"""
const_xref.py — Find every .text reference to given 32-bit immediate constants.

Anti-tamper detection sites often funnel into a shared "violation" sink,
tagged by a magic constant pushed/moved right before the call. Locating all
references to that magic maps the full detection surface to one choke point.

Usage:
    python const_xref.py <pe_path> <const1> [const2 ...]
    (constants hex, e.g. 0x204bda9c)
"""
import sys
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CS_MODE_64


def main():
    pe_path = sys.argv[1]
    consts = [int(x, 16) for x in sys.argv[2:]]
    const_bytes = {c: c.to_bytes(4, "little") for c in consts}

    pe = pefile.PE(pe_path)
    base = pe.OPTIONAL_HEADER.ImageBase
    is64 = pe.FILE_HEADER.Machine == 0x8664
    md = Cs(CS_ARCH_X86, CS_MODE_64 if is64 else CS_MODE_32)

    # search all executable sections
    for s in pe.sections:
        if not (s.Characteristics & 0x20000000):
            continue
        name = s.Name.rstrip(b"\x00").decode(errors="replace")
        data = s.get_data()
        sec_va = base + s.VirtualAddress
        for c, cb in const_bytes.items():
            idx = 0
            hits = []
            while True:
                j = data.find(cb, idx)
                if j < 0:
                    break
                hits.append(sec_va + j)
                idx = j + 1
            if hits:
                print(f"=== const {hex(c)} in {name}: {len(hits)} occurrence(s) ===")
                for h in hits:
                    # disassemble a couple instrs starting a few bytes back to show context
                    print(f"    @ {hex(h)}")
                print()


if __name__ == "__main__":
    main()
