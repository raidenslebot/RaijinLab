"""Settle which GO_DYNFLAG_LO bit is SPARKLE by reading the CLIENT, not the server.

WHY THIS CAN WORK OFFLINE. The server writes GAMEOBJECT_DYNAMIC; the CLIENT
decides whether to draw the shimmer. That decision is a hardcoded bit test inside
Ascension.exe, so it is a fact on disk - it does not depend on what any server
sends, and it cannot change between sessions. Two real TrinityCore tables
disagree (ACTIVATE/SPARKLE = 0x01/0x08 vs 0x04/0x20), and the addon's copy is the
modern one applied to a 3.3.5a client. The binary is the arbiter.

METHOD. GAMEOBJECT_DYNAMIC lives at descriptor byte 0x38 (update-field 14). So:
find every instruction that loads a dword from [reg+0x38], then look at the
instructions immediately following for a bit test against a small immediate. The
constants the client tests against that field are the constants it defines.

WHAT WOULD MAKE THIS INCONCLUSIVE, stated up front so the output is not
over-read: 0x38 is a common structure offset, so hits will include unrelated
code. The signal is only meaningful if the tested constants cluster on the
candidate flag bits, and if one candidate set clearly dominates. If the
distribution is flat this proves nothing and must be reported as such - a weak
signal presented as an answer is exactly the failure this file exists to avoid.
"""

import collections
import os
import re
import sys

CLIENT = r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe"

# mov r32, [reg+0x38] - the ModRM byte encodes reg/base; 0x38 is the disp8.
# 8B /r with mod=01 (disp8). Covers the common base registers.
LOADS = [bytes([0x8B, modrm, 0x38]) for modrm in
         (0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78,   # base eax
          0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x71, 0x79,   # base ecx
          0x42, 0x4A, 0x52, 0x5A, 0x62, 0x6A, 0x72, 0x7A,   # base edx
          0x43, 0x4B, 0x53, 0x5B, 0x63, 0x6B, 0x73, 0x7B,   # base ebx
          0x45, 0x4D, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D,   # base ebp
          0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x76, 0x7E,   # base esi
          0x47, 0x4F, 0x57, 0x5F, 0x67, 0x6F, 0x77, 0x7F)]  # base edi

CANDIDATES = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]

# Bit tests that follow a load, within a short window.
#   A8 ib          test al, imm8
#   F6 C0+r ib     test r8, imm8
#   24 ib          and  al, imm8
#   80 E0+r ib     and  r8, imm8
#   25 id          and  eax, imm32
#   81 E0+r id     and  r32, imm32
#   F7 C0+r id     test r32, imm32
def tests_after(buf, pos, window=20):
    """Immediates that look like bit tests in the bytes just after `pos`."""
    out = []
    seg = buf[pos:pos + window]
    i = 0
    while i < len(seg) - 1:
        b = seg[i]
        if b == 0xA8 or b == 0x24:                       # test/and al, imm8
            out.append(seg[i + 1]); i += 2; continue
        if b in (0xF6, 0x80) and i + 2 < len(seg):       # test/and r8, imm8
            if 0xC0 <= seg[i + 1] <= 0xC7 or 0xE0 <= seg[i + 1] <= 0xE7:
                out.append(seg[i + 2]); i += 3; continue
        if b == 0x25 and i + 4 < len(seg):               # and eax, imm32
            v = int.from_bytes(seg[i + 1:i + 5], "little")
            if v <= 0xFF: out.append(v)
            i += 5; continue
        if b in (0xF7, 0x81) and i + 5 < len(seg):       # test/and r32, imm32
            if 0xC0 <= seg[i + 1] <= 0xC7 or 0xE0 <= seg[i + 1] <= 0xE7:
                v = int.from_bytes(seg[i + 2:i + 6], "little")
                if v <= 0xFF: out.append(v)
                i += 6; continue
        i += 1
    return [v for v in out if v in CANDIDATES]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else CLIENT
    if not os.path.exists(path):
        print("client not found: %s" % path)
        return 2
    buf = open(path, "rb").read()
    print("scanning %s (%.1f MB)" % (os.path.basename(path), len(buf) / 1048576.0))

    hits = collections.Counter()
    sites = 0
    for pat in LOADS:
        start = 0
        while True:
            i = buf.find(pat, start)
            if i < 0:
                break
            start = i + 1
            found = tests_after(buf, i + len(pat))
            if found:
                sites += 1
                for v in found:
                    hits[v] += 1

    print("\n%d load-from-[reg+0x38] sites are followed by a bit test" % sites)
    if not hits:
        print("INCONCLUSIVE: no bit tests found near any +0x38 load")
        return 1

    total = sum(hits.values())
    print("\nconstant  count   share")
    for v in CANDIDATES:
        n = hits.get(v, 0)
        bar = "#" * int(40.0 * n / max(1, max(hits.values())))
        print("  0x%02X    %5d   %5.1f%%  %s" % (v, n, 100.0 * n / total, bar))

    # The two candidate tables, scored on the bits each one actually defines.
    classic = sum(hits.get(b, 0) for b in (0x01, 0x02, 0x04, 0x08, 0x10))
    modern = sum(hits.get(b, 0) for b in (0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80))
    only_classic = hits.get(0x01, 0)
    only_modern = sum(hits.get(b, 0) for b in (0x20, 0x40, 0x80))
    print("\nbits unique to CLASSIC (0x01):            %d" % only_classic)
    print("bits unique to MODERN  (0x20/0x40/0x80): %d" % only_modern)
    print("all CLASSIC-defined bits: %d | all MODERN-defined bits: %d"
          % (classic, modern))

    print("")
    if only_classic == 0 and only_modern == 0:
        print("INCONCLUSIVE: neither table's unique bits are tested near this "
              "offset. 0x38 is a common structure offset and these hits are "
              "probably unrelated code.")
        return 1
    ratio = (float(only_classic) / only_modern) if only_modern else float("inf")
    if ratio >= 3.0:
        print("LEANS CLASSIC: the bit only CLASSIC defines is tested %.1fx more "
              "often than all MODERN-only bits combined." % ratio)
    elif only_modern and (float(only_modern) / max(1, only_classic)) >= 3.0:
        print("LEANS MODERN: MODERN-only bits dominate.")
    else:
        print("INCONCLUSIVE: the distribution does not separate the two tables.")
    print("\nThis is a STATISTICAL reading of unlabelled code, not a proof. It is "
          "worth acting on only if it AGREES with the live evidence from "
          "/raijin goflags; where they disagree, the live object wins.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
