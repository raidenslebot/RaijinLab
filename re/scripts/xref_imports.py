"""
xref_imports.py — Locate import-thunk call sites for AC-critical APIs.

For a target PE, resolves the IAT thunk address (VA) of each API of interest,
then scans .text for `call dword [thunk]` (FF 15 <abs32>) and
`jmp dword [thunk]` (FF 25 <abs32>) references, printing the caller VA and a
short disassembly window around each site.

Usage:
    python xref_imports.py <pe_path> [api1 api2 ...]

If no APIs are given, a default AC-relevant watchlist is used.
"""
import sys
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CS_MODE_64

DEFAULT_WATCH = [
    # debugger / anti-debug
    "IsDebuggerPresent", "CheckRemoteDebuggerPresent", "OutputDebugStringA",
    # process/module enumeration
    "CreateToolhelp32Snapshot", "GetModuleHandleW", "GetProcAddress",
    "GetModuleFileNameW", "GetModuleFileNameA", "K32GetProcessMemoryInfo",
    # memory / integrity
    "VirtualProtect", "VirtualAllocEx", "VirtualAlloc", "GetVolumePathNameW",
    "GetThreadContext", "GetCurrentThread",
    # dbghelp (stack walking / minidump — used for integrity + crash telemetry)
    "StackWalk64", "MiniDumpWriteDump", "SymInitialize", "SymFromAddr",
    # timing (anti-debug via delta)
    "QueryPerformanceCounter", "GetTickCount",
    # crypto (token / hash)
    "CryptGenRandom", "CryptAcquireContextA",
    # process control (watchdog kill)
    "WaitForSingleObject", "CreateFileW",
]


def rva_to_va(pe, rva):
    return pe.OPTIONAL_HEADER.ImageBase + rva


def get_text_section(pe):
    for s in pe.sections:
        name = s.Name.rstrip(b"\x00").decode(errors="replace")
        if name == ".text":
            return s
    # fallback: first executable section
    for s in pe.sections:
        if s.Characteristics & 0x20000000:
            return s
    return pe.sections[0]


def build_iat_map(pe):
    """Return {api_name: iat_thunk_VA} for all imports."""
    m = {}
    if not hasattr(pe, "DIRECTORY_ENTRY_IMPORT"):
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]]
        )
    base = pe.OPTIONAL_HEADER.ImageBase
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        dll = entry.dll.decode(errors="replace")
        for imp in entry.imports:
            if imp.name:
                name = imp.name.decode(errors="replace")
                m[name] = (imp.address, dll)  # imp.address is already VA (base+rva)
    return m


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    pe_path = Path(sys.argv[1])
    watch = sys.argv[2:] if len(sys.argv) > 2 else DEFAULT_WATCH

    pe = pefile.PE(str(pe_path))
    is64 = pe.FILE_HEADER.Machine == 0x8664
    mode = CS_MODE_64 if is64 else CS_MODE_32
    md = Cs(CS_ARCH_X86, mode)
    md.detail = False

    base = pe.OPTIONAL_HEADER.ImageBase
    iat = build_iat_map(pe)

    # target thunk VAs we care about
    targets = {}
    for api in watch:
        if api in iat:
            thunk_va, dll = iat[api]
            targets[thunk_va] = (api, dll)

    print(f"[*] {pe_path.name}  base={hex(base)}  arch={'x64' if is64 else 'x86'}")
    print(f"[*] {len(targets)}/{len(watch)} watched APIs resolved in IAT")
    missing = [a for a in watch if a not in iat]
    if missing:
        print(f"[*] not imported: {', '.join(missing)}")
    print()

    sec = get_text_section(pe)
    text = sec.get_data()
    text_va = base + sec.VirtualAddress
    print(f"[*] scanning .text  va={hex(text_va)}  size={len(text)}\n")

    # scan for FF 15 (call [mem]) and FF 25 (jmp [mem]) with abs32 operand
    results = {va: [] for va in targets}
    i = 0
    n = len(text)
    while i < n - 6:
        b = text[i]
        if b == 0xFF and text[i + 1] in (0x15, 0x25):
            operand = int.from_bytes(text[i + 2:i + 6], "little")
            # x86: operand is absolute VA of the thunk
            if operand in targets:
                caller_va = text_va + i
                kind = "call" if text[i + 1] == 0x15 else "jmp"
                results[operand].append((caller_va, kind))
                i += 6
                continue
        i += 1

    total = 0
    for thunk_va, (api, dll) in sorted(targets.items(), key=lambda kv: kv[1][0]):
        sites = results[thunk_va]
        total += len(sites)
        print(f"=== {api}  ({dll})  thunk={hex(thunk_va)}  xrefs={len(sites)} ===")
        for caller_va, kind in sites[:40]:
            print(f"    {kind:4} @ {hex(caller_va)}")
        if len(sites) > 40:
            print(f"    ... +{len(sites) - 40} more")
        print()
    print(f"[*] total xref sites: {total}")


if __name__ == "__main__":
    main()
