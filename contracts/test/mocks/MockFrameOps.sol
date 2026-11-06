// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Test double for PQVaultFrameOps. Foundry's EVM has no EIP-8141 opcodes, so this contract
/// answers the same calldata with the same return layout, from a frame transaction the test
/// configures. Behaviour on the real devnet is exercised separately (script/ and devnet receipts).
contract MockFrameOps {
    /// Where op=1 (APPROVE) records the approved scope. op=1 runs by DELEGATECALL, so this slot
    /// lives in the *calling vault's* storage, exactly as the real APPROVE acts on the caller.
    bytes32 public constant APPROVED_SLOT = keccak256("pq-vault.mock.approved-scope");

    struct FrameCfg {
        uint256 mode;
        address target;
        bytes32 word0;
        uint256 flags;
    }

    bytes32 public sigHash;
    uint256 public maxCost;
    uint256 public curFrame;
    FrameCfg[] internal _frames;
    bytes[] internal _sigs; // ARBITRARY entries with empty msg
    uint256 public sigScheme; // scheme reported for every entry (0 = ARBITRARY)

    function reset(bytes32 sigHash_, uint256 maxCost_, uint256 curFrame_) external {
        sigHash = sigHash_;
        maxCost = maxCost_;
        curFrame = curFrame_;
        sigScheme = 0;
        delete _frames;
        delete _sigs;
    }

    function addFrame(uint256 mode, address target, bytes32 word0, uint256 flags) external {
        _frames.push(FrameCfg(mode, target, word0, flags));
    }

    function addSig(bytes calldata entry) external {
        _sigs.push(entry);
    }

    function setScheme(uint256 s) external {
        sigScheme = s;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        uint256 op = uint256(bytes32(input[0:32]));
        if (op == 1) {
            uint256 scope = uint256(bytes32(input[32:64])); // op=1 carries one operand (64-byte calldata)
            bytes32 slot = APPROVED_SLOT;
            assembly {
                sstore(slot, scope)
            }
            return "";
        }
        (, uint256 a, uint256 b) = abi.decode(input, (uint256, uint256, uint256));
        uint256[12] memory w;
        w[0] = uint256(sigHash);
        w[1] = maxCost;
        w[2] = _frames.length;
        w[3] = curFrame;
        w[4] = _sigs.length;
        bytes memory sig;
        if (a < _sigs.length) {
            w[5] = sigScheme;
            sig = _sigs[a];
            w[7] = sig.length;
            if (sigScheme != 0) sig = new bytes(sig.length); // real helper copies only ARBITRARY bytes
        } else {
            w[5] = type(uint256).max;
        }
        if (b < _frames.length) {
            FrameCfg memory f = _frames[b];
            w[8] = f.mode;
            w[9] = uint256(uint160(f.target));
            w[10] = uint256(f.word0);
            w[11] = f.flags;
        } else {
            w[8] = type(uint256).max;
        }
        return abi.encodePacked(w, sig);
    }
}
