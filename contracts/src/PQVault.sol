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

/// @title PQVault — t-of-n post-quantum guardian wallet for EIP-8141 frame transactions
/// @notice No ECDSA anywhere: every approval is a JARDIN hash-based signature (upstream verifiers,
///         unmodified) carried in an EIP-8141 `ARBITRARY` signature entry and checked against the
///         protocol's canonical signature hash `TXPARAM(0x08)`, which commits to chain id, sender,
///         nonce, fees and every frame (including the body frame's calldata).
///
///         The number of guardians n and the threshold t (2 <= t <= n <= 16) are fixed at creation.
///
///         Transaction shape (exactly), the ERC-8421 `[only_verify, pay]` validation prefix + one body frame:
///           signatures: t ARBITRARY entries, msg empty, guardian indices strictly increasing
///           frame 0 VERIFY  scope EXECUTION -> validate() data = selector ‖ 0 ‖ k   checks entries [0, k)
///           frame 1 VERIFY  scope PAYMENT   -> validate() data = selector ‖ k ‖ t   checks entries [k, t)
///           frame 2 SENDER                  -> execute(calls)                      consumes every leaf, runs the batch
///         The submitter picks k (1 <= k < t) to balance validation gas between the two frames; the
///         frame data is covered by the signature hash, so k is signed like everything else.
///
///         Every guardian signature is cryptographically verified inside a VERIFY frame, before
///         payment is approved. A missing, corrupted, stale or duplicated approval makes the whole
///         transaction invalid, so it costs the vault nothing. All guardians sign the same message
///         (messageFor(sigHash)), independently and in any order.
///
///         VERIFY frames are static: they only *check* each compact leaf against the shared LeafLedger
///         (q must be above the slot's high-water mark). The SENDER frame *consumes* every leaf
///         (LeafLedger.consume is an atomic check-and-update, so a leaf raced by another transaction
///         after validation is caught there) and then runs the batch atomically.
///
///         Entry layout (ARBITRARY signature bytes):
///           compact   (0x02): guardian u8 ‖ 0x02 ‖ slotSeed 16 ‖ slotRoot 16 ‖ plain-FORS sig (2593+16h)
///           stateless (0x01): guardian u8 ‖ 0x01 ‖ SPX sig 6512   (against the guardian's master key)
///
///         Validation gas: about 75-80k per compact approval. Two or more approvals exceed EIP-8141's
///         combined MAX_VERIFY_GAS (100k); ERC-8421 [BUDGET-010] gives a *staked* entity its own
///         MAX_VERIFY_GAS_STAKED_ENTITY (1,000,000) budget, and every validation frame here belongs to
///         the vault (sender and payer), which stakes itself in its constructor.
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
    uint256 public constant MAX_GUARDIANS = 16;
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
        Guardian[] guardians; // n master keys
        bytes16[] slotSeeds; // initial compact slot per guardian
        bytes16[] slotRoots;
        uint8 threshold; // t
        uint256 maxTxCost; // cap on TXPARAM(0x06), the most one transaction may make the vault pay
        uint32 unstakeDelay;
    }

    address public immutable FRAME_OPS;
    IJardinFors public immutable FORS;
    IJardinSpx public immutable SPX;
    ILeafLedger public immutable LEDGER;
    IStakingRegistry public immutable STAKING;
    uint256 public immutable MAX_TX_COST;
    uint256 public immutable N_GUARDIANS;
    uint256 public immutable THRESHOLD;

    mapping(uint256 => Guardian) private _guardians;
    /// Guardian epochs; bumping an epoch revokes all of that guardian's slots.
    mapping(uint256 => uint256) private _epochs;
    /// slotId = keccak256(seed16 ‖ root16) => (epoch << 8) | (guardian + 1); 0 = not registered.
    mapping(bytes32 => uint256) public slotInfo;

    // ---------------------------------------------------------------- events & errors
    event SlotRegistered(uint8 indexed guardian, bytes32 indexed slotId, uint256 epoch);
    event SlotRevoked(bytes32 indexed slotId);
    event GuardianReplaced(uint8 indexed guardian, uint256 newEpoch);
    event Executed(bytes32 indexed sigHash, uint256 guardianMask, uint256 calls);
    event BatchFailed(bytes32 indexed sigHash, bytes reason);
    event LeafRaced(bytes32 indexed sigHash, bytes32 indexed slotId, uint256 q);

    error NotSelf();
    error BadShape();
    error BadConfig();
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
    uint8 private constant R_GUARDIAN = 3; // unknown guardian index, or not strictly increasing (duplicate)
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
        uint256 n = init.guardians.length;
        if (
            n > MAX_GUARDIANS || init.threshold < 2 || init.threshold > n || init.slotSeeds.length != n
                || init.slotRoots.length != n
        ) revert BadConfig();
        FRAME_OPS = deps.frameOps;
        FORS = IJardinFors(deps.fors);
        SPX = IJardinSpx(deps.spx);
        LEDGER = ILeafLedger(deps.ledger);
        STAKING = IStakingRegistry(deps.staking);
        MAX_TX_COST = init.maxTxCost;
        N_GUARDIANS = n;
        THRESHOLD = init.threshold;
        for (uint256 g = 0; g < n; g++) {
            for (uint256 o = 0; o < g; o++) {
                if (_sameKey(init.guardians[o], init.guardians[g])) revert DuplicateKey();
            }
            _setGuardian(g, init.guardians[g]);
            _registerSlot(n, uint8(g), init.slotSeeds[g], init.slotRoots[g]);
        }
        // ERC-8421 staking must be done by the vault itself (the registry keys on msg.sender). Doing
        // it here avoids a bootstrap loop: the vault's first frame tx already needs the stake.
        if (stakeAmount > 0) STAKING.addStake{value: stakeAmount}(init.unstakeDelay);
    }

    receive() external payable {}

    // =================================================================== VERIFY frames (0 and 1)
    /// @notice Validation entry for both VERIFY frames. Calldata: selector ‖ from u8 ‖ to u8.
    ///         Runs as a STATICCALL; the only side effect is APPROVE (execution in frame 0, payment in frame 1).
    function validate() external {
        if (msg.data.length != 6) revert BadShape();
        uint256 from = uint8(msg.data[4]);
        uint256 to = uint8(msg.data[5]);
        uint256 t = THRESHOLD;

        // Shape of the whole transaction, as seen through the body frame (index 2).
        Ctx memory c = _frame(2);
        if (c.frameCount != 3 || c.sigCount != t) revert BadShape();
        if (
            c.fMode != MODE_SENDER || c.fTarget != uint256(uint160(address(this)))
                || bytes4(c.fWord0) != this.execute.selector || c.fFlags != 0
        ) revert BadShape();
        if (c.maxCost > MAX_TX_COST) revert TxTooExpensive();

        // The two VERIFY frames must split [0, t) between them: frame 0 = [0, k), frame 1 = [k, t).
        uint256 scope;
        uint256 peer;
        bytes32 peerWord;
        if (c.curFrame == 0) {
            if (from != 0 || to == 0 || to >= t) revert BadShape();
            (scope, peer, peerWord) = (SCOPE_EXECUTION, 1, _rangeWord(to, t));
        } else if (c.curFrame == 1) {
            if (to != t || from == 0 || from >= t) revert BadShape();
            (scope, peer, peerWord) = (SCOPE_PAYMENT, 0, _rangeWord(0, from));
        } else {
            revert BadShape();
        }
        Ctx memory p = _frame(peer);
        if (
            p.fMode != MODE_VERIFY || p.fTarget != uint256(uint160(address(this))) || p.fWord0 != peerWord
                || p.fFlags != (peer == 0 ? SCOPE_EXECUTION : SCOPE_PAYMENT)
        ) revert BadShape();

        bytes32 m = messageFor(c.sigHash);
        // Guardian indices strictly increase across all t entries, so no guardian approves twice.
        uint256 prev = from == 0 ? NONE : _guardianAt(from - 1);
        for (uint256 i = from; i < to; i++) {
            (Ctx memory ci, bytes memory e) = _introspect(i, NONE, NONE);
            Approval memory a = _check(ci, e, prev, m);
            if (a.reason == R_STALE) revert StaleLeaf(a.slotId, a.q);
            if (a.reason != 0) revert BadEntry(i, a.reason);
            prev = a.guardian;
        }

        _approve(scope);
    }

    // =================================================================== SENDER frame (2)
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Body frame: consume every approving leaf, then run the batch atomically.
    /// @dev Reached only after both VERIFY frames approved, and validate() pins frame 2 to this
    ///      function, so every entry has already been verified; entries are only decoded here.
    function execute(Call[] calldata calls) external onlySelf {
        uint256 t = THRESHOLD;
        bytes32 sigHash;
        uint256 mask;
        bool raced;
        for (uint256 i = 0; i < t; i++) {
            (Ctx memory c, bytes memory e) = _introspect(i, NONE, Q_OFFSET + 1);
            sigHash = c.sigHash;
            Approval memory a = _decode(c, e);
            if (a.reason != 0) revert BadEntry(i, a.reason); // unreachable after validate(); defensive
            mask |= 1 << a.guardian;
            if (address(LEDGER) != address(0) && a.kind == SIG_COMPACT) {
                // Atomic check-and-update. A leaf consumed by another transaction since validation
                // (a race) fails here; the remaining leaves are still consumed (their signatures are
                // public now) and nothing is executed.
                try LEDGER.consume(a.slotId, a.q) {}
                catch {
                    raced = true;
                    emit LeafRaced(sigHash, a.slotId, a.q);
                }
            }
        }
        if (raced) return;

        try this.runBatch(calls) {
            emit Executed(sigHash, mask, calls.length);
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

    // =================================================================== guardian management (t-of-n via execute)
    /// @notice Key rotation: authorise a new compact slot for guardian `g` (e.g. after a slot is exhausted
    ///         or after the guardian restored from backup and generated fresh slot randomness).
    function registerSlot(uint8 g, bytes16 seed, bytes16 root) external onlySelf {
        _registerSlot(N_GUARDIANS, g, seed, root);
    }

    function revokeSlot(bytes32 slotId) external onlySelf {
        delete slotInfo[slotId];
        emit SlotRevoked(slotId);
    }

    /// @notice Key-loss recovery / guardian replacement: t other guardians install new master and slot keys
    ///         for `g`. Bumping the epoch revokes every slot `g` held before.
    function replaceGuardian(uint8 g, Guardian calldata master, bytes16 slotSeed, bytes16 slotRoot)
        external
        onlySelf
    {
        uint256 n = N_GUARDIANS;
        if (g >= n) revert BadGuardian();
        for (uint256 o = 0; o < n; o++) {
            if (o != g && _sameKey(_guardians[o], master)) revert DuplicateKey();
        }
        uint256 epoch = _epochs[g] + 1;
        _epochs[g] = epoch;
        _setGuardian(g, master);
        _registerSlot(n, g, slotSeed, slotRoot);
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
        return _epochs[g];
    }

    function slotGuardian(bytes32 slotId) external view returns (bool active, uint8 g) {
        uint256 info = slotInfo[slotId];
        if (info == 0) return (false, 0);
        g = uint8((info & 0xff) - 1);
        active = (info >> 8) == _epochs[g];
    }

    /// @notice What every approving guardian signs.
    function messageFor(bytes32 sigHash) public pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, sigHash));
    }

    // =================================================================== internals
    function _rangeWord(uint256 from, uint256 to) private pure returns (bytes32) {
        return bytes32(abi.encodePacked(PQVault.validate.selector, uint8(from), uint8(to)));
    }

    function _sameKey(Guardian memory a, Guardian memory b) private pure returns (bool) {
        return a.spxSeed == b.spxSeed && a.spxRoot == b.spxRoot;
    }

    function _setGuardian(uint256 g, Guardian memory m) private {
        _requireCanonical(m.spxSeed, m.spxRoot);
        if (m.spxSeed == bytes32(0) && m.spxRoot == bytes32(0)) revert NonCanonicalKey();
        _guardians[g] = m;
    }

    function _registerSlot(uint256 n, uint8 g, bytes16 seed, bytes16 root) private {
        if (g >= n) revert BadGuardian();
        _requireCanonical(bytes32(seed), bytes32(root));
        if (seed == bytes16(0) && root == bytes16(0)) revert NonCanonicalKey();
        bytes32 slotId = keccak256(abi.encodePacked(seed, root));
        // A slot key held (in its current epoch) by another guardian would let one device approve twice.
        uint256 info = slotInfo[slotId];
        if (info != 0) {
            uint256 owner = (info & 0xff) - 1;
            if (owner != g && (info >> 8) == _epochs[owner]) revert DuplicateKey();
        }
        uint256 epoch = _epochs[g];
        slotInfo[slotId] = (epoch << 8) | (uint256(g) + 1);
        emit SlotRegistered(g, slotId, epoch);
    }

    /// PQ public-key components are 16-byte values stored high-aligned; dirty low bits would brick the key.
    function _requireCanonical(bytes32 seed, bytes32 root) private pure {
        if (uint256(seed) & type(uint128).max != 0 || uint256(root) & type(uint128).max != 0) {
            revert NonCanonicalKey();
        }
    }

    /// Structural decode of an entry (no cryptography). `e` may be truncated after the leaf byte.
    function _decode(Ctx memory c, bytes memory e) private view returns (Approval memory a) {
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
    /// @param prev guardian index of the previous entry (NONE for the first): must be strictly smaller.
    function _check(Ctx memory c, bytes memory e, uint256 prev, bytes32 m) private view returns (Approval memory a) {
        a = _decode(c, e);
        if (a.reason != 0) return a;
        if (prev != NONE && a.guardian <= prev) {
            a.reason = R_GUARDIAN;
            return a;
        }
        if (a.kind == SIG_COMPACT) {
            uint256 info = slotInfo[a.slotId];
            if (info != ((_epochs[a.guardian] << 8) | (uint256(a.guardian) + 1))) {
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
