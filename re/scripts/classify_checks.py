"""
classify_checks.py — For each detection site (where the violation magic is
built), show the preceding technique and the following sink call.

Given a PE and a list of VAs (the `mov [mem], MAGIC` sites), disassemble a
window before (to reveal the check technique) and after (to reveal the shared
sink call target), annotating IAT calls.
"""
import sys
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CS_MODE_64
from collections import Counter


def build_iat_name_map(pe):
    m = {}
    if not hasattr(pe, "DIRECTORY_ENTRY_IMPORT"):
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]]
        )
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        dll = entry.dll.decode(errors="replace")
        for imp in entry.imports:
            if imp.name:
                m[imp.address] = f"{dll}!{imp.name.decode(errors='replace')}"
    return m


def va_to_off(pe, va):
    rva = va - pe.OPTIONAL_HEADER.ImageBase
    for s in pe.sections:
        start = s.VirtualAddress
        end = start + max(s.Misc_VirtualSize, s.SizeOfRawData)
        if start <= rva < end:
            return s.PointerToRawData + (rva - start)
    return None


def main():
    pe_path = sys.argv[1]
    sites = [int(x, 16) for x in sys.argv[2:]]
    pe = pefile.PE(pe_path)
    base = pe.OPTIONAL_HEADER.ImageBase
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    iat = build_iat_name_map(pe)
    data = pe.__data__

    sink_calls = Counter()
    for va in sites:
        off = va_to_off(pe, va)
        before, after = 64, 40
        start_va = va - before
        start_off = off - before
        chunk = data[start_off:start_off + before + after]
        print("=" * 70)
        print(f"detection site @ {hex(va)}")
        print("-" * 70)
        near_calls = []
        for insn in md.disasm(chunk, start_va):
            annot = ""
            if insn.mnemonic in ("call", "jmp"):
                if "[" in insn.op_str:
                    try:
                        inside = insn.op_str[insn.op_str.index("[") + 1:insn.op_str.index("]")]
                        if inside.startswith("0x") and int(inside, 16) in iat:
                            annot = f"   ; {iat[int(inside,16)]}"
                    except Exception:
                        pass
                else:
                    # direct call — record potential sink (after the site)
                    if insn.address > va:
                        try:
                            tgt = int(insn.op_str, 16)
                            near_calls.append(tgt)
                        except Exception:
                            pass
            mark = ">>" if insn.address == va else "  "
            print(f"{mark} {insn.address:#010x}  {insn.mnemonic} {insn.op_str}{annot}")
        if near_calls:
            sink_calls[near_calls[0]] += 1
        print()

    print("=" * 70)
    print("Direct call targets immediately after each site (candidate shared sink):")
    for tgt, cnt in sink_calls.most_common():
        print(f"    {hex(tgt)}  x{cnt}")


if __name__ == "__main__":
    main()
