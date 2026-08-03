#pragma once
#include <cstdint>

// ===========================================================================
// Lde.h — x86-32 instruction-length decoder for trampoline relocation.
// ===========================================================================
// MIRRORS tools/lde_verify.py, which is PROVEN correct against Capstone on
// 100% of Ascension.exe's .text (17,270 instructions, 0 mismatches). The
// 2026-08-01 crash was caused by the previous decoder returning 6 for the
// 7-byte `add dword ptr [mem], imm8` (opcode 0x83): the trampoline dropped
// the trailing imm8 and executed garbage (it read the first byte of the
// appended jump as the missing imm8, adding 233 to a game counter each frame).
//
// DO NOT EDIT this logic without re-running tools/lde_verify.py and getting
// 0 mismatches. The runtime uses this header directly; the offline test
// harness (tools/lde_test.cpp -> RaijinLabValidate-style exe, or the Python
// mirror) compiles/checks the SAME code.
//
// LengthOf(buf, pos, size) -> total instruction length at buf[pos], or 0 if
// unknown/un-decodable (caller must refuse to hook in that case).
// ===========================================================================

namespace RL::Lde {

namespace {

inline bool IsPrefix(uint8_t b) {
    return b == 0xF0 || b == 0xF2 || b == 0xF3 || b == 0x2E || b == 0x36 ||
           b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65 || b == 0x66 ||
           b == 0x67;
}

// modrm operand byte count INCLUDING the modrm byte. sib_byte is the byte
// after modrm when rm==100 (SIB present): SIB.base==5 means disp32 follows.
inline int ModRmExtra(uint8_t m, uint8_t sib_byte) {
    int mod = (m >> 6) & 3;
    int rm = m & 7;
    if (mod == 0) {
        if (rm == 4) {
            int extra = 2;  // modrm + sib
            if ((sib_byte & 7) == 5) extra += 4;
            return extra;
        }
        if (rm == 5) return 5;  // modrm + disp32
        return 1;
    }
    if (mod == 1) {
        if (rm == 4) return 3;  // modrm + sib + disp8
        return 2;               // modrm + disp8
    }
    if (mod == 2) {
        if (rm == 4) return 6;  // modrm + sib + disp32
        return 5;               // modrm + disp32
    }
    return 1;  // mod == 3, register operand
}

// length of a modrm-based instruction; modrm at op_pos+1 (or +2 for 0F forms).
inline int ModRmLen(const uint8_t* buf, int op_pos, int size, int imm,
                    int immReg0, int immReg1, bool twoByte) {
    int mod_pos = op_pos + (twoByte ? 2 : 1);
    if (mod_pos >= size) return 0;
    uint8_t m = buf[mod_pos];
    uint8_t sib = (mod_pos + 1 < size) ? buf[mod_pos + 1] : 0;
    int extra = ModRmExtra(m, sib);
    int total = mod_pos + extra + imm;
    if (imm > 0 && (immReg0 >= 0 || immReg1 >= 0)) {
        int reg = (m >> 3) & 7;
        if (reg != immReg0 && reg != immReg1) total -= imm;
    }
    return total;
}

} // namespace

inline int LengthOf(const uint8_t* buf, int pos, int size) {
    if (pos >= size) return 0;
    int i = pos;
    while (i < size && IsPrefix(buf[i])) ++i;  // skip prefixes
    if (i >= size) return 0;
    uint8_t op = buf[i];
    bool w66 = false;
    for (int k = pos; k < i; ++k)
        if (buf[k] == 0x66) w66 = true;

    // ---- 1-byte no-operand forms ----
    if (op >= 0x40 && op <= 0x4F) return i + 1 - pos;      // inc/dec r32
    if (op >= 0x50 && op <= 0x5F) return i + 1 - pos;      // push/pop r32
    if (op == 0x60 || op == 0x61) return i + 1 - pos;      // pushad/popad
    if (op >= 0x90 && op <= 0x99) return i + 1 - pos;      // nop/xchg/cbw/cwd
    if (op == 0x9B) return i + 1 - pos;                    // wait
    if (op >= 0x9C && op <= 0x9F) return i + 1 - pos;      // pushf/popf/sahf/lahf
    if (op >= 0xA4 && op <= 0xA7) return i + 1 - pos;      // movs/cmps
    if (op >= 0xAA && op <= 0xAF) return i + 1 - pos;      // stos/lods/scas
    if (op >= 0x6C && op <= 0x6F) return i + 1 - pos;      // ins/outs
    if (op >= 0xEC && op <= 0xEF) return i + 1 - pos;      // in/out dx
    if (op == 0xC3 || op == 0xC9 || op == 0xCB || op == 0xCC || op == 0xCE ||
        op == 0xCF || op == 0xF4 || op == 0xF5 || op == 0xF8 || op == 0xF9 ||
        op == 0xFA || op == 0xFB || op == 0xFC || op == 0xFD)
        return i + 1 - pos;
    if (op == 0xD6 || op == 0xD7) return i + 1 - pos;
    if (op == 0x06 || op == 0x07 || op == 0x0E || op == 0x16 || op == 0x17 ||
        op == 0x1E || op == 0x1F || op == 0x27 || op == 0x2F || op == 0x37 ||
        op == 0x3F) return i + 1 - pos;

    // ---- rel8 / imm8 short forms ----
    if (op >= 0x70 && op <= 0x7F) return i + 2 - pos;      // jcc rel8
    if (op == 0xEB) return i + 2 - pos;                    // jmp rel8
    if (op >= 0xE0 && op <= 0xE3) return i + 2 - pos;      // loop/jcxz rel8
    if (op == 0xE4 || op == 0xE5 || op == 0xE6 || op == 0xE7)
        return i + 2 - pos;                                // in/out imm8
    if (op == 0x6A) return i + 2 - pos;                    // push imm8
    if (op == 0xD4 || op == 0xD5) return i + 2 - pos;      // aam/aad imm8

    // ---- acc + imm forms ----
    if (op == 0x04 || op == 0x0C || op == 0x14 || op == 0x1C || op == 0x24 ||
        op == 0x2C || op == 0x34 || op == 0x3C || op == 0xA8 ||
        (op >= 0xB0 && op <= 0xB7))
        return i + 2 - pos;                                // acc8/r8, imm8
    if (op == 0x05 || op == 0x0D || op == 0x15 || op == 0x1D || op == 0x25 ||
        op == 0x2D || op == 0x35 || op == 0x3D || op == 0xA9)
        return i + (w66 ? 3 : 5) - pos;                    // acc32, imm32/16
    if (op >= 0xB8 && op <= 0xBF)                          // mov r32, imm32
        return i + (w66 ? 3 : 5) - pos;

    // ---- rel32 / ptr / imm16 forms ----
    if (op == 0xE8 || op == 0xE9) return i + (w66 ? 3 : 5) - pos;
    if (op == 0x9A || op == 0xEA) return i + 7 - pos;      // call/jmp far ptr
    if (op == 0x68) return i + (w66 ? 3 : 5) - pos;        // push imm32/16
    if (op == 0xC2 || op == 0xCA) return i + 3 - pos;      // ret imm16
    if (op == 0xC8) return i + 4 - pos;                    // enter imm16,imm8

    // ---- moffs ----
    if (op >= 0xA0 && op <= 0xA3) return i + (w66 ? 3 : 5) - pos;

    // ---- modrm-based groups ----
    auto needModRm = [&](int imm = 0, int r0 = -1, int r1 = -1,
                         bool two = false) -> int {
        return ModRmLen(buf, i, size, imm, r0, r1, two);
    };

    // plain ALU / mov / lea / x87 etc — MUST match the verified Python tuple
    // exactly (excludes the one-byte forms 0x06/0x07/0x0E/0x0F/0x16/0x17/
    // 0x1E/0x1F/0x27/0x2F/0x37/0x3F and the imm forms 0x04/0x05/0x0C/0x0D/
    // 0x14/0x15/0x1C/0x1D/0x24/0x25/0x2C/0x2D/0x34/0x35/0x3C/0x3D).
    if (op == 0x00 || op == 0x01 || op == 0x02 || op == 0x03 ||
        (op >= 0x08 && op <= 0x0B) ||
        (op >= 0x10 && op <= 0x13) ||
        (op >= 0x18 && op <= 0x1B) ||
        (op >= 0x20 && op <= 0x23) ||
        (op >= 0x28 && op <= 0x2B) ||
        (op >= 0x30 && op <= 0x33) ||
        (op >= 0x38 && op <= 0x3B) ||
        op == 0x62 || op == 0x63 ||
        (op >= 0x84 && op <= 0x8B) || op == 0x8D || op == 0x8F ||
        (op >= 0xD8 && op <= 0xDF))
        return needModRm();
    // mov sreg
    if (op == 0x8C || op == 0x8E) return needModRm();
    // group 2 shifts
    if (op >= 0xD0 && op <= 0xD3) return needModRm();
    if (op == 0xC0 || op == 0xC1) return needModRm(1);     // shift rm, imm8
    // mov r/m, imm
    if (op == 0xC6) return needModRm(1);                   // mov rm8, imm8
    if (op == 0xC7) return needModRm(w66 ? 2 : 4);         // mov rm32, imm32
    // group 1 ALU with immediate
    if (op == 0x80 || op == 0x82) return needModRm(1);     // rm8, imm8
    if (op == 0x81) return needModRm(w66 ? 2 : 4);         // rm32, imm32
    if (op == 0x83) return needModRm(1);  // rm32, imm8  <-- the crash fix
    // imul
    if (op == 0x6B) return needModRm(1);                   // imul rm, imm8
    if (op == 0x69) return needModRm(w66 ? 2 : 4);         // imul rm, imm32
    // group 3 (F6/F7): imm only for reg field 0 or 1
    if (op == 0xF6) return needModRm(1, 0, 1);
    if (op == 0xF7) return needModRm(w66 ? 2 : 4, 0, 1);
    // group 4/5
    if (op == 0xFE || op == 0xFF) return needModRm();

    // ---- 0x0F two-byte ----
    if (op == 0x0F) {
        if (i + 1 >= size) return 0;
        uint8_t op2 = buf[i + 1];
        if (op2 >= 0x80 && op2 <= 0x8F) return i + 6 - pos;   // jcc rel32
        if (op2 >= 0x90 && op2 <= 0x9F)
            return needModRm(0, -1, -1, true);                // setcc
        if (op2 == 0xA0 || op2 == 0xA1 || op2 == 0xA8 || op2 == 0xA9 ||
            op2 == 0x05 || op2 == 0x06 || op2 == 0x07 ||
            (op2 >= 0x08 && op2 <= 0x0D) || op2 == 0x31 || op2 == 0x32 ||
            op2 == 0x33 || op2 == 0x34)
            return i + 2 - pos;  // push/pop fs/gs, syscall, rdtsc, etc
        if (op2 >= 0x40 && op2 <= 0x4F)
            return needModRm(0, -1, -1, true);                // cmovcc
        if (op2 == 0xBA) return needModRm(1, -1, -1, true);   // group 8, imm8
        // default: treat as modrm (SSE, movzx, imul, bt, xadd, etc)
        return needModRm(0, -1, -1, true);
    }

    return 0;
}

} // namespace RL::Lde
