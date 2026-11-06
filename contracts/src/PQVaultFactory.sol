// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LeafLedger, IVaultRegistry, IForsPlainVerifier} from "./LeafLedger.sol";
import {PQVault} from "./PQVault.sol";

/// @title PQVaultFactory — deploys PQ-Vaults (CREATE2) and owns the shared LeafLedger
contract PQVaultFactory is IVaultRegistry {
    address public immutable frameOps;
    address public immutable forsVerifier;
    address public immutable spxVerifier;
    address public immutable stakingRegistry;
    LeafLedger public immutable ledger;

    mapping(address => bool) public isVault;

    event VaultDeployed(address indexed vault, bytes32 salt, bool leafLedger);

    constructor(address frameOps_, address fors_, address spx_, address stakingRegistry_) {
        frameOps = frameOps_;
        forsVerifier = fors_;
        spxVerifier = spx_;
        stakingRegistry = stakingRegistry_;
        ledger = new LeafLedger(this, IForsPlainVerifier(fors_));
    }

    /// @param useLedger false deploys the JARDIN-baseline variant (no on-chain leaf tracking), kept
    ///        for the adversarial comparison in research/; production vaults use the ledger.
    function deploy(bytes32 salt, PQVault.Init calldata init, bool useLedger, uint256 stakeAmount)
        external
        payable
        returns (PQVault vault)
    {
        vault = new PQVault{salt: salt, value: msg.value}(
            PQVault.Deps({
                frameOps: frameOps,
                fors: forsVerifier,
                spx: spxVerifier,
                ledger: useLedger ? address(ledger) : address(0),
                staking: stakingRegistry
            }),
            init,
            stakeAmount
        );
        isVault[address(vault)] = true;
        emit VaultDeployed(address(vault), salt, useLedger);
    }
}
