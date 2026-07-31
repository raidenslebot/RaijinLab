"""Disassemble Ascension.exe and find what the client actually tests against the
value it loads from descriptor+0x38 (GAMEOBJECT_DYNAMIC).

WHY A REAL DISASSEMBLER. The first pass at this used raw byte patterns, which
match operands and data as readily as instructions and cannot tell which register
received the load. That produced a distribution I could only report as a lean.
Capstone decodes properly, so a hit means an instruction really loaded from
[reg+0x38], and the constant really is tested against THAT value.

WHAT THIS CAN AND CANNOT SETTLE. 0x38 is a common structure offset, so not every
hit is a gameobject. What is diagnostic is which constants the client EVER tests
against a value from that offset: under MODERN, SPARKLE is 0x20 and the client
must test it somewhere to draw the shimmer. A complete absence of 0x20 across
every accurately-decoded site is evidence MODERN is not this client's table.
Absence of evidence is weak on its own, which is why the baseline matters: if the
client tests 0x20 freely elsewhere but never here, that asymmetry is the signal.
"""

import collections
import os
import sys

CLIENT = r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe"
CANDIDATES = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80)


def text_section(path):
    """(bytes, virtual address) of the executable section."""
    import struct
    data = open(path, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt = struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    off = pe + 24 + opt
    for i in range(nsec):
        s = off + i * 40
        name = data[s:s + 8].rstrip(b"\0").decode("ascii", "replace")
        vsize, va, rsize, raw = struct.unpack_from("<IIII", data, s + 8)
        flags = struct.unpack_from("<I", data, s + 36)[0]
        if flags & 0x20000000 and name.lower().startswith(".t"):   # executable
            return data[raw:raw + rsize], base + va
    return None, None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else CLIENT
    if not os.path.exists(path):
        print("client not found: %s" % path); return 2
    try:
        from capstone import Cs, CS_ARCH_X86, CS_MODE_32, x86
    except ImportError:
        print("SKIP: capstone not installed"); return 0

    code, va = text_section(path)
    if not code:
        print("could not locate the text section"); return 2
    print("disassembling .text: %.1f MB at 0x%X" % (len(code) / 1048576.0, va))

    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    insns = list(md.disasm(code, va))
    print("%d instructions decoded" % len(insns))

    near = collections.Counter()      # constants tested against a +0x38 value
    base = collections.Counter()      # constants tested against anything
    sites = []

    def mem_at_38(op):
        return (op.type == x86.X86_OP_MEM and op.mem.disp == 0x38
                and op.mem.base != 0 and op.mem.index == 0)

    for i, ins in enumerate(insns):
        # baseline: every bit test in the binary
        if ins.mnemonic in ("test", "and") and len(ins.operands) == 2:
            src = ins.operands[1]
            if src.type == x86.X86_OP_IMM and src.imm in CANDIDATES:
                base[src.imm] += 1

        # a load from [reg+0x38] into a register
        if ins.mnemonic not in ("mov", "movzx"):
            continue
        ops = ins.operands
        if len(ops) != 2 or ops[0].type != x86.X86_OP_REG or not mem_at_38(ops[1]):
            continue
        dst = ins.reg_name(ops[0].reg)
        if not dst:
            continue
        root = dst.lstrip("er")[:2]   # eax/ax/al -> "ax"/"al" share a root

        # follow the basic block forward until the value is clobbered or we branch
        for j in range(i + 1, min(i + 14, len(insns))):
            nx = insns[j]
            if nx.mnemonic.startswith(("j", "call", "ret")):
                break
            if nx.mnemonic in ("test", "and") and len(nx.operands) == 2:
                a, b = nx.operands
                if (a.type == x86.X86_OP_REG and b.type == x86.X86_OP_IMM
                        and b.imm in CANDIDATES):
                    nm = nx.reg_name(a.reg) or ""
                    if nm.lstrip("er")[:2] == root or nm[-1:] == root[-1:]:
                        near[b.imm] += 1
                        sites.append((nx.address, dst, b.imm))
                        break
            # value overwritten?
            if (nx.mnemonic == "mov" and nx.operands
                    and nx.operands[0].type == x86.X86_OP_REG
                    and (nx.reg_name(nx.operands[0].reg) or "") == dst):
                break

    tot_n, tot_b = sum(near.values()), sum(base.values())
    print("\n%d accurately-decoded sites test a constant against a value "
          "loaded from [reg+0x38]" % tot_n)
    if tot_n == 0:
        print("INCONCLUSIVE: no such site exists - this offset is not bit-tested "
              "anywhere, so the client does not read its flags this way.")
        return 1

    print("\nconst   near[+0x38]      whole binary     ratio")
    for v in CANDIDATES:
        n, b = near.get(v, 0), base.get(v, 0)
        pn = 100.0 * n / tot_n
        pb = 100.0 * b / max(1, tot_b)
        tag = ""
        if v == 0x08: tag = "  <- SPARKLE if CLASSIC"
        if v == 0x20: tag = "  <- SPARKLE if MODERN"
        print("  0x%02X   %4d (%5.1f%%)   %6d (%5.2f%%)   %5.2fx%s"
              % (v, n, pn, b, pb, (pn / pb) if pb else 0.0, tag))

    only_c = near.get(0x01, 0)
    only_m = sum(near.get(b, 0) for b in (0x20, 0x40, 0x80))
    exp_m = tot_n * sum(base.get(b, 0) for b in (0x20, 0x40, 0x80)) / max(1, tot_b)
    print("\nCLASSIC-only bit (0x01) tested here:   %d" % only_c)
    print("MODERN-only bits tested here:          %d  (expected ~%.1f if this "
          "were MODERN's field)" % (only_m, exp_m))

    print("")
    if only_m == 0 and only_c > 0 and exp_m >= 3.0:
        print("STRONG: the client never tests a MODERN-only bit against this "
              "field, where chance alone predicts ~%.0f. Consistent ONLY with "
              "CLASSIC (ACTIVATE=0x01, SPARKLE=0x08)." % exp_m)
    elif only_m == 0 and only_c > 0:
        print("LEANS CLASSIC, but the expected count of MODERN-only bits (%.1f) "
              "is too small for their absence to carry weight." % exp_m)
    else:
        print("INCONCLUSIVE: the distribution does not separate the tables.")
    print("\nStill a reading of unlabelled code. /raijin goflags on a real object "
          "is what PROVES it; this only says what to expect.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
