// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVaultRegistry {
    function isVault(address account) external view returns (bool);
}

interface IForsPlainVerifier {
    function verifyForsPlain(bytes32 pkSeed, bytes32 pkRoot, bytes32 message, bytes calldata sig)
        external
        pure
        returns (bool);
}

/// @title LeafLedger — chain-anchored high-water marks for stateful JARDIN compact slots
/// @notice A JARDIN compact slot is a Merkle tree of 2^h few-time FORS keys; the signer must never
///         sign two different messages with the same leaf q. Upstream JARDIN keeps q only on the
///         device (no on-chain counter, no SSTORE on the compact path), so a device restored from a
///         stale backup, cloned, or rolled back can re-sign a consumed leaf and the chain cannot tell.
///
///         The ledger records, per slot (keyed by keccak256(seed16 ‖ root16), *not* by account), the
///         highest leaf any PQ-Vault has consumed, and only accepts strictly increasing q. Keying by
///         slot means one guardian device that guards several vaults shares a single counter, so a
///         leaf cannot be spent once per vault.
///
///         Reading `hwm` from a vault's VERIFY frame touches storage that is not associated with the
///         sender, which the EIP-8141 canonical mempool rejects and the ERC-8421 alternative mempool
///         admits for a staked sender.
///
///         Writes come only from vaults deployed by the registry (factory). A PQ-Vault calls `consume`
///         only for a slot whose signature over the current transaction it has verified, so a slot's
///         mark can only be advanced with that slot's own signature.
///
///         Equivocation reports close the case the high-water mark cannot: two live copies of one
///         device state (a clone) signing the *same* fresh leaf for different messages. Anyone who sees
///         both signatures (they are public once broadcast) can submit them; the ledger checks both with
///         the JARDIN verifier and revokes the slot by setting its mark to the maximum, so every vault
///         rejects it from then on (zero extra gas on the vault's validation path). Only the slot's key
///         holder can produce such a pair, so a report cannot be forged to grief an honest slot.
contract LeafLedger {
    IVaultRegistry public immutable registry;
    IForsPlainVerifier public immutable forsVerifier;
    uint256 public constant REVOKED = type(uint256).max;

    /// Highest consumed leaf index (JARDIN q is 1-based); 0 = no leaf consumed.
    mapping(bytes32 slotId => uint256) public hwm;

    event LeafConsumed(bytes32 indexed slotId, uint256 q, address indexed vault);
    event SlotRevokedForEquivocation(bytes32 indexed slotId, uint256 q, address reporter);

    error NotVault();
    error StaleLeaf(bytes32 slotId, uint256 q, uint256 highWaterMark);
    error NotEquivocation();

    constructor(IVaultRegistry registry_, IForsPlainVerifier forsVerifier_) {
        registry = registry_;
        forsVerifier = forsVerifier_;
    }

    function isRevoked(bytes32 slotId) external view returns (bool) {
        return hwm[slotId] == REVOKED;
    }

    /// @notice Permissionless: prove that slot (seed, root) signed two different messages with the same
    ///         leaf, and revoke it everywhere. `sigA`/`sigB` are JARDIN plain-FORS signatures; the leaf
    ///         index q is the byte at offset 2592 of each.
    function reportEquivocation(
        bytes16 seed,
        bytes16 root,
        bytes32 msgA,
        bytes calldata sigA,
        bytes32 msgB,
        bytes calldata sigB
    ) external {
        if (msgA == msgB || sigA.length < 2593 || sigB.length < 2593 || sigA[2592] != sigB[2592]) {
            revert NotEquivocation();
        }
        if (
            !forsVerifier.verifyForsPlain(bytes32(seed), bytes32(root), msgA, sigA)
                || !forsVerifier.verifyForsPlain(bytes32(seed), bytes32(root), msgB, sigB)
        ) revert NotEquivocation();
        bytes32 slotId = keccak256(abi.encodePacked(seed, root));
        hwm[slotId] = REVOKED;
        emit SlotRevokedForEquivocation(slotId, uint8(sigA[2592]), msg.sender);
    }

    function consume(bytes32 slotId, uint256 q) external {
        if (!registry.isVault(msg.sender)) revert NotVault();
        uint256 h = hwm[slotId];
        if (q <= h) revert StaleLeaf(slotId, q, h);
        hwm[slotId] = q;
        emit LeafConsumed(slotId, q, msg.sender);
    }
}
