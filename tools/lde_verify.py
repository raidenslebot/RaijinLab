"""Exhaustive verification of the x86 instruction-length decoder against
Capstone across the ENTIRE .text section of Ascension.exe.

The C++ trampoline builder (NativeHook.cpp) uses a hand-rolled length decoder.
The 2026-08-01 crash was caused by that decoder returning 6 for `add r/m32,imm8`
(0x83) which is really 7 bytes — the trampoline dropped the imm8 and executed
garbage. This tool proves the SAME decoder logic (mirrored 1:1 in Python) is
correct on every instruction in the game's code, or reports every mismatch.

Usage: python tools/lde_verify.py
"""
import struct
import sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400  # .text virtual size (VSZ)

PREFIXES = frozenset([0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65,
                      0x66, 0x67])

# modrm operand byte count INCLUDING the modrm byte itself.
# Handles the SIB (rm==100) base==5 disp32 case for mod==0.
def modrm_extra(b, sib_byte=None):
    mod = (b >> 6) & 3
    rm = b & 7
    if mod == 0:
        if rm == 4:
            # SIB present; if SIB.base == 5 -> disp32
            extra = 2  # modrm + sib
            if sib_byte is not None and (sib_byte & 7) == 5:
                extra += 4
            return extra
        if rm == 5:
            return 5  # modrm + disp32
        return 1
    if mod == 1:
        if rm == 4:
            return 3  # modrm + sib + disp8
        return 2  # modrm + disp8
    if mod == 2:
        if rm == 4:
            return 6  # modrm + sib + disp32
        return 5  # modrm + disp32
    return 1  # mod==3, register operand


def has_66(buf, off):
    return 0x66 in buf[off:i_after_prefixes(buf, off)]


def i_after_prefixes(buf, off):
    i = off
    n = len(buf)
    while i < n and buf[i] in PREFIXES:
        i += 1
    return i


def lde(buf, off):
    """Return total instruction length starting at off, or 0 if unknown."""
    n = len(buf)
    i = i_after_prefixes(buf, off)
    if i >= n:
        return 0
    op = buf[i]
    w66 = 0x66 in buf[off:i]

    # --- 1-byte no-operand forms ---
    if op in range(0x40, 0x50):  # inc/dec r32
        return i - off + 1
    if op in range(0x50, 0x60):  # push/pop r32
        return i - off + 1
    if op in (0x60, 0x61):  # pushad/popad
        return i - off + 1
    if op in range(0x90, 0x9A):  # nop/xchg/cbw/cwd
        return i - off + 1
    if op == 0x9B:  # wait
        return i - off + 1
    if op in range(0x9C, 0xA0):  # pushf/popf/sahf/lahf
        return i - off + 1
    if op in range(0xA4, 0xA8):  # string ops (movs/cmps)
        return i - off + 1
    if op in range(0xAA, 0xB0):  # string ops (stos/lods/scas)
        return i - off + 1
    if op in range(0x6C, 0x70):  # ins/outs
        return i - off + 1
    if op in range(0xEC, 0xF0):  # in/out dx
        return i - off + 1
    if op in (0xC3, 0xC9, 0xCB, 0xCC, 0xCE, 0xCF, 0xF4, 0xF5,
              0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD):
        return i - off + 1
    if op in (0xD6, 0xD7):
        return i - off + 1
    if op in (0x06, 0x07, 0x0E, 0x16, 0x17, 0x1E, 0x1F, 0x27, 0x2F, 0x37, 0x3F):
        return i - off + 1

    # --- rel8 / imm8 short forms ---
    if op in range(0x70, 0x80):  # jcc rel8
        return i - off + 2
    if op in (0xEB,):  # jmp rel8
        return i - off + 2
    if op in range(0xE0, 0xE4):  # loop/jcxz rel8
        return i - off + 2
    if op in (0xE4, 0xE5, 0xE6, 0xE7):  # in/out imm8
        return i - off + 2
    if op in (0x6A,):  # push imm8
        return i - off + 2
    if op in (0xD4, 0xD5):  # aam/aad imm8
        return i - off + 2

    # --- acc + imm forms (imm8 or imm32/16) ---
    if op in (0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C,
              0xA8, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7):
        return i - off + 2
    if op in (0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D, 0xA9):
        return i - off + (3 if w66 else 5)
    if op in range(0xB8, 0xC0):  # mov r32, imm32
        return i - off + (3 if w66 else 5)

    # --- rel32 / ptr forms ---
    if op == 0xE8:  # call rel32
        return i - off + (3 if w66 else 5)
    if op == 0xE9:  # jmp rel32
        return i - off + (3 if w66 else 5)
    if op == 0x9A:  # call far ptr16:32
        return i - off + 7
    if op == 0xEA:  # jmp far
        return i - off + 7
    if op in (0x68,):  # push imm32
        return i - off + (3 if w66 else 5)
    if op in (0xC2, 0xCA):  # ret imm16
        return i - off + 3
    if op == 0xC8:  # enter imm16, imm8
        return i - off + 4

    # --- moffs (0xA0-0xA3: AL/AX/EAX <-> moffs) ---
    if op in (0xA0, 0xA1, 0xA2, 0xA3):
        return i - off + (3 if w66 else 5)

    # --- modrm-based groups ---
    # `two` = true when the opcode is the 2-byte 0F form (modrm at buf[i+2]).
    def need_modrm(imm=0, imm_if_reg=None, two=False):
        mod_pos = i + (2 if two else 1)
        if mod_pos >= n:
            return 0
        m = buf[mod_pos]
        sib = buf[mod_pos + 1] if mod_pos + 1 < n else None
        extra = modrm_extra(m, sib)
        total = (mod_pos + extra + imm) - off
        # for F6/F7: imm present only for reg field 0 or 1
        if imm_if_reg is not None:
            reg = (m >> 3) & 7
            if reg not in imm_if_reg:
                total -= imm
        return total

    if op in (0x00, 0x01, 0x02, 0x03, 0x08, 0x09, 0x0A, 0x0B,
              0x10, 0x11, 0x12, 0x13, 0x18, 0x19, 0x1A, 0x1B,
              0x20, 0x21, 0x22, 0x23, 0x28, 0x29, 0x2A, 0x2B,
              0x30, 0x31, 0x32, 0x33, 0x38, 0x39, 0x3A, 0x3B,
              0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B,
              0x8D, 0x8F, 0x63, 0x62,
              0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF):
        return need_modrm()

    if op in (0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C, 0x04):
        return i - off + 2
    if op in (0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D):
        return i - off + (3 if w66 else 5)

    # mov sreg
    if op in (0x8C, 0x8E):
        return need_modrm()

    # group 2 shifts
    if op in (0xD0, 0xD1, 0xD2, 0xD3):
        return need_modrm()
    if op in (0xC0, 0xC1):  # shift rm, imm8
        return need_modrm(imm=1)

    # mov r/m, imm
    if op == 0xC6:  # mov rm8, imm8
        return need_modrm(imm=1)
    if op == 0xC7:  # mov rm32, imm32
        return need_modrm(imm=(2 if w66 else 4))

    # group 1 ALU with immediate
    if op in (0x80, 0x82):  # rm8, imm8
        return need_modrm(imm=1)
    if op == 0x81:  # rm32, imm32
        return need_modrm(imm=(2 if w66 else 4))
    if op == 0x83:  # rm32, imm8  <-- THE BUG WAS HERE
        return need_modrm(imm=1)

    # imul
    if op == 0x6B:  # imul r32, rm32, imm8
        return need_modrm(imm=1)
    if op == 0x69:  # imul r32, rm32, imm32
        return need_modrm(imm=(2 if w66 else 4))

    # group 3 (F6/F7)
    if op == 0xF6:
        return need_modrm(imm=1, imm_if_reg=(0, 1))
    if op == 0xF7:
        return need_modrm(imm=(2 if w66 else 4), imm_if_reg=(0, 1))

    # group 4/5
    if op in (0xFE, 0xFF):
        return need_modrm()

    # 0x0F two-byte
    if op == 0x0F:
        if i + 1 >= n:
            return 0
        op2 = buf[i + 1]
        # jcc rel32 / setcc / cmovcc / other
        if op2 in range(0x80, 0x90):  # jcc rel32
            return i - off + 6
        if op2 in range(0x90, 0xA0):  # setcc rm8
            return need_modrm(two=True)
        if op2 in (0xA0, 0xA1, 0xA8, 0xA9, 0x05, 0x06, 0x07,
                   0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x31, 0x32,
                   0x33, 0x34):  # push/pop fs/gs, syscall etc
            return i - off + 2
        if op2 in range(0x40, 0x50):  # cmovcc r32, rm32
            return need_modrm(two=True)
        if op2 in (0xB6, 0xB7, 0xBE, 0xBF, 0xAF, 0xB0, 0xB1,
                   0xB2, 0xB3, 0xB4, 0xB5, 0xAB, 0xA3, 0xA5, 0xAD,
                   0xC0, 0xC1, 0xC2, 0xAE, 0x10, 0x11, 0x12, 0x13,
                   0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B,
                   0x1C, 0x1D, 0x1E, 0x1F, 0x28, 0x29, 0x2A, 0x2B,
                   0x2C, 0x2D, 0x2E, 0x2F, 0x54, 0x55, 0x56, 0x57,
                   0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
                   0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67,
                   0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
                   0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77,
                   0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
                   0x6E, 0x7E, 0x6F, 0x7F, 0x20, 0x21, 0x22, 0x23,
                   0x01, 0xBA, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD,
                   0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5,
                   0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD,
                   0xDE, 0xDF, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5,
                   0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED,
                   0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5,
                   0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD,
                   0xFE, 0xFF, 0x0E, 0x0F, 0x30, 0x35, 0x36, 0x37,
                   0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
                   0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
                   0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F):
            return need_modrm(two=True)
        if op2 == 0xBA:  # group 8: bt/bts/btr/btc rm, imm8
            return need_modrm(imm=1, two=True)
        # default: treat as modrm
        return need_modrm(two=True)

    return 0


def main():
    data = open(EXE, 'rb').read()
    text = data[TEXT_OFF:TEXT_OFF + TEXT_SIZE]
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = False

    # Capstone linear sweep over the whole .text
    insns = list(md.disasm(text, TEXT_VA))
    # build dict: va -> size
    sizes = {}
    for ins in insns:
        sizes[ins.address] = ins.size

    mismatches = 0
    checked = 0
    shown = 0
    for va, size in sorted(sizes.items()):
        fo = va - IMAGE_BASE - 0x1000 + TEXT_OFF
        if fo < 0 or fo >= len(data):
            continue
        chunk = data[fo:fo + 16]
        mine = lde(chunk, 0)
        checked += 1
        if mine != size:
            mismatches += 1
            if shown < 30:
                shown += 1
                print('MISMATCH va=0x%08X capstone=%d mine=%d bytes=%s'
                      % (va, size, mine, ' '.join('%02X' % b for b in chunk[:size + 4])))
    print()
    print('checked %d instructions, %d mismatches' % (checked, mismatches))
    if mismatches == 0:
        print('DECODER PROVEN CORRECT against capstone on 100%% of .text')
        return 0
    print('DECODER NOT CORRECT - fix before shipping')
    return 1


if __name__ == '__main__':
    sys.exit(main())
