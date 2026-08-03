"""Disassemble RaijinLabRuntime.dll at 0x1F090 (crash eip = base+0x1F090, AV_READ fault=0x3C)."""
from pathlib import Path
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

DLL = Path(r"C:\Ascension\Workspace\RaijinLab\runtime\build_x86\RaijinLabRuntime.dll")
data = DLL.read_bytes()
md = Cs(CS_ARCH_X86, CS_MODE_32)

# Crash eip 0x66AAF090 at runtime base 0x5DAF0000 => offset 0x1F090
off = 0x1F090
chunk = data[off - 0x80:off + 0x120]
print(f"=== DLL bytes around 0x1F090 (file off 0x{off:X}) ===")
for i, insn in enumerate(md.disasm(chunk, 0x5DAF0000 + (off - 0x80))):
    mark = "  <<< EIP" if insn.address == 0x66AAF090 else ""
    print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}{mark}")

# Find which function contains 0x1F090 — scan for the nearest preceding push ebp/mov ebp,esp
print("\n=== nearest preceding function prologue ===")
for scan in range(off, max(off - 0x2000, 0), -1):
    if data[scan:scan+3] == b"\x55\x8b\xec":
        print(f"  prologue at 0x{scan:X} (va 0x{0x5DAF0000+scan:X})")
        break
