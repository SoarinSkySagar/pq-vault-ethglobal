// PQVaultFrameOps — the EIP-8141 introspection opcodes PQ-Vault needs, batched into a single
// helper so a VERIFY frame pays for one cold account access instead of one per opcode (the
// whole validation prefix must fit MAX_VERIFY_GAS = 100,000 on the chain-1337 devnet).
//
// Same technique as @forshtat/hegota-support (MIT) yul/erc8421-workshop/*.yul: Solidity cannot
// emit the frame opcodes, so they are emitted with `verbatim`. Opcode bytes and stack order were
// checked against ethrex 9aa3645d (crates/vm/levm/src/opcode_handlers/frame_tx.rs):
//   TXPARAM 0xb0 [param]                 SIGPARAM 0xb4 [sigIndex, param]
//   FRAMEDATALOAD 0xb1 [offset, frame]   SIGDATACOPY 0xb5 [memOff, dataOff, len, sigIndex]
//   FRAMEPARAM 0xb3 [frame, param]       APPROVE 0xaa [offset, length, scope]
// (first operand = top of stack; Yul's verbatim puts its first argument on top).
//
// Stateless and shared by every vault. Calldata (no selector):
//   op = 1: APPROVE(scope = word 1). MUST be reached by DELEGATECALL from the account being
//           approved (APPROVE checks ADDRESS == frame target; delegatecall keeps the vault's address).
//   op = 0: introspect(sigIndex = word 1, frameIndex = word 2). Returns 12 words + signature bytes:
//     0 sigHash (TXPARAM 0x08)      4 len(signatures)          8  frame.mode
//     1 maxCost (TXPARAM 0x06)      5 sig.scheme (~0 if none)  9  frame.resolved_target
//     2 len(frames)                 6 sig.msg (0 = canonical)  10 frame.data[0:32]
//     3 current frame index         7 len(sig.signature)       11 frame.flags
//     then len(sig.signature) bytes (copied only for ARBITRARY entries; zeros otherwise).
//   A missing signature / frame index is reported with sentinel ~0 instead of halting.
object "PQVaultFrameOps" {
    code {
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            switch calldataload(0)
            case 1 {
                verbatim_3i_0o(hex"aa", 0, 0, calldataload(32))
            }
            default {
                let sigIndex := calldataload(32)
                let frameIndex := calldataload(64)

                mstore(0x00, verbatim_1i_1o(hex"b0", 0x08))
                mstore(0x20, verbatim_1i_1o(hex"b0", 0x06))
                let frameCount := verbatim_1i_1o(hex"b0", 0x09)
                mstore(0x40, frameCount)
                mstore(0x60, verbatim_1i_1o(hex"b0", 0x0a))
                let sigCount := verbatim_1i_1o(hex"b0", 0x0b)
                mstore(0x80, sigCount)

                let scheme := not(0)
                let sigLen := 0
                if lt(sigIndex, sigCount) {
                    scheme := verbatim_2i_1o(hex"b4", sigIndex, 0x01)
                    mstore(0xc0, verbatim_2i_1o(hex"b4", sigIndex, 0x02))
                    sigLen := verbatim_2i_1o(hex"b4", sigIndex, 0x03)
                }
                mstore(0xa0, scheme)
                mstore(0xe0, sigLen)

                switch lt(frameIndex, frameCount)
                case 1 {
                    mstore(0x100, verbatim_2i_1o(hex"b3", frameIndex, 0x02))
                    mstore(0x120, verbatim_2i_1o(hex"b3", frameIndex, 0x00))
                    mstore(0x140, verbatim_2i_1o(hex"b1", 0, frameIndex))
                    mstore(0x160, verbatim_2i_1o(hex"b3", frameIndex, 0x03))
                }
                default {
                    mstore(0x100, not(0))
                }

                // SIGDATACOPY halts on non-ARBITRARY entries: copy only scheme 0.
                if and(iszero(scheme), gt(sigLen, 0)) {
                    verbatim_4i_0o(hex"b5", 0x180, 0, sigLen, sigIndex)
                }
                return(0, add(0x180, sigLen))
            }
        }
    }
}
