// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Gas-faithful stand-in for PQVaultFrameOps, used only to *measure* validate(): it serves one
/// precomputed introspection response from contract code (EXTCODECOPY, like the real helper's
/// SIGDATACOPY it costs ~3 gas/word) and records APPROVE as an event instead of a storage write.
contract CodeBlobFrameOps {
    address public immutable blob0; // response for signature index 0
    address public immutable blob1; // response for signature index 1

    event Approved(uint256 scope);

    constructor(bytes memory response0, bytes memory response1) {
        blob0 = _blob(response0);
        blob1 = _blob(response1);
    }

    function _blob(bytes memory response) private returns (address b) {
        // runtime code of `b` = 0x00 (STOP) || response
        bytes memory init = abi.encodePacked(hex"61", uint16(response.length + 1), hex"80600c6000396000f3", hex"00", response);
        assembly {
            b := create(0, add(init, 0x20), mload(init))
        }
        require(b != address(0), "blob");
    }

    fallback(bytes calldata input) external returns (bytes memory out) {
        if (uint256(bytes32(input[0:32])) == 1) {
            emit Approved(uint256(bytes32(input[32:64])));
            return "";
        }
        address b = uint256(bytes32(input[32:64])) == 0 ? blob0 : blob1;
        uint256 n = b.code.length - 1;
        out = new bytes(n);
        assembly {
            extcodecopy(b, add(out, 0x20), 1, n)
        }
    }
}
