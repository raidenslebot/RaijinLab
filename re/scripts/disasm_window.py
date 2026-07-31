"""
disasm_window.py — Linear disassembly window around one or more VAs.

Usage:
    python disasm_window.py <pe_path> <va> [va2 ...] [--before N] [--after N]

VAs are hex (0x...). --before/--after control bytes of context (default 48/64).
Resolves IAT call targets to API names inline where possible.
"""
import sys
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CS_MODE_64


def parse_args(argv):
    pe_path = argv[0]
    vas = []
    before, after = 48, 96
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--before":
            before = int(argv[i + 1]); i += 2
        elif a == "--after":
            after = int(argv[i + 1]); i += 2
        else:
            vas.append(int(a, 16)); i += 1
    return pe_path, vas, before, after


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
            return s.PointerToRawData + (rva - start), s
    return None, None


def main():
    pe_path, vas, before, after = parse_args(sys.argv[1:])
    pe = pefile.PE(pe_path)
    base = pe.OPTIONAL_HEADER.ImageBase
    is64 = pe.FILE_HEADER.Machine == 0x8664
    md = Cs(CS_ARCH_X86, CS_MODE_64 if is64 else CS_MODE_32)
    iat = build_iat_name_map(pe)
    data = pe.__data__

    for va in vas:
        off, sec = va_to_off(pe, va)
        print("=" * 72)
        if off is None:
            print(f"VA {hex(va)} not mapped to a section")
            continue
        secname = sec.Name.rstrip(b"\x00").decode(errors="replace")
        start_off = off - before
        start_va = va - before
        chunk = data[start_off:start_off + before + after]
        print(f"VA {hex(va)}  section={secname}  (showing -{before}/+{after})")
        print("-" * 72)
        for insn in md.disasm(chunk, start_va):
            marker = ">>" if insn.address == va else "  "
            annot = ""
            # annotate call/jmp [abs] to IAT
            if insn.mnemonic in ("call", "jmp") and "[" in insn.op_str:
                try:
                    inside = insn.op_str[insn.op_str.index("[") + 1:insn.op_str.index("]")]
                    if inside.startswith("0x"):
                        tgt = int(inside, 16)
                        if tgt in iat:
                            annot = f"   ; {iat[tgt]}"
                except Exception:
                    pass
            print(f"{marker} {insn.address:#010x}  {insn.bytes.hex():<20} {insn.mnemonic} {insn.op_str}{annot}")
        print()


if __name__ == "__main__":
    main()
