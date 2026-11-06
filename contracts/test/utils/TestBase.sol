// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Foundry cheatcodes used by these tests (subset of forge-std's Vm, declared locally so the repo
/// has no forge-std dependency).
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address msgSender) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function deal(address account, uint256 newBalance) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonBytes(string calldata json, string calldata key) external pure returns (bytes memory);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert() external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool c, string memory m) internal pure {
        require(c, m);
    }

    function assertEq(uint256 a, uint256 b, string memory m) internal pure {
        if (a != b) revert(string.concat(m, ": ", _u(a), " != ", _u(b)));
    }

    function assertEq(bytes32 a, bytes32 b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertEq(address a, address b, string memory m) internal pure {
        require(a == b, m);
    }

    function _u(uint256 v) private pure returns (string memory s) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        s = string(b);
    }
}
