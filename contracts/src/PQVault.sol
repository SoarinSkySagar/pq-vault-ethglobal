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
///         Transaction shape (exactly):
///           signatures: [ARBITRARY entry of guardian A, ARBITRARY entry of guardian B], msg empty
///           frame 0 VERIFY  -> validate()          (static; must fit the 100k validation budget)
///           frame 1 SENDER  -> execute(calls)      (target = this vault)
///
///         validate() verifies guardian A's *compact* signature (one JARDIN plain-FORS check fits the
///         budget; two do not), rejects stale leaves via the shared LeafLedger, caps what the
///         transaction may cost, and binds the approval to the frame list so the only code that can
///         run as the vault is execute(). execute() verifies guardian B (compact or stateless SPX,
///         a different guardian), advances both slots' leaf marks, then runs the batch atomically.
///         If B's signature is missing or invalid nothing is executed: the only effect of a single
///         guardian acting alone is a fee of at most MAX_TX_COST and one consumed leaf.
///
///         Entry layout (ARBITRARY signature bytes):
///           compact   (0x02): guardian u8 ‖ 0x02 ‖ slotSeed 16 ‖ slotRoot 16 ‖ plain-FORS sig (2593+16h)
///           stateless (0x01): guardian u8 ‖ 0x01 ‖ SPX sig 6512   (against the guardian's master key)
///         Signed messages (B signs first, then A commits to B's exact entry bytes):
///           guardian B: keccak256(abi.encode(DOMAIN, sigHash))
///           guardian A: keccak256(abi.encode(DOMAIN, sigHash, keccak256(entryB)))
///         `ARBITRARY` bytes with an empty msg are elided from TXPARAM(0x08), so without the second form
///         anyone relaying the tx could corrupt entry B and rebroadcast a copy that still passes
///         validation (only A is checked there) but executes nothing while the vault pays the fee.
contract PQVault {
    // ---------------------------------------------------------------- constants & config
    uint256 private constant MODE_SENDER = 2;
    uint256 private constant SCOPE_EXECUTION_AND_PAYMENT = 3;
    uint256 private constant SCHEME_ARBITRARY = 0;
    uint256 private constant FORS_BASE_LEN = 2593; // JardinForsPlainVerifier: 2593 + 16h, h in [2,8]
    uint256 private constant SPX_LEN = 6512;
    uint256 private constant COMPACT_HDR = 34; // guardian + kind + seed16 + root16

    uint8 public constant SIG_STATELESS = 0x01;
    uint8 public constant SIG_COMPACT = 0x02;
    uint256 public constant N_GUARDIANS = 3;
    uint256 public constant THRESHOLD = 2;
    bytes32 public constant DOMAIN = keccak256("PQ-Vault/v1");

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
        uint256 maxTxCost; // cap on TXPARAM(0x06), the most a single guardian can make the vault pay
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
    event Executed(bytes32 indexed sigHash, uint8 guardianA, uint8 guardianB, uint8 kindB, uint256 calls);
    event SecondApprovalRejected(bytes32 indexed sigHash, uint8 guardianA, uint8 reason);
    event BatchFailed(bytes32 indexed sigHash, bytes reason);

    error NotSelf();
    error BadShape();
    error TxTooExpensive();
    error BadEntry(uint8 reason);
    error StaleLeaf(bytes32 slotId, uint256 q);
    error FrameOpsFailed();
    error NonCanonicalKey();
    error BadGuardian();
    error CallFailed(uint256 index, bytes reason);

    // Rejection reasons (BadEntry / SecondApprovalRejected)
    uint8 private constant R_SCHEME = 1; // not an ARBITRARY entry over the canonical sig hash
    uint8 private constant R_LENGTH = 2;
    uint8 private constant R_GUARDIAN = 3; // unknown guardian index, or same guardian twice
    uint8 private constant R_KIND = 4; // unsupported kind (validate() accepts compact only)
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
            _setGuardian(g, init.guardians[g]);
            _registerSlot(g, init.slotSeeds[g], init.slotRoots[g]);
        }
        // ERC-8421 staking must be done by the vault itself (the registry keys on msg.sender). Doing
        // it here avoids a bootstrap loop: the vault's first frame tx already needs the stake.
        if (stakeAmount > 0) STAKING.addStake{value: stakeAmount}(init.unstakeDelay);
    }

    receive() external payable {}

    // =================================================================== VERIFY frame
    /// @notice Frame-0 entry. Runs as a STATICCALL; the only side effect is APPROVE.
    function validate() external {
        (Ctx memory c, bytes memory entry) = _introspect(0, 1);
        if (c.curFrame != 0 || c.frameCount != 2 || c.sigCount != 2) revert BadShape();
        // Bind the approval to the frame list: frame 1 must be execute() on this vault with no flags,
        // so nothing can act as the vault without passing the second-guardian check in execute().
        if (
            c.fMode != MODE_SENDER || c.fTarget != uint256(uint160(address(this)))
                || bytes4(c.fWord0) != this.execute.selector || c.fFlags != 0
        ) revert BadShape();
        if (c.maxCost > MAX_TX_COST) revert TxTooExpensive();

        (, bytes memory entryB) = _introspect(1, type(uint256).max);
        bytes32 m = firstMessageFor(c.sigHash, keccak256(entryB));
        Approval memory a = _check(c, entry, true, type(uint8).max, m);
        if (a.reason == R_STALE) revert StaleLeaf(a.slotId, a.q);
        if (a.reason != 0) revert BadEntry(a.reason);

        _approve(SCOPE_EXECUTION_AND_PAYMENT);
    }

    // =================================================================== SENDER frame
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Frame-1 entry: second guardian check, leaf accounting, then the batch.
    function execute(Call[] calldata calls) external onlySelf {
        (Ctx memory c0, bytes memory e0) = _introspect(0, type(uint256).max);
        // Entry 0 was fully verified by validate() in frame 0 of this same transaction (a SENDER frame
        // runs only after that approval, and validate() pins frame 1 to this function); decode only.
        Approval memory a = _decode(c0, e0);
        if (a.reason != 0) revert BadEntry(a.reason); // unreachable after validate(); defensive
        if (address(LEDGER) != address(0) && a.kind == SIG_COMPACT) LEDGER.consume(a.slotId, a.q);

        (Ctx memory c1, bytes memory e1) = _introspect(1, type(uint256).max);
        Approval memory b = _check(c1, e1, false, a.guardian, messageFor(c1.sigHash));
        if (b.reason != 0) {
            emit SecondApprovalRejected(c0.sigHash, a.guardian, b.reason);
            return; // keep leaf A consumed; execute nothing
        }
        if (address(LEDGER) != address(0) && b.kind == SIG_COMPACT) LEDGER.consume(b.slotId, b.q);

        try this.runBatch(calls) {
            emit Executed(c0.sigHash, a.guardian, b.guardian, b.kind, calls.length);
        } catch (bytes memory reason) {
            emit BatchFailed(c0.sigHash, reason);
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

    /// @notice Key-loss recovery / guardian replacement: the other two guardians install new master and
    ///         slot keys for `g`. Bumping the epoch revokes every slot `g` held before.
    function replaceGuardian(uint8 g, Guardian calldata master, bytes16 slotSeed, bytes16 slotRoot)
        external
        onlySelf
    {
        if (g >= N_GUARDIANS) revert BadGuardian();
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

    /// @notice What the second guardian (signature entry 1) signs.
    function messageFor(bytes32 sigHash) public pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, sigHash));
    }

    /// @notice What the first guardian (signature entry 0, checked in VERIFY) signs: it also commits to the
    ///         exact bytes of entry 1, so entry 1 cannot be altered in the mempool.
    function firstMessageFor(bytes32 sigHash, bytes32 entryBHash) public pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, sigHash, entryBHash));
    }

    // =================================================================== internals
    function _setGuardian(uint8 g, Guardian memory m) private {
        _requireCanonical(m.spxSeed, m.spxRoot);
        _guardians[g] = m;
    }

    function _registerSlot(uint8 g, bytes16 seed, bytes16 root) private {
        if (g >= N_GUARDIANS) revert BadGuardian();
        _requireCanonical(bytes32(seed), bytes32(root));
        if (seed == bytes16(0) && root == bytes16(0)) revert NonCanonicalKey();
        bytes32 slotId = keccak256(abi.encodePacked(seed, root));
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

    /// Structural decode of an entry (no cryptography).
    function _decode(Ctx memory c, bytes memory e) private view returns (Approval memory a) {
        if (c.scheme != SCHEME_ARBITRARY || c.msgWord != 0) {
            a.reason = R_SCHEME;
            return a;
        }
        if (e.length < 2) {
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
            uint256 forsLen = e.length < COMPACT_HDR ? 0 : e.length - COMPACT_HDR;
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
                q := byte(0, mload(add(p, add(COMPACT_HDR, 2592))))
            }
            a.slotId = slotId;
            a.q = q;
        } else if (a.kind == SIG_STATELESS) {
            if (e.length != 2 + SPX_LEN) a.reason = R_LENGTH;
        } else {
            a.reason = R_KIND;
        }
    }

    /// Full check of one entry against the transaction's canonical signature hash.
    /// @param compactOnly validate() only accepts the compact path (the stateless path does not fit 100k).
    /// @param otherGuardian guardian that already approved (type(uint8).max if none): must differ.
    function _check(Ctx memory c, bytes memory e, bool compactOnly, uint8 otherGuardian, bytes32 m)
        private
        view
        returns (Approval memory a)
    {
        a = _decode(c, e);
        if (a.reason != 0) return a;
        if (a.guardian == otherGuardian) {
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
            if (compactOnly) {
                a.reason = R_KIND;
                return a;
            }
            Guardian storage g = _guardians[a.guardian];
            if (!_staticVerify(address(SPX), IJardinSpx.verify.selector, g.spxSeed, g.spxRoot, m, e, 2)) {
                a.reason = R_SIG;
            }
        }
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

    /// One call to PQVaultFrameOps: 12 context words + the signature entry bytes. The returned `entry`
    /// aliases the tail of the return buffer, so the 384 bytes in front of it are scratch for _staticVerify.
    function _introspect(uint256 sigIndex, uint256 frameIndex) private view returns (Ctx memory c, bytes memory entry) {
        (bool ok, bytes memory out) = FRAME_OPS.staticcall(abi.encode(uint256(0), sigIndex, frameIndex));
        if (!ok || out.length < 384) revert FrameOpsFailed();
        assembly {
            let src := add(out, 0x20)
            for { let i := 0 } lt(i, 384) { i := add(i, 0x20) } { mstore(add(c, i), mload(add(src, i))) }
        }
        if (out.length != 384 + c.sigLen) revert FrameOpsFailed();
        uint256 len = c.sigLen;
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
