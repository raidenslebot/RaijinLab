"""Find callers of 0x512B00 / 0x512AB0 (the 0x512B07 crash function) and
understand what pointer they pass. The crash: 0x512B07 = `mov eax,[esi+4]`
with esi=garbage GUID-pointer. Find who calls it with a GUID pointer."""
import struct
from capstone import *
from capstone.x86 import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000

TEXT_VA = 0x401000
TEXT_FO = 0x400
TEXT_SIZE = 0x5DF3B3 - 0x401000  # .text ends ~0x5DF3B3 (from earlier notes)

def va2fo(va):
    return TEXT_FO + (va - TEXT_VA)

def fo2va(fo):
    return TEXT_VA + (fo - TEXT_FO)

md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

TARGETS = {0x00512B00: 'resolver512B00', 0x00512AB0: 'helper512AB0'}

# Scan .text for direct calls to the targets
calls = {t: [] for t in TARGETS}
for fo in range(TEXT_FO, TEXT_FO + TEXT_SIZE - 5):
    b = data[fo:fo+5]
    if b[0] == 0xE8:  # call rel32
        rel = struct.unpack('<i', b[1:5])[0]
        src = fo2va(fo)
        dst = (src + 5 + rel) & 0xFFFFFFFF
        if dst in TARGETS:
            calls[dst].append(src)

for t, name in TARGETS.items():
    print(f"=== callers of {name} (0x{t:08X}) : {len(calls[t])} ===")
    for src in calls[t]:
        print(f"  0x{src:08X}")

print()
# Also look for pushes of the target address (register-indirect calls)
print("=== indirect refs (push 0x512B00/0x512AB0) ===")
for fo in range(TEXT_FO, TEXT_FO + TEXT_SIZE - 5):
    b = data[fo:fo+5]
    if b[0] == 0x68:  # push imm32
        imm = struct.unpack('<I', b[1:5])[0]
        if imm in TARGETS:
            print(f"  0x{fo2va(fo):08X}: push {TARGETS[imm]}")
