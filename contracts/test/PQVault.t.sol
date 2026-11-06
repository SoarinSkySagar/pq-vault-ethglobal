// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TestBase, Vm} from "./utils/TestBase.sol";
import {MockFrameOps} from "./mocks/MockFrameOps.sol";
import {CodeBlobFrameOps} from "./mocks/CodeBlobFrameOps.sol";
import {PQVault} from "../src/PQVault.sol";
import {PQVaultFactory} from "../src/PQVaultFactory.sol";
import {LeafLedger} from "../src/LeafLedger.sol";
import {JardinForsPlainVerifier} from "jardin/JardinForsPlainVerifier.sol";
import {JardinSpxVerifier} from "jardin/JardinSpxVerifier.sol";

contract Sink {
    uint256 public pings;

    function ping() external payable {
        pings++;
    }

    function boom() external pure {
        revert("boom");
    }

    receive() external payable {}
}

/// Real JARDIN signatures (fixtures from test/fixtures/gen_fixtures.py, produced by the upstream
/// JARDIN Python signers) verified by the real upstream JARDIN verifier contracts. Only the EIP-8141
/// opcodes are simulated (MockFrameOps).
contract PQVaultTest is TestBase {
    event log_named_uint(string key, uint256 val);

    address constant ENTRY_POINT = address(0xaa);
    uint256 constant MAX_COST = 0.05 ether;

    MockFrameOps ops;
    PQVaultFactory factory;
    LeafLedger ledger;
    PQVault vault; // with LeafLedger (PQ-Vault)
    PQVault baseline; // without on-chain leaf tracking (JARDIN behaviour)
    Sink sink;

    function setUp() public {
        ops = new MockFrameOps();
        factory = new PQVaultFactory(
            address(ops), address(new JardinForsPlainVerifier()), address(new JardinSpxVerifier()), address(0)
        );
        ledger = factory.ledger();
        vault = factory.deploy{value: 10 ether}(bytes32("pq-vault"), _init(), true, 0);
        baseline = factory.deploy{value: 10 ether}(bytes32("baseline"), _init(), false, 0);
        sink = new Sink();
    }

    // ------------------------------------------------------------------ helpers
    /// Read on demand (cheatcode, no gas): keeping 116 KB of JSON in storage would cost ~80M gas.
    function _fx() internal view returns (string memory) {
        return vm.readFile("test/fixtures/vault_fixtures.json");
    }

    function _j(string memory k) internal view returns (bytes memory) {
        return vm.parseJsonBytes(_fx(), string.concat(".", k));
    }

    function _j32(string memory k) internal view returns (bytes32) {
        return vm.parseJsonBytes32(_fx(), string.concat(".", k));
    }

    function _init() internal view returns (PQVault.Init memory init) {
        for (uint256 i = 0; i < 3; i++) {
            string memory g = string.concat("g", _d(i));
            init.guardians[i] = PQVault.Guardian(_j32(string.concat(g, "_spxSeed")), _j32(string.concat(g, "_spxRoot")));
            init.slotSeeds[i] = bytes16(_j(string.concat(g, "_slotSeed")));
            init.slotRoots[i] = bytes16(_j(string.concat(g, "_slotRoot")));
        }
        init.maxTxCost = MAX_COST;
        init.unstakeDelay = 86400;
    }

    function _d(uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked(bytes1(uint8(48 + i))));
    }

    function _transfer(uint256 amount) internal view returns (PQVault.Call[] memory calls) {
        calls = new PQVault.Call[](1);
        calls[0] = PQVault.Call(address(sink), amount, "");
    }

    /// Configure the simulated frame transaction for scenario `s` targeting vault `v`.
    function _load(PQVault v, string memory s, PQVault.Call[] memory calls) internal returns (bytes memory e0) {
        ops.reset(_j32(string.concat(s, "_sigHash")), MAX_COST, 0);
        bytes memory execData = abi.encodeCall(PQVault.execute, (calls));
        ops.addFrame(1, address(v), bytes32(abi.encodeCall(PQVault.validate, ())), 3);
        ops.addFrame(2, address(v), bytes32(execData), 0);
        e0 = _j(string.concat(s, "_e0"));
        ops.addSig(e0);
        ops.addSig(_j(string.concat(s, "_e1")));
    }

    function _approvedScope(PQVault v) internal view returns (uint256) {
        return uint256(vm.load(address(v), ops.APPROVED_SLOT()));
    }

    /// Full transaction: VERIFY (frame 0) must approve, then the SENDER frame runs execute().
    function _run(PQVault v, string memory s, PQVault.Call[] memory calls) internal {
        _load(v, s, calls);
        vm.store(address(v), ops.APPROVED_SLOT(), 0);
        vm.prank(ENTRY_POINT);
        v.validate();
        assertEq(_approvedScope(v), 3, "VERIFY must APPROVE execution+payment");
        ops.reset(_j32(string.concat(s, "_sigHash")), MAX_COST, 1); // now executing frame 1
        ops.addFrame(1, address(v), bytes32(abi.encodeCall(PQVault.validate, ())), 3);
        ops.addFrame(2, address(v), bytes32(abi.encodeCall(PQVault.execute, (calls))), 0);
        ops.addSig(_j(string.concat(s, "_e0")));
        ops.addSig(_j(string.concat(s, "_e1")));
        vm.prank(address(v));
        v.execute(calls);
    }

    function _lastRejectReason() internal returns (bool found, uint256 reason) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 t = keccak256("SecondApprovalRejected(bytes32,uint8,uint8)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == t) {
                (, reason) = abi.decode(logs[i].data, (uint8, uint8));
                found = true;
            }
        }
    }

    // ------------------------------------------------------------------ guardian authorization
    function test_twoGuardiansCompact_executes() public {
        uint256 before = address(sink).balance;
        _run(vault, "happy", _transfer(1 ether));
        assertEq(address(sink).balance - before, 1 ether, "transfer executed");
        assertEq(ledger.hwm(_j32("g0_slotId")), 1, "guardian 0 leaf 1 recorded");
        assertEq(ledger.hwm(_j32("g1_slotId")), 1, "guardian 1 leaf 1 recorded");
    }

    function test_statelessSecondApproval_executes() public {
        _run(vault, "stateless", _transfer(2 ether));
        assertEq(address(sink).balance, 2 ether, "transfer executed with SPX second approval");
        assertEq(ledger.hwm(_j32("g0_slotId")), 2, "compact leaf recorded");
    }

    function test_sameGuardianTwice_executesNothing() public {
        vm.recordLogs();
        _run(vault, "sameGuardian", _transfer(1 ether));
        (bool found, uint256 reason) = _lastRejectReason();
        assertTrue(found && reason == 3, "R_GUARDIAN");
        assertEq(address(sink).balance, 0, "nothing executed");
        assertEq(ledger.hwm(_j32("g0_slotId")), 3, "first guardian's leaf still consumed");
    }

    function test_secondSignatureOverOtherTx_executesNothing() public {
        vm.recordLogs();
        _run(vault, "wrongMsg", _transfer(1 ether));
        (bool found, uint256 reason) = _lastRejectReason();
        assertTrue(found && reason == 7, "R_SIG");
        assertEq(address(sink).balance, 0, "nothing executed");
    }

    function test_tamperedFirstSignature_notApproved() public {
        bytes memory e0 = _load(vault, "happy", _transfer(1 ether));
        e0[100] = bytes1(uint8(e0[100]) ^ 1);
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), bytes32(abi.encodeCall(PQVault.validate, ())), 3);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1 ether)))), 0);
        ops.addSig(e0);
        ops.addSig(_j("happy_e1"));
        vm.expectRevert(abi.encodeWithSelector(PQVault.BadEntry.selector, uint8(7)));
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    /// Entry 1 bytes are elided from the canonical sig hash, so a relayer could alter them; guardian A's
    /// signature commits to them, so the altered copy no longer validates.
    function test_mutatedSecondEntry_notApproved() public {
        _load(vault, "happy", _transfer(1 ether));
        bytes memory e1 = _j("happy_e1");
        e1[50] = bytes1(uint8(e1[50]) ^ 1);
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), bytes32(0), 3);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1 ether)))), 0);
        ops.addSig(_j("happy_e0"));
        ops.addSig(e1);
        vm.expectRevert(abi.encodeWithSelector(PQVault.BadEntry.selector, uint8(7)));
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    function test_nonArbitraryScheme_notApproved() public {
        _load(vault, "happy", _transfer(1 ether));
        ops.setScheme(1);
        vm.expectRevert(abi.encodeWithSelector(PQVault.BadEntry.selector, uint8(1)));
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    // ------------------------------------------------------------------ approval bound to frames
    function test_validate_rejectsForeignBodyFrame() public {
        _load(vault, "happy", _transfer(1 ether));
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), bytes32(0), 3);
        // A SENDER frame straight to another contract would act as the vault with one signature.
        ops.addFrame(2, address(sink), bytes32(abi.encodeCall(Sink.ping, ())), 0);
        ops.addSig(_j("happy_e0"));
        ops.addSig(_j("happy_e1"));
        vm.expectRevert(PQVault.BadShape.selector);
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    function test_validate_rejectsExtraFrameOrFlags() public {
        _load(vault, "happy", _transfer(1 ether));
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1))))
            , 0);
        vm.expectRevert(PQVault.BadShape.selector);
        vm.prank(ENTRY_POINT);
        vault.validate();

        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), bytes32(0), 3);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1)))), 4); // atomic flag
        ops.addSig(_j("happy_e0"));
        ops.addSig(_j("happy_e1"));
        vm.expectRevert(PQVault.BadShape.selector);
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    function test_validate_capsTransactionCost() public {
        _load(vault, "happy", _transfer(1 ether));
        ops.reset(_j32("happy_sigHash"), MAX_COST + 1, 0);
        ops.addFrame(1, address(vault), bytes32(0), 3);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1 ether)))), 0);
        ops.addSig(_j("happy_e0"));
        ops.addSig(_j("happy_e1"));
        vm.expectRevert(PQVault.TxTooExpensive.selector);
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    // ------------------------------------------------------------------ replay / rollback protection
    function test_rolledBackLeaf_rejectedAtValidation() public {
        _run(vault, "happy", _transfer(1 ether)); // g0 leaf 1
        _run(vault, "stateless", _transfer(1 ether)); // g0 leaf 2
        _load(vault, "rollback", _transfer(5 ether)); // g0 re-signs leaf 2 for another tx
        vm.expectRevert(abi.encodeWithSelector(PQVault.StaleLeaf.selector, _j32("g0_slotId"), uint256(2)));
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    /// Same sequence against the baseline (no on-chain leaf state): the reused leaf is accepted.
    function test_baseline_acceptsRolledBackLeaf() public {
        _run(baseline, "happy", _transfer(1 ether));
        _run(baseline, "stateless", _transfer(1 ether));
        _run(baseline, "rollback", _transfer(5 ether));
        assertEq(address(sink).balance, 7 ether, "baseline executed a tx signed with a reused FORS leaf");
    }

    function test_rolledBackSecondApproval_executesNothing() public {
        _run(vault, "happy", _transfer(1 ether)); // g0 leaf 1 consumed
        vm.recordLogs();
        _run(vault, "rollbackSecond", _transfer(1 ether)); // second approval = g0 leaf 1 again
        (bool found, uint256 reason) = _lastRejectReason();
        assertTrue(found && reason == 6, "R_STALE");
        assertEq(address(sink).balance, 1 ether, "second transfer not executed");
        assertEq(ledger.hwm(_j32("g1_slotId")), 3, "first approval's leaf consumed");
    }

    function test_ledger_onlyFactoryVaults() public {
        vm.expectRevert(LeafLedger.NotVault.selector);
        ledger.consume(bytes32(uint256(1)), 1);
    }

    function test_execute_onlySelf() public {
        vm.expectRevert(PQVault.NotSelf.selector);
        vault.execute(_transfer(1 ether));
        vm.expectRevert(PQVault.NotSelf.selector);
        vault.registerSlot(0, bytes16(uint128(1) << 64), bytes16(uint128(1) << 64));
    }

    function test_failedBatch_stillConsumesLeaves() public {
        PQVault.Call[] memory calls = new PQVault.Call[](2);
        calls[0] = PQVault.Call(address(sink), 1 ether, "");
        calls[1] = PQVault.Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        _run(vault, "happy", calls);
        assertEq(address(sink).balance, 0, "batch is atomic");
        assertEq(ledger.hwm(_j32("g0_slotId")), 1, "leaf A consumed");
        assertEq(ledger.hwm(_j32("g1_slotId")), 1, "leaf B consumed");
    }

    // ------------------------------------------------------------------ key loss recovery & rotation
    function test_recovery_replacesLostGuardian_andRevokesOldSlots() public {
        PQVault.Call[] memory calls = new PQVault.Call[](1);
        calls[0] = PQVault.Call(
            address(vault),
            0,
            abi.encodeCall(
                PQVault.replaceGuardian,
                (
                    2,
                    PQVault.Guardian(_j32("g2new_spxSeed"), _j32("g2new_spxRoot")),
                    bytes16(_j("g2new_slotSeed")),
                    bytes16(_j("g2new_slotRoot"))
                )
            )
        );
        _run(vault, "recovery", calls); // guardians 0 and 1 replace guardian 2
        assertEq(vault.epochOf(2), 1, "epoch bumped");
        (bool oldActive,) = vault.slotGuardian(_j32("g2_slotId"));
        (bool newActive, uint8 g) = vault.slotGuardian(_j32("g2new_slotId"));
        assertTrue(!oldActive && newActive && g == 2, "old slot revoked, new slot active");
        assertEq(vault.guardian(2).spxSeed, _j32("g2new_spxSeed"), "master key rotated");

        _load(vault, "oldSlotAfterRecovery", _transfer(1 ether));
        vm.expectRevert(abi.encodeWithSelector(PQVault.BadEntry.selector, uint8(5)));
        vm.prank(ENTRY_POINT);
        vault.validate();

        _run(vault, "newSlotAfterRecovery", _transfer(1 ether));
        assertEq(address(sink).balance, 1 ether, "replacement guardian can approve");
    }

    // ------------------------------------------------------------------ equivocation reports (clone defence)
    function _fors(bytes memory entry) internal pure returns (bytes memory out) {
        out = new bytes(entry.length - 34);
        for (uint256 i = 0; i < out.length; i++) out[i] = entry[i + 34];
    }

    /// Message signed by entry 0 of scenario `s`.
    function _m0(string memory s) internal view returns (bytes32) {
        return vault.firstMessageFor(_j32(string.concat(s, "_sigHash")), keccak256(_j(string.concat(s, "_e1"))));
    }

    function _report(string memory a, string memory b) internal {
        bytes memory ea = _j(string.concat(a, "_e0"));
        bytes memory eb = _j(string.concat(b, "_e0"));
        bytes32 ma = _m0(a);
        bytes32 mb = _m0(b);
        ledger.reportEquivocation(bytes16(_j("g0_slotSeed")), bytes16(_j("g0_slotRoot")), ma, _fors(ea), mb, _fors(eb));
    }

    function test_equivocation_revokesSlotEverywhere() public {
        // guardian 0 signed leaf 2 for two different transactions (a cloned / rolled-back device)
        _report("stateless", "rollback");
        assertTrue(ledger.isRevoked(_j32("g0_slotId")), "slot revoked");
        _load(vault, "happy", _transfer(1 ether)); // even a never-used leaf of that slot is now refused
        vm.expectRevert(abi.encodeWithSelector(PQVault.StaleLeaf.selector, _j32("g0_slotId"), uint256(1)));
        vm.prank(ENTRY_POINT);
        vault.validate();
    }

    function test_equivocation_rejectsNonProofs() public {
        bytes memory e = _j("stateless_e0");
        bytes32 m = _m0("stateless");
        bytes16 seed = bytes16(_j("g0_slotSeed"));
        bytes16 root = bytes16(_j("g0_slotRoot"));
        vm.expectRevert(LeafLedger.NotEquivocation.selector); // same message twice
        ledger.reportEquivocation(seed, root, m, _fors(e), m, _fors(e));
        bytes memory e1 = _fors(_j("happy_e0"));
        bytes32 m1 = _m0("happy");
        vm.expectRevert(LeafLedger.NotEquivocation.selector); // different leaves (q=1 vs q=2)
        ledger.reportEquivocation(seed, root, m1, e1, m, _fors(e));
        bytes memory bad = _fors(_j("rollback_e0"));
        bad[200] = bytes1(uint8(bad[200]) ^ 1);
        bytes32 mr = _m0("rollback");
        bytes memory fe = _fors(e);
        vm.expectRevert(LeafLedger.NotEquivocation.selector); // forged second signature
        ledger.reportEquivocation(seed, root, m, fe, mr, bad);
        assertTrue(!ledger.isRevoked(_j32("g0_slotId")), "honest slot not revoked");
    }

    // ------------------------------------------------------------------ gas (mocked opcodes)
    function test_gas_validate() public {
        _load(vault, "happy", _transfer(1 ether));
        (bool ok0, bytes memory r0) = address(ops).staticcall(abi.encode(uint256(0), uint256(0), uint256(1)));
        (bool ok1, bytes memory r1) = address(ops).staticcall(abi.encode(uint256(0), uint256(1), type(uint256).max));
        require(ok0 && ok1, "mock");
        // Swap in a helper whose cost profile matches the real 175-byte Yul helper.
        vm.etch(address(ops), address(new CodeBlobFrameOps(r0, r1)).code);
        vm.recordLogs();
        uint256 g = gasleft();
        vm.prank(ENTRY_POINT);
        vault.validate();
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length == 1 && logs[0].emitter == address(vault), "APPROVE ran in the vault's context");
        emit log_named_uint("validate() gas (gas-faithful FrameOps stand-in)", g);
        assertTrue(g < 100_000, "validate must fit MAX_VERIFY_GAS");
    }
}
