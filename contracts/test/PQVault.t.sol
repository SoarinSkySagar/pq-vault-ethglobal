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
/// opcodes are simulated (MockFrameOps). A transaction is run frame by frame: VERIFY frame 0
/// (validate [0,k), APPROVE execution), VERIFY frame 1 (validate [k,t), APPROVE payment), SENDER frame 2.
contract PQVaultTest is TestBase {
    event log_named_uint(string key, uint256 val);

    address constant ENTRY_POINT = address(0xaa);
    uint256 constant MAX_COST = 0.05 ether;
    uint256 constant NONE = type(uint256).max;
    uint8 constant R_GUARDIAN = 3;
    uint8 constant R_SLOT = 5;
    uint8 constant R_SIG = 7;

    MockFrameOps ops;
    PQVaultFactory factory;
    LeafLedger ledger;
    PQVault vault; // 2-of-3 with LeafLedger (PQ-Vault)
    PQVault baseline; // 2-of-3 without on-chain leaf tracking (JARDIN behaviour)
    PQVault vault34; // 3-of-4 with LeafLedger
    Sink sink;

    function setUp() public {
        ops = new MockFrameOps();
        factory = new PQVaultFactory(
            address(ops), address(new JardinForsPlainVerifier()), address(new JardinSpxVerifier()), address(0)
        );
        ledger = factory.ledger();
        vault = factory.deploy{value: 10 ether}(bytes32("pq-vault"), _init(3, 2), true, 0);
        baseline = factory.deploy{value: 10 ether}(bytes32("baseline"), _init(3, 2), false, 0);
        vault34 = factory.deploy{value: 10 ether}(bytes32("pq-vault-3of4"), _init(4, 3), true, 0);
        sink = new Sink();
    }

    // ------------------------------------------------------------------ helpers
    /// Read on demand (cheatcode, no gas): keeping 150 KB of JSON in storage would cost ~100M gas.
    function _fx() internal view returns (string memory) {
        return vm.readFile("test/fixtures/vault_fixtures.json");
    }

    /// Each read materialises the whole fixture file in memory, and EVM memory never shrinks, so the
    /// helpers below give the scratch space back (reset the free-memory pointer) after every read.
    function _j(string memory k) internal view returns (bytes memory out) {
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        bytes memory r = vm.parseJsonBytes(_fx(), string.concat(".", k));
        assembly {
            // move r down to fmp (dest < src, so a forward word copy is safe), then free the rest
            let words := add(div(add(mload(r), 31), 32), 1)
            for { let i := 0 } lt(i, words) { i := add(i, 1) } {
                mstore(add(fmp, mul(i, 32)), mload(add(r, mul(i, 32))))
            }
            out := fmp
            mstore(0x40, add(fmp, mul(words, 32)))
        }
    }

    function _j32(string memory k) internal view returns (bytes32 v) {
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        v = vm.parseJsonBytes32(_fx(), string.concat(".", k));
        assembly {
            mstore(0x40, fmp)
        }
    }

    function _jn(string memory k) internal view returns (uint256 v) {
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        v = vm.parseJsonUint(_fx(), string.concat(".", k));
        assembly {
            mstore(0x40, fmp)
        }
    }

    function _e(string memory s, uint256 i) internal view returns (bytes memory) {
        return _j(string.concat(s, "_e", _d(i)));
    }

    function _init(uint256 n, uint8 t) internal view returns (PQVault.Init memory init) {
        init.guardians = new PQVault.Guardian[](n);
        init.slotSeeds = new bytes16[](n);
        init.slotRoots = new bytes16[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory g = string.concat("g", _d(i));
            init.guardians[i] = PQVault.Guardian(_j32(string.concat(g, "_spxSeed")), _j32(string.concat(g, "_spxRoot")));
            init.slotSeeds[i] = bytes16(_j(string.concat(g, "_slotSeed")));
            init.slotRoots[i] = bytes16(_j(string.concat(g, "_slotRoot")));
        }
        init.threshold = t;
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

    function _vdata(uint256 from, uint256 to) internal pure returns (bytes memory) {
        return abi.encodePacked(PQVault.validate.selector, uint8(from), uint8(to));
    }

    function _vword(uint256 from, uint256 to) internal pure returns (bytes32) {
        return bytes32(_vdata(from, to));
    }

    /// The canonical three frames for vault `v` with threshold `t`, split at `k`.
    function _frames(PQVault v, uint256 k, uint256 t, PQVault.Call[] memory calls) internal {
        ops.addFrame(1, address(v), _vword(0, k), 2); // VERIFY, scope EXECUTION (only_verify)
        ops.addFrame(1, address(v), _vword(k, t), 1); // VERIFY, scope PAYMENT (pay)
        ops.addFrame(2, address(v), bytes32(abi.encodeCall(PQVault.execute, (calls))), 0); // SENDER
    }

    /// Configure the simulated frame transaction for scenario `s` (all of its entries) on vault `v`.
    function _load(PQVault v, string memory s, uint256 k, PQVault.Call[] memory calls) internal {
        uint256 n = _jn(string.concat(s, "_n"));
        ops.reset(_j32(string.concat(s, "_sigHash")), MAX_COST, 0);
        _frames(v, k, v.THRESHOLD(), calls);
        for (uint256 i = 0; i < n; i++) {
            ops.addSig(_e(s, i));
        }
    }

    function _approvedScope(PQVault v) internal view returns (uint256) {
        return uint256(vm.load(address(v), ops.APPROVED_SLOT()));
    }

    /// Run VERIFY frame `f` (range [from, to)) as ENTRY_POINT; returns success and revert data.
    function _verify(PQVault v, uint256 f, uint256 from, uint256 to) internal returns (bool ok, bytes memory ret) {
        ops.setCurFrame(f);
        vm.store(address(v), ops.APPROVED_SLOT(), 0);
        bytes memory data = _vdata(from, to);
        vm.prank(ENTRY_POINT);
        (ok, ret) = address(v).call(data);
    }

    function _expectVerifyRevert(PQVault v, uint256 f, uint256 from, uint256 to, bytes memory err) internal {
        (bool ok, bytes memory ret) = _verify(v, f, from, to);
        assertTrue(!ok, "VERIFY frame must revert");
        assertEq(keccak256(ret), keccak256(err), "revert reason");
    }

    function _verifyOk(PQVault v, uint256 f, uint256 from, uint256 to, uint256 scope) internal {
        (bool ok, bytes memory ret) = _verify(v, f, from, to);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assertEq(_approvedScope(v), scope, "VERIFY frame approved the wrong scope");
    }

    /// Full transaction: both VERIFY frames must approve, then the SENDER frame runs execute().
    function _run(PQVault v, string memory s, uint256 k, PQVault.Call[] memory calls) internal {
        uint256 t = v.THRESHOLD();
        _load(v, s, k, calls);
        _verifyOk(v, 0, 0, k, 2);
        _verifyOk(v, 1, k, t, 1);
        ops.setCurFrame(2);
        vm.prank(address(v));
        v.execute(calls);
    }

    function _badEntry(uint256 i, uint8 reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PQVault.BadEntry.selector, i, reason);
    }

    function _badShape() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PQVault.BadShape.selector);
    }

    // ------------------------------------------------------------------ guardian authorization (2-of-3)
    function test_twoGuardiansCompact_executes() public {
        uint256 before = address(sink).balance;
        _run(vault, "happy", 1, _transfer(1 ether));
        assertEq(address(sink).balance - before, 1 ether, "transfer executed");
        assertEq(ledger.hwm(_j32("g0_slotId")), 1, "guardian 0 leaf 1 consumed");
        assertEq(ledger.hwm(_j32("g1_slotId")), 1, "guardian 1 leaf 1 consumed");
    }

    function test_statelessApproval_executes() public {
        _run(vault, "stateless", 1, _transfer(2 ether));
        assertEq(address(sink).balance, 2 ether, "transfer executed with an SPX approval");
        assertEq(ledger.hwm(_j32("g0_slotId")), 2, "compact leaf consumed");
    }

    function test_sameGuardianTwice_invalid() public {
        _load(vault, "sameGuardian", 1, _transfer(1 ether));
        _verifyOk(vault, 0, 0, 1, 2);
        _expectVerifyRevert(vault, 1, 1, 2, _badEntry(1, R_GUARDIAN));
    }

    function test_approvalOverOtherTx_invalid() public {
        _load(vault, "wrongMsg", 1, _transfer(1 ether));
        _verifyOk(vault, 0, 0, 1, 2);
        _expectVerifyRevert(vault, 1, 1, 2, _badEntry(1, R_SIG));
    }

    function test_tamperedFirstSignature_invalid() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        bytes memory e0 = _e("happy", 0);
        e0[100] = bytes1(uint8(e0[100]) ^ 1);
        ops.setSig(0, e0);
        _expectVerifyRevert(vault, 0, 0, 1, _badEntry(0, R_SIG));
    }

    /// Entry bytes are elided from the canonical sig hash, so a relayer can alter any entry; every entry
    /// is verified in a VERIFY frame, so the altered copy is invalid and costs the vault nothing.
    function test_relayerMutatedEntry_invalid() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        bytes memory e1 = _e("happy", 1);
        e1[50] = bytes1(uint8(e1[50]) ^ 1);
        ops.setSig(1, e1);
        _verifyOk(vault, 0, 0, 1, 2);
        _expectVerifyRevert(vault, 1, 1, 2, _badEntry(1, R_SIG));
    }

    function test_nonArbitraryScheme_invalid() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        ops.setScheme(1);
        _expectVerifyRevert(vault, 0, 0, 1, _badEntry(0, 1));
    }

    // ------------------------------------------------------------------ approval bound to the frame list
    function test_validate_rejectsForeignBodyFrame() public {
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), _vword(0, 1), 2);
        ops.addFrame(1, address(vault), _vword(1, 2), 1);
        // A SENDER frame straight to another contract would act as the vault without execute().
        ops.addFrame(2, address(sink), bytes32(abi.encodeCall(Sink.ping, ())), 0);
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault, 0, 0, 1, _badShape());
        _expectVerifyRevert(vault, 1, 1, 2, _badShape());
    }

    function test_validate_rejectsExtraFrameOrFlags() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1)))), 0);
        _expectVerifyRevert(vault, 0, 0, 1, _badShape());

        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), _vword(0, 1), 2);
        ops.addFrame(1, address(vault), _vword(1, 2), 1);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1)))), 4); // atomic flag
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault, 0, 0, 1, _badShape());
    }

    /// The two VERIFY frames must partition [0, t): no entry may go unchecked, none may be checked by a
    /// frame that does not belong to this vault, and the peer frame must carry the matching scope.
    function test_validate_rejectsBadSplit() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        _expectVerifyRevert(vault, 0, 0, 2, _badShape()); // frame 0 claims everything
        _expectVerifyRevert(vault, 1, 0, 2, _badShape()); // frame 1 must start at k > 0
        _expectVerifyRevert(vault, 0, 1, 2, _badShape()); // frame 0 must start at 0

        // peer frame range disagrees: frame 1 says [0,2) while frame 0 says [0,1)
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), _vword(0, 1), 2);
        ops.addFrame(1, address(vault), _vword(0, 2), 1);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1)))), 0);
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault, 0, 0, 1, _badShape());

        // peer frame has the wrong scope (self_verify instead of pay)
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), _vword(0, 1), 2);
        ops.addFrame(1, address(vault), _vword(1, 2), 3);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1)))), 0);
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault, 0, 0, 1, _badShape());

        // peer VERIFY frame targets another account
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        ops.addFrame(1, address(vault), _vword(0, 1), 2);
        ops.addFrame(1, address(baseline), _vword(1, 2), 1);
        ops.addFrame(2, address(vault), bytes32(abi.encodeCall(PQVault.execute, (_transfer(1)))), 0);
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault, 0, 0, 1, _badShape());
    }

    function test_validate_rejectsWrongSignatureCount() public {
        // 2 entries against the 3-of-4 vault
        ops.reset(_j32("happy_sigHash"), MAX_COST, 0);
        _frames(vault34, 1, 3, _transfer(1));
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault34, 0, 0, 1, _badShape());
    }

    function test_validate_capsTransactionCost() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        ops.reset(_j32("happy_sigHash"), MAX_COST + 1, 0);
        _frames(vault, 1, 2, _transfer(1 ether));
        ops.addSig(_e("happy", 0));
        ops.addSig(_e("happy", 1));
        _expectVerifyRevert(vault, 0, 0, 1, abi.encodeWithSelector(PQVault.TxTooExpensive.selector));
    }

    // ------------------------------------------------------------------ t-of-n
    function test_threeOfFour_executes_splitAt1() public {
        _run(vault34, "threeOfFour", 1, _transfer(1 ether));
        assertEq(address(sink).balance, 1 ether, "3-of-4 transfer executed");
        assertEq(ledger.hwm(_j32("g0_slotId")), 1, "g0 leaf consumed");
        assertEq(ledger.hwm(_j32("g2_slotId")), 1, "g2 leaf consumed");
        assertEq(ledger.hwm(_j32("g3_slotId")), 1, "g3 leaf consumed");
    }

    function test_threeOfFour_executes_splitAt2() public {
        _run(vault34, "threeOfFour", 2, _transfer(1 ether));
        assertEq(address(sink).balance, 1 ether, "3-of-4 transfer executed");
        assertEq(ledger.hwm(_j32("g3_slotId")), 1, "g3 leaf consumed");
    }

    function test_config_rejectsBadThresholdsAndDuplicateKeys() public {
        PQVault.Init memory init = _init(3, 1);
        vm.expectRevert(PQVault.BadConfig.selector); // t < 2
        factory.deploy(bytes32("c1"), init, true, 0);
        init = _init(3, 4);
        vm.expectRevert(PQVault.BadConfig.selector); // t > n
        factory.deploy(bytes32("c2"), init, true, 0);
        init = _init(3, 2);
        init.guardians[2] = init.guardians[0];
        vm.expectRevert(PQVault.DuplicateKey.selector); // one master key as two guardians
        factory.deploy(bytes32("c3"), init, true, 0);
        init = _init(3, 2);
        init.slotSeeds[2] = init.slotSeeds[0];
        init.slotRoots[2] = init.slotRoots[0];
        vm.expectRevert(PQVault.DuplicateKey.selector); // one compact slot as two guardians
        factory.deploy(bytes32("c4"), init, true, 0);
    }

    function test_registerSlot_rejectsAnotherGuardiansSlot() public {
        bytes16 seed = bytes16(_j("g0_slotSeed"));
        bytes16 root = bytes16(_j("g0_slotRoot"));
        vm.expectRevert(PQVault.DuplicateKey.selector);
        vm.prank(address(vault));
        vault.registerSlot(1, seed, root);
    }

    // ------------------------------------------------------------------ replay / rollback protection
    function test_rolledBackLeaf_rejectedInFirstVerifyFrame() public {
        _run(vault, "happy", 1, _transfer(1 ether)); // g0 leaf 1
        _run(vault, "stateless", 1, _transfer(1 ether)); // g0 leaf 2
        _load(vault, "rollback", 1, _transfer(5 ether)); // g0 re-signs leaf 2 for another tx
        _expectVerifyRevert(
            vault, 0, 0, 1, abi.encodeWithSelector(PQVault.StaleLeaf.selector, _j32("g0_slotId"), uint256(2))
        );
    }

    function test_rolledBackLeaf_rejectedInSecondVerifyFrame() public {
        _run(vault, "happy", 1, _transfer(1 ether)); // g1 leaf 1 consumed
        _load(vault, "rollbackSecond", 1, _transfer(1 ether)); // g1 leaf 1 again
        _verifyOk(vault, 0, 0, 1, 2);
        _expectVerifyRevert(
            vault, 1, 1, 2, abi.encodeWithSelector(PQVault.StaleLeaf.selector, _j32("g1_slotId"), uint256(1))
        );
    }

    /// Same sequence against the baseline (no on-chain leaf state): the reused leaf is accepted.
    function test_baseline_acceptsRolledBackLeaf() public {
        _run(baseline, "happy", 1, _transfer(1 ether));
        _run(baseline, "stateless", 1, _transfer(1 ether));
        _run(baseline, "rollback", 1, _transfer(5 ether));
        assertEq(address(sink).balance, 7 ether, "baseline executed a tx signed with a reused FORS leaf");
    }

    /// A leaf consumed by another transaction after this one was validated (a race between two pending
    /// transactions) is caught by the SENDER frame's atomic check-and-update: nothing executes, and the
    /// other approvals' leaves are still consumed because their signatures are public.
    function test_leafRacedAfterValidation_executesNothing() public {
        PQVault.Call[] memory calls = _transfer(1 ether);
        _load(vault, "happy", 1, calls);
        _verifyOk(vault, 0, 0, 1, 2);
        _verifyOk(vault, 1, 1, 2, 1);
        bytes32 g1 = _j32("g1_slotId");
        vm.prank(address(vault34)); // another vault's transaction lands first with g1's leaf 1
        ledger.consume(g1, 1);
        ops.setCurFrame(2);
        vm.recordLogs();
        vm.prank(address(vault));
        vault.execute(calls);
        assertEq(address(sink).balance, 0, "nothing executed");
        assertEq(ledger.hwm(_j32("g0_slotId")), 1, "g0 leaf still consumed");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool raced;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PQVault.LeafRaced.selector) raced = true;
        }
        assertTrue(raced, "LeafRaced emitted");
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
        _run(vault, "happy", 1, calls);
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
        _run(vault, "recovery", 1, calls); // guardians 0 and 1 replace guardian 2
        assertEq(vault.epochOf(2), 1, "epoch bumped");
        (bool oldActive,) = vault.slotGuardian(_j32("g2_slotId"));
        (bool newActive, uint8 g) = vault.slotGuardian(_j32("g2new_slotId"));
        assertTrue(!oldActive && newActive && g == 2, "old slot revoked, new slot active");
        assertEq(vault.guardian(2).spxSeed, _j32("g2new_spxSeed"), "master key rotated");

        _load(vault, "oldSlotAfterRecovery", 1, _transfer(1 ether));
        _verifyOk(vault, 0, 0, 1, 2);
        _expectVerifyRevert(vault, 1, 1, 2, _badEntry(1, R_SLOT));

        _run(vault, "newSlotAfterRecovery", 1, _transfer(1 ether));
        assertEq(address(sink).balance, 1 ether, "replacement guardian can approve");
    }

    // ------------------------------------------------------------------ equivocation reports (clone defence)
    function _fors(bytes memory entry) internal pure returns (bytes memory out) {
        out = new bytes(entry.length - 34);
        for (uint256 i = 0; i < out.length; i++) out[i] = entry[i + 34];
    }

    function _m(string memory s) internal view returns (bytes32) {
        return vault.messageFor(_j32(string.concat(s, "_sigHash")));
    }

    function test_equivocation_revokesSlotEverywhere() public {
        // guardian 0 signed leaf 2 for two different transactions (a cloned / rolled-back device)
        bytes memory ea = _fors(_e("stateless", 0));
        bytes memory eb = _fors(_e("rollback", 0));
        bytes32 ma = _m("stateless");
        bytes32 mb = _m("rollback");
        ledger.reportEquivocation(bytes16(_j("g0_slotSeed")), bytes16(_j("g0_slotRoot")), ma, ea, mb, eb);
        assertTrue(ledger.isRevoked(_j32("g0_slotId")), "slot revoked");
        _load(vault, "happy", 1, _transfer(1 ether)); // even a never-used leaf of that slot is now refused
        _expectVerifyRevert(
            vault, 0, 0, 1, abi.encodeWithSelector(PQVault.StaleLeaf.selector, _j32("g0_slotId"), uint256(1))
        );
    }

    function test_equivocation_rejectsNonProofs() public {
        bytes memory e = _fors(_e("stateless", 0));
        bytes32 m = _m("stateless");
        bytes16 seed = bytes16(_j("g0_slotSeed"));
        bytes16 root = bytes16(_j("g0_slotRoot"));
        vm.expectRevert(LeafLedger.NotEquivocation.selector); // same message twice
        ledger.reportEquivocation(seed, root, m, e, m, e);
        bytes memory e1 = _fors(_e("happy", 0));
        bytes32 m1 = _m("happy");
        vm.expectRevert(LeafLedger.NotEquivocation.selector); // different leaves (q=1 vs q=2)
        ledger.reportEquivocation(seed, root, m1, e1, m, e);
        bytes memory bad = _fors(_e("rollback", 0));
        bad[200] = bytes1(uint8(bad[200]) ^ 1);
        bytes32 mr = _m("rollback");
        vm.expectRevert(LeafLedger.NotEquivocation.selector); // forged second signature
        ledger.reportEquivocation(seed, root, m, e, mr, bad);
        assertTrue(!ledger.isRevoked(_j32("g0_slotId")), "honest slot not revoked");
    }

    // ------------------------------------------------------------------ gas (mocked opcodes)
    /// Gas of one VERIFY frame, with a stand-in FrameOps whose cost profile matches the real Yul helper.
    function _gasVerify(PQVault v, uint256 f, uint256 from, uint256 to) internal returns (uint256 g) {
        ops.setCurFrame(f);
        // Every request validate() will make in this frame, answered by the configured mock first.
        bytes[] memory req = new bytes[](3 + to - from);
        uint256 r;
        req[r++] = abi.encode(uint256(0), NONE, uint256(2), uint256(0)); // body frame + tx context
        req[r++] = abi.encode(uint256(0), NONE, f == 0 ? uint256(1) : uint256(0), uint256(0)); // peer frame
        if (from > 0) req[r++] = abi.encode(uint256(0), from - 1, NONE, uint256(1)); // previous guardian byte
        for (uint256 i = from; i < to; i++) {
            req[r++] = abi.encode(uint256(0), i, NONE, NONE);
        }
        bytes[] memory reqs = new bytes[](r);
        bytes[] memory resp = new bytes[](r);
        for (uint256 i = 0; i < r; i++) {
            reqs[i] = req[i];
            (bool ok, bytes memory out) = address(ops).staticcall(req[i]);
            require(ok, "mock");
            resp[i] = out;
        }
        bytes memory mockCode = address(ops).code;
        vm.etch(address(ops), address(new CodeBlobFrameOps(reqs, resp)).code);
        bytes memory data = _vdata(from, to);
        vm.recordLogs();
        vm.prank(ENTRY_POINT);
        g = gasleft();
        (bool okv,) = address(v).call(data);
        g -= gasleft();
        assertTrue(okv, "validate");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length == 1 && logs[0].emitter == address(v), "APPROVE ran in the vault's context");
        vm.etch(address(ops), mockCode);
    }

    function test_gas_validate_twoOfThree() public {
        _load(vault, "happy", 1, _transfer(1 ether));
        uint256 g0 = _gasVerify(vault, 0, 0, 1);
        _load(vault, "happy", 1, _transfer(1 ether));
        uint256 g1 = _gasVerify(vault, 1, 1, 2);
        emit log_named_uint("2-of-3 VERIFY frame 0 (1 compact) gas", g0);
        emit log_named_uint("2-of-3 VERIFY frame 1 (1 compact) gas", g1);
        emit log_named_uint("2-of-3 validation prefix gas (both frames)", g0 + g1);
        assertTrue(g0 < 100_000 && g1 < 100_000, "each VERIFY frame fits a 100k frame limit");
        assertTrue(g0 + g1 + 200 < 1_000_000, "prefix fits ERC-8421 MAX_VERIFY_GAS_STAKED_ENTITY");
    }

    function test_gas_validate_statelessApproval() public {
        _load(vault, "stateless", 1, _transfer(1 ether));
        uint256 g1 = _gasVerify(vault, 1, 1, 2);
        emit log_named_uint("VERIFY frame with 1 stateless (SPX) approval gas", g1);
        assertTrue(g1 < 1_000_000, "fits ERC-8421 MAX_VERIFY_GAS_STAKED_ENTITY");
    }

    function test_gas_validate_threeOfFour() public {
        _load(vault34, "threeOfFour", 1, _transfer(1 ether));
        uint256 g0 = _gasVerify(vault34, 0, 0, 1);
        _load(vault34, "threeOfFour", 1, _transfer(1 ether));
        uint256 g1 = _gasVerify(vault34, 1, 1, 3);
        emit log_named_uint("3-of-4 VERIFY frame 0 (1 compact) gas", g0);
        emit log_named_uint("3-of-4 VERIFY frame 1 (2 compact) gas", g1);
        emit log_named_uint("3-of-4 validation prefix gas (both frames)", g0 + g1);
        assertTrue(g0 + g1 + 300 < 1_000_000, "prefix fits ERC-8421 MAX_VERIFY_GAS_STAKED_ENTITY");
    }
}
