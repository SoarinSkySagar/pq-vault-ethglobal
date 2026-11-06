// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Gas-faithful stand-in for PQVaultFrameOps, used only to *measure* validate(): it serves up to six
/// precomputed introspection responses from contract code (EXTCODECOPY, like the real helper's
/// SIGDATACOPY it costs ~3 gas/word), selected by the hash of the request, with no storage reads,
/// and records APPROVE as an event instead of a storage write.
contract CodeBlobFrameOps {
    bytes32 internal immutable k0;
    bytes32 internal immutable k1;
    bytes32 internal immutable k2;
    bytes32 internal immutable k3;
    bytes32 internal immutable k4;
    bytes32 internal immutable k5;
    address internal immutable b0;
    address internal immutable b1;
    address internal immutable b2;
    address internal immutable b3;
    address internal immutable b4;
    address internal immutable b5;

    event Approved(uint256 scope);

    constructor(bytes[] memory requests, bytes[] memory responses) {
        require(requests.length == responses.length && requests.length <= 6, "blobs");
        bytes32[6] memory k;
        address[6] memory b;
        for (uint256 i = 0; i < requests.length; i++) {
            k[i] = keccak256(requests[i]);
            b[i] = _blob(responses[i]);
        }
        (k0, k1, k2, k3, k4, k5) = (k[0], k[1], k[2], k[3], k[4], k[5]);
        (b0, b1, b2, b3, b4, b5) = (b[0], b[1], b[2], b[3], b[4], b[5]);
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
        bytes32 key = keccak256(input);
        address b = key == k0 ? b0 : key == k1 ? b1 : key == k2 ? b2 : key == k3 ? b3 : key == k4 ? b4 : key == k5 ? b5 : address(0);
        require(b != address(0), "unknown request");
        uint256 n = b.code.length - 1;
        out = new bytes(n);
        assembly {
            extcodecopy(b, add(out, 0x20), 1, n)
        }
    }
}
