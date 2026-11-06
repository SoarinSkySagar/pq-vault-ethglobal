// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IJardinFors {
    function verifyForsPlain(bytes32 pkSeed, bytes32 pkRoot, bytes32 message, bytes calldata sig)
        external
        pure
        returns (bool);
}

interface IJardinSpx {
    function verify(bytes32 pkSeed, bytes32 pkRoot, bytes32 message, bytes calldata sig) external pure returns (bool);
}

interface ILeafLedger {
    function hwm(bytes32 slotId) external view returns (uint256);
    function consume(bytes32 slotId, uint256 q) external;
}

interface IStakingRegistry {
    function addStake(uint32 unstakeDelaySec) external payable;
    function unlockStake() external;
    function withdrawStake(address payable withdrawAddress) external;
}

/// @title PQVault — 2-of-3 post-quantum guardian wallet for EIP-8141 frame transactions
/// @notice No ECDSA anywhere: every approval is a JARDIN hash-based signature (upstream verifiers,
///         unmodified) carried in an EIP-8141 `ARBITRARY` signature entry and checked against the
///         protocol's canonical signature hash `TXPARAM(0x08)`, which commits to chain id, sender,
///         nonce, fees and every frame (including the body frame's calldata).
///
///         Transaction shape (exactly) — the ERC-8421 `[only_verify, pay]` validation prefix + one body frame:
///           signatures: 2 ARBITRARY entries, msg empty; entry 0's guardian < entry 1's guardian
///           frame 0 VERIFY  scope EXECUTION -> validate()        verifies guardian A (entry 0)
///           frame 1 VERIFY  scope PAYMENT   -> validate()        verifies guardian B (entry 1)
///           frame 2 SENDER                  -> execute(calls)    consumes both leaves, runs the batch
///
///         Both signatures are verified before payment is approved: a missing, corrupted, stale or
///         duplicated approval makes the transaction invalid, so it costs the vault nothing. Both guardians
///         sign the same message (messageFor(sigHash)), independently and in any order.
///
///         VERIFY frames are static: they only *check* each compact leaf against the shared LeafLedger
///         (q must be above the slot's high-water mark). The SENDER frame *consumes* both leaves
///         (LeafLedger.consume is an atomic check-and-update, so a leaf raced by another transaction after
///         validation is caught there) and then runs the batch atomically.
///
///         Entry layout (ARBITRARY signature bytes):
///           compact   (0x02): guardian u8 ‖ 0x02 ‖ slotSeed 16 ‖ slotRoot 16 ‖ plain-FORS sig (2593+16h)
///           stateless (0x01): guardian u8 ‖ 0x01 ‖ SPX sig 6512   (against the guardian's master key)
///
///         Validation gas: ~85k per VERIFY frame with a compact approval (~295k with a stateless one), so the
///         prefix (~170k) exceeds EIP-8141's combined MAX_VERIFY_GAS (100k). ERC-8421 [BUDGET-010] gives a
///         *staked* entity its own MAX_VERIFY_GAS_STAKED_ENTITY (1,000,000) budget; both VERIFY frames belong
///         to the vault (sender and payer), which stakes itself in its constructor.
contract PQVault {
    // ---------------------------------------------------------------- constants & config
    uint256 private constant MODE_VERIFY = 1;
    uint256 private constant MODE_SENDER = 2;
    uint256 private constant SCOPE_PAYMENT = 1;
    uint256 private constant SCOPE_EXECUTION = 2;
    uint256 private constant SCHEME_ARBITRARY = 0;
    uint256 private constant FORS_BASE_LEN = 2593; // JardinForsPlainVerifier: 2593 + 16h, h in [2,8]
    uint256 private constant SPX_LEN = 6512;
    uint256 private constant COMPACT_HDR = 34; // guardian + kind + seed16 + root16
    uint256 private constant Q_OFFSET = 2626; // COMPACT_HDR + 2592: leaf index byte inside a compact entry
    uint256 private constant NONE = type(uint256).max;

    uint8 public constant SIG_STATELESS = 0x01;
    uint8 public constant SIG_COMPACT = 0x02;
    uint256 public constant N_GUARDIANS = 3;
    uint256 public constant THRESHOLD = 2;
    bytes32 public constant DOMAIN = keccak256("PQ-Vault/v2");

    struct Deps {
        address frameOps; // PQVaultFrameOps (EIP-8141 opcode helper)
        address fors; // JardinForsPlainVerifier
        address spx; // JardinSpxVerifier
        address ledger; // LeafLedger, or address(0) for the JARDIN baseline (no on-chain leaf tracking)
        address staking; // ERC-8421 staking registry, or address(0)
    }

    struct Guardian {
        bytes32 spxSeed; // JARDIN SPX master public key (stateless; 16-byte values, high-aligned)
        bytes32 spxRoot;
    }

    struct Init {
        Guardian[3] guardians;
        bytes16[3] slotSeeds; // initial compact slot per guardian
        bytes16[3] slotRoots;
        uint256 maxTxCost; // cap on TXPARAM(0x06), the most one transaction may make the vault pay
        uint32 unstakeDelay;
    }

    address public immutable FRAME_OPS;
    IJardinFors public immutable FORS;
    IJardinSpx public immutable SPX;
    ILeafLedger public immutable LEDGER;
    IStakingRegistry public immutable STAKING;
    uint256 public immutable MAX_TX_COST;

    Guardian[3] private _guardians;
    /// Three 32-bit guardian epochs packed in one word; bumping an epoch revokes all of that guardian's slots.
    uint256 private _epochs;
    /// slotId = keccak256(seed16 ‖ root16) => (epoch << 8) | (guardian + 1); 0 = not registered.
    mapping(bytes32 => uint256) public slotInfo;

    // ---------------------------------------------------------------- events & errors
    event SlotRegistered(uint8 indexed guardian, bytes32 indexed slotId, uint256 epoch);
    event SlotRevoked(bytes32 indexed slotId);
    event GuardianReplaced(uint8 indexed guardian, uint256 newEpoch);
    event Executed(bytes32 indexed sigHash, uint8 guardianA, uint8 guardianB, uint256 calls);
    event BatchFailed(bytes32 indexed sigHash, bytes reason);
    event LeafRaced(bytes32 indexed sigHash, bytes32 indexed slotId, uint256 q);

    error NotSelf();
    error BadShape();
    error TxTooExpensive();
    error BadEntry(uint256 index, uint8 reason);
    error StaleLeaf(bytes32 slotId, uint256 q);
    error FrameOpsFailed();
    error NonCanonicalKey();
    error BadGuardian();
    error DuplicateKey();
    error CallFailed(uint256 index, bytes reason);

    // Rejection reasons (BadEntry)
    uint8 private constant R_SCHEME = 1; // not an ARBITRARY entry over the canonical sig hash
    uint8 private constant R_LENGTH = 2;
    uint8 private constant R_GUARDIAN = 3; // unknown guardian index, or not above entry 0's (same guardian twice)
    uint8 private constant R_KIND = 4; // unsupported kind
    uint8 private constant R_SLOT = 5; // slot not registered to this guardian in its current epoch
    uint8 private constant R_STALE = 6; // leaf q not above the ledger high-water mark
    uint8 private constant R_SIG = 7; // cryptographic verification failed

    struct Ctx {
        bytes32 sigHash;
        uint256 maxCost;
        uint256 frameCount;
        uint256 curFrame;
        uint256 sigCount;
        uint256 scheme;
        uint256 msgWord;
        uint256 sigLen;
        uint256 fMode;
        uint256 fTarget;
        bytes32 fWord0;
        uint256 fFlags;
    }

    struct Approval {
        uint8 reason; // 0 = valid
        uint8 guardian;
        uint8 kind;
        bytes32 slotId; // compact only
        uint256 q; // compact only
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(Deps memory deps, Init memory init, uint256 stakeAmount) payable {
        FRAME_OPS = deps.frameOps;
        FORS = IJardinFors(deps.fors);
        SPX = IJardinSpx(deps.spx);
        LEDGER = ILeafLedger(deps.ledger);
        STAKING = IStakingRegistry(deps.staking);
        MAX_TX_COST = init.maxTxCost;
        for (uint8 g = 0; g < N_GUARDIANS; g++) {
            for (uint8 o = 0; o < g; o++) {
                if (_sameKey(init.guardians[o], init.guardians[g])) revert DuplicateKey();
            }
            _setGuardian(g, init.guardians[g]);
            _registerSlot(g, init.slotSeeds[g], init.slotRoots[g]);
        }
        // ERC-8421 staking must be done by the vault itself (the registry keys on msg.sender). Doing
        // it here avoids a bootstrap loop: the vault's first frame tx already needs the stake.
        if (stakeAmount > 0) STAKING.addStake{value: stakeAmount}(init.unstakeDelay);
    }

    receive() external payable {}

    // =================================================================== VERIFY frames (0 and 1)
    /// @notice Validation entry of both VERIFY frames: frame i verifies signature entry i.
    ///         Runs as a STATICCALL; the only side effect is APPROVE (execution in frame 0, payment in frame 1).
    function validate() external {
        if (msg.data.length != 4) revert BadShape();
        // Shape of the whole transaction, as seen through the body frame (index 2).
        Ctx memory c = _frame(2);
        if (c.frameCount != 3 || c.sigCount != THRESHOLD) revert BadShape();
        if (
            c.fMode != MODE_SENDER || c.fTarget != uint256(uint160(address(this)))
                || bytes4(c.fWord0) != this.execute.selector || c.fFlags != 0
        ) revert BadShape();
        if (c.maxCost > MAX_TX_COST) revert TxTooExpensive();

        uint256 me = c.curFrame;
        if (me > 1) revert BadShape();
        uint256 peer = 1 - me;
        // The other VERIFY frame must be this vault's validate() with the complementary scope.
        Ctx memory p = _frame(peer);
        if (
            p.fMode != MODE_VERIFY || p.fTarget != uint256(uint160(address(this)))
                || p.fWord0 != bytes32(PQVault.validate.selector)
                || p.fFlags != (peer == 0 ? SCOPE_EXECUTION : SCOPE_PAYMENT)
        ) revert BadShape();

        // Entry 1's guardian must be above entry 0's, so the two approvals come from different guardians.
        uint256 prev = me == 0 ? NONE : _guardianAt(0);
        (Ctx memory ci, bytes memory e) = _introspect(me, NONE, NONE);
        Approval memory a = _check(ci, e, prev, messageFor(c.sigHash));
        if (a.reason == R_STALE) revert StaleLeaf(a.slotId, a.q);
        if (a.reason != 0) revert BadEntry(me, a.reason);

        _approve(me == 0 ? SCOPE_EXECUTION : SCOPE_PAYMENT);
    }

    // =================================================================== SENDER frame (2)
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Body frame: consume both leaves, then run the batch atomically.
    /// @dev Reached only after both VERIFY frames approved, and validate() pins frame 2 to this function,
    ///      so both entries are already verified; they are only decoded here.
    function execute(Call[] calldata calls) external onlySelf {
        (Ctx memory c0, bytes memory e0) = _introspect(0, NONE, Q_OFFSET + 1);
        (Ctx memory c1, bytes memory e1) = _introspect(1, NONE, Q_OFFSET + 1);
        Approval memory a = _decode(c0, e0);
        Approval memory b = _decode(c1, e1);
        if (a.reason != 0) revert BadEntry(0, a.reason); // verified in VERIFY frame 0; defensive
        if (b.reason != 0) revert BadEntry(1, b.reason); // verified in VERIFY frame 1; defensive
        bytes32 sigHash = c0.sigHash;
        // Atomic check-and-update per leaf. A leaf consumed by another transaction since validation (a race)
        // fails here; the other leaf is still consumed (its signature is public now) and nothing executes.
        bool okA = _consume(sigHash, a);
        bool okB = _consume(sigHash, b);
        if (!okA || !okB) return;

        try this.runBatch(calls) {
            emit Executed(sigHash, a.guardian, b.guardian, calls.length);
        } catch (bytes memory reason) {
            emit BatchFailed(sigHash, reason);
        }
    }

    /// @notice Atomic batch; reverts as a whole on the first failing call. Self-call only.
    function runBatch(Call[] calldata calls) external onlySelf {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
        }
    }

    // =================================================================== guardian management (2-of-3 via execute)
    /// @notice Key rotation: authorise a new compact slot for guardian `g` (e.g. after a slot is exhausted
    ///         or after the guardian restored from backup and generated fresh slot randomness).
    function registerSlot(uint8 g, bytes16 seed, bytes16 root) external onlySelf {
        _registerSlot(g, seed, root);
    }

    function revokeSlot(bytes32 slotId) external onlySelf {
        delete slotInfo[slotId];
        emit SlotRevoked(slotId);
    }

    /// @notice Key-loss recovery / guardian replacement: the other two guardians install new master and slot
    ///         keys for `g`. Bumping the epoch revokes every slot `g` held before.
    function replaceGuardian(uint8 g, Guardian calldata master, bytes16 slotSeed, bytes16 slotRoot)
        external
        onlySelf
    {
        if (g >= N_GUARDIANS) revert BadGuardian();
        for (uint8 o = 0; o < N_GUARDIANS; o++) {
            if (o != g && _sameKey(_guardians[o], master)) revert DuplicateKey();
        }
        uint256 epoch = _epochOf(g) + 1;
        _epochs = (_epochs & ~(uint256(0xffffffff) << (32 * g))) | ((epoch & 0xffffffff) << (32 * g));
        _setGuardian(g, master);
        _registerSlot(g, slotSeed, slotRoot);
        emit GuardianReplaced(g, epoch);
    }

    function unlockStake() external onlySelf {
        STAKING.unlockStake();
    }

    function withdrawStake(address payable to) external onlySelf {
        STAKING.withdrawStake(to);
    }

    // =================================================================== views
    function guardian(uint8 g) external view returns (Guardian memory) {
        return _guardians[g];
    }

    function epochOf(uint8 g) external view returns (uint256) {
        return _epochOf(g);
    }

    function slotGuardian(bytes32 slotId) external view returns (bool active, uint8 g) {
        uint256 info = slotInfo[slotId];
        if (info == 0) return (false, 0);
        g = uint8((info & 0xff) - 1);
        active = (info >> 8) == _epochOf(g);
    }

    /// @notice What both approving guardians sign.
    function messageFor(bytes32 sigHash) public pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, sigHash));
    }

    // =================================================================== internals
    function _sameKey(Guardian memory a, Guardian memory b) private pure returns (bool) {
        return a.spxSeed == b.spxSeed && a.spxRoot == b.spxRoot;
    }

    function _setGuardian(uint8 g, Guardian memory m) private {
        _requireCanonical(m.spxSeed, m.spxRoot);
        if (m.spxSeed == bytes32(0) && m.spxRoot == bytes32(0)) revert NonCanonicalKey();
        _guardians[g] = m;
    }

    function _registerSlot(uint8 g, bytes16 seed, bytes16 root) private {
        if (g >= N_GUARDIANS) revert BadGuardian();
        _requireCanonical(bytes32(seed), bytes32(root));
        if (seed == bytes16(0) && root == bytes16(0)) revert NonCanonicalKey();
        bytes32 slotId = keccak256(abi.encodePacked(seed, root));
        // A slot key held (in its current epoch) by another guardian would let one device approve twice.
        uint256 info = slotInfo[slotId];
        if (info != 0) {
            uint8 owner = uint8((info & 0xff) - 1);
            if (owner != g && (info >> 8) == _epochOf(owner)) revert DuplicateKey();
        }
        uint256 epoch = _epochOf(g);
        slotInfo[slotId] = (epoch << 8) | (uint256(g) + 1);
        emit SlotRegistered(g, slotId, epoch);
    }

    function _epochOf(uint8 g) private view returns (uint256) {
        return (_epochs >> (32 * g)) & 0xffffffff;
    }

    /// PQ public-key components are 16-byte values stored high-aligned; dirty low bits would brick the key.
    function _requireCanonical(bytes32 seed, bytes32 root) private pure {
        if (uint256(seed) & type(uint128).max != 0 || uint256(root) & type(uint128).max != 0) {
            revert NonCanonicalKey();
        }
    }

    /// Structural decode of an entry (no cryptography). `e` may be truncated after the leaf byte.
    function _decode(Ctx memory c, bytes memory e) private pure returns (Approval memory a) {
        if (c.scheme != SCHEME_ARBITRARY || c.msgWord != 0) {
            a.reason = R_SCHEME;
            return a;
        }
        uint256 len = c.sigLen; // full length (e may hold only a prefix of it)
        if (len < 2) {
            a.reason = R_LENGTH;
            return a;
        }
        a.guardian = uint8(e[0]);
        a.kind = uint8(e[1]);
        if (a.guardian >= N_GUARDIANS) {
            a.reason = R_GUARDIAN;
            return a;
        }
        if (a.kind == SIG_COMPACT) {
            uint256 forsLen = len < COMPACT_HDR ? 0 : len - COMPACT_HDR;
            if (forsLen < FORS_BASE_LEN + 32 || (forsLen - FORS_BASE_LEN) % 16 != 0 || forsLen > FORS_BASE_LEN + 128)
            {
                a.reason = R_LENGTH;
                return a;
            }
            bytes32 slotId;
            uint256 q;
            assembly {
                let p := add(e, 0x20)
                slotId := keccak256(add(p, 2), 32)
                q := byte(0, mload(add(p, Q_OFFSET)))
            }
            a.slotId = slotId;
            a.q = q;
        } else if (a.kind == SIG_STATELESS) {
            if (len != 2 + SPX_LEN) a.reason = R_LENGTH;
        } else {
            a.reason = R_KIND;
        }
    }

    /// Full check of one entry against message `m`.
    /// @param prev guardian index of entry 0 when checking entry 1 (NONE for entry 0): must be strictly smaller.
    function _check(Ctx memory c, bytes memory e, uint256 prev, bytes32 m) private view returns (Approval memory a) {
        a = _decode(c, e);
        if (a.reason != 0) return a;
        if (prev != NONE && a.guardian <= prev) {
            a.reason = R_GUARDIAN;
            return a;
        }
        if (a.kind == SIG_COMPACT) {
            uint256 info = slotInfo[a.slotId];
            if (info != ((_epochOf(a.guardian) << 8) | (uint256(a.guardian) + 1))) {
                a.reason = R_SLOT;
                return a;
            }
            if (address(LEDGER) != address(0) && a.q <= LEDGER.hwm(a.slotId)) {
                a.reason = R_STALE;
                return a;
            }
            bytes32 seed;
            bytes32 root;
            assembly {
                let p := add(e, 0x20)
                seed := and(mload(add(p, 2)), not(0xffffffffffffffffffffffffffffffff))
                root := and(mload(add(p, 18)), not(0xffffffffffffffffffffffffffffffff))
            }
            if (!_staticVerify(address(FORS), IJardinFors.verifyForsPlain.selector, seed, root, m, e, COMPACT_HDR)) {
                a.reason = R_SIG;
            }
        } else {
            Guardian storage g = _guardians[a.guardian];
            if (!_staticVerify(address(SPX), IJardinSpx.verify.selector, g.spxSeed, g.spxRoot, m, e, 2)) {
                a.reason = R_SIG;
            }
        }
    }

    /// Consume a compact approval's leaf; false (and LeafRaced) if it was consumed since validation.
    function _consume(bytes32 sigHash, Approval memory a) private returns (bool) {
        if (address(LEDGER) == address(0) || a.kind != SIG_COMPACT) return true;
        try LEDGER.consume(a.slotId, a.q) {
            return true;
        } catch {
            emit LeafRaced(sigHash, a.slotId, a.q);
            return false;
        }
    }

    /// Guardian index (first byte) of signature entry `i`, copying only that byte.
    function _guardianAt(uint256 i) private view returns (uint256) {
        (Ctx memory c, bytes memory e) = _introspect(i, NONE, 1);
        if (c.scheme != SCHEME_ARBITRARY || e.length == 0) revert BadEntry(i, R_SCHEME);
        return uint8(e[0]);
    }

    /// Calls `verifier.selector(seed, root, m, buf[off:])` without copying the signature: the ABI head
    /// is written in place over the bytes just before buf[off:]. Clobbers `buf` and up to 164 bytes in
    /// front of it, which always belong to the same FrameOps return buffer (see _introspect).
    function _staticVerify(address verifier, bytes4 selector, bytes32 seed, bytes32 root, bytes32 m, bytes memory buf, uint256 off)
        private
        view
        returns (bool valid)
    {
        assembly {
            let len := sub(mload(buf), off)
            let h := sub(add(add(buf, 0x20), off), 0xa4)
            mstore(h, selector)
            mstore(add(h, 0x04), seed)
            mstore(add(h, 0x24), root)
            mstore(add(h, 0x44), m)
            mstore(add(h, 0x64), 0x80)
            mstore(add(h, 0x84), len)
            let ok := staticcall(gas(), verifier, h, add(0xa4, len), 0x00, 0x20)
            valid := and(ok, and(eq(returndatasize(), 0x20), eq(mload(0x00), 1)))
        }
    }

    /// Transaction context plus frame `f`'s fields, without any signature bytes.
    function _frame(uint256 f) private view returns (Ctx memory c) {
        (c,) = _introspect(NONE, f, 0);
    }

    /// One call to PQVaultFrameOps: 12 context words + up to `maxCopy` bytes of signature entry `sigIndex`.
    /// The returned `entry` aliases the tail of the return buffer, so the 384 bytes in front of it are
    /// scratch for _staticVerify.
    function _introspect(uint256 sigIndex, uint256 frameIndex, uint256 maxCopy)
        private
        view
        returns (Ctx memory c, bytes memory entry)
    {
        (bool ok, bytes memory out) = FRAME_OPS.staticcall(abi.encode(uint256(0), sigIndex, frameIndex, maxCopy));
        if (!ok || out.length < 384) revert FrameOpsFailed();
        assembly {
            let src := add(out, 0x20)
            for { let i := 0 } lt(i, 384) { i := add(i, 0x20) } { mstore(add(c, i), mload(add(src, i))) }
        }
        uint256 len = c.sigLen < maxCopy ? c.sigLen : maxCopy;
        if (out.length != 384 + len) revert FrameOpsFailed();
        assembly {
            entry := add(out, 384)
            mstore(entry, len)
        }
    }

    function _approve(uint256 scope) private {
        (bool ok,) = FRAME_OPS.delegatecall(abi.encode(uint256(1), scope));
        if (!ok) revert FrameOpsFailed();
    }
}
