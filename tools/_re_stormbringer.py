"""Properly RE the Stormbringer proc chain in Ascension.exe.

Goal: find (a) where the client stores that spell 273056 procs spell 273057,
(b) where the 16.7% proc chance and the ICD are read, and (c) the function that
fires 273057. We anchor on data references:
  * 273056 (0x42A80) and 273057 (0x42AF1) as immediate/operand constants.
  * The two spell-table globals already RE'd: 0xBE6D88 (spell table) and the
    table base 0xAD49D0 (this=0xAD49D0 in the 0x4CFD20 decoder) — proc data
    lives in a parallel table the cast/land code indexes by spell id.

We disassemble the 0x4CFD20 spell-decoder and its caller region AND scan the
data section for the proc table (SpellProcEvent-style: procFlags/procChance/
procSpell). This replaces guesswork with a real address map.
"""
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
import struct

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
data = open(EXE, 'rb').read()

def va_to_fo(va):
    return va - IMAGE_BASE - 0x1000 + TEXT_OFF

def disasm_range(start_va, length, label, watch=None):
    print('=' * 78)
    print('%s  start=0x%08X len=0x%X' % (label, start_va, length))
    print('=' * 78)
    fo = va_to_fo(start_va)
    chunk = data[fo:fo+length]
    md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
    watch = watch or {}
    for ins in md.disasm(chunk, start_va):
        op = ins.op_str.lower()
        ann = ''
        for addr, name in watch.items():
            if ('0x%x' % addr) in op or ('0x%08x' % addr) in op:
                ann += '   <=== %s' % name
        # annotate 273056/273057 immediates (0x42A80/0x42AF1)
        for sid, nm in ((0x42A80,'273056 Stormbringer'),(0x42AF1,'273057 proc bolt'),(0x42AF2,'273058 ground')):
            hs = '0x%x' % sid
            if hs in op:
                ann += '   <=== %s' % nm
        print('0x%08X  %-8s %-34s ; %s%s' % (ins.address, ins.mnemonic, ins.op_str,
              ' '.join('%02X' % b for b in ins.bytes), ann))

def collect_calls(start_va, size=0x800):
    fo = va_to_fo(start_va)
    buf = data[fo:fo+size]
    calls = []
    for pos in range(0, len(buf)-5):
        if buf[pos] == 0xE8:
            rel = struct.unpack_from('<i', buf, pos+1)[0]
            calls.append(start_va + pos + 5 + rel)
    # dedup
    seen=set(); u=[]
    for c in calls:
        if c not in seen: seen.add(c); u.append(c)
    return u

# ---- STEP 1: the spell decoder 0x4CFD20 (proven earlier: reads the spell
# record, this=0xAD49D0). Disassemble it + note how proc data might be reached.
print('#'*78)
print('# STEP 1: spell decoder 0x4CFD20 (this=0xAD49D0) — the spell-record reader')
print('#'*78)
disasm_range(0x004CFD20, 0x120, 'spell decoder 0x4CFD20',
             {0x00AD49D0:'spell table obj', 0x00BE6D88:'spell table',
              0x00BE8D98:'spell count'})

# ---- STEP 2: find xrefs to the spell-table object 0xAD49D0 (the proc engine
# also uses it). Scan .text for [0x00AD49D0] / lea 0xad49d0 references.
print()
print('#'*78)
print('# STEP 2: scan all call/load sites referencing 0xAD49D0 (proc engine xrefs)')
print('#'*78)
base_fo = va_to_fo(0x00401000)
text_len = 0x5DD400
tbuf = data[base_fo:base_fo+text_len]
needle_a = struct.pack('<I', 0x00AD49D0)   # mov ecx, 0xad49d0 imm32
needle_b = struct.pack('<I', 0x00AD49D0 ^ 0xFFFFFFFF)  # not helpful
# scan for the imm32 0xad49d0 (little-endian D0 49 AD 00)
pat = bytes([0xD0, 0x49, 0xAD, 0x00])
idx = 0
hits = []
while True:
    i = tbuf.find(pat, idx)
    if i < 0: break
    hits.append(0x00401000 + i)
    idx = i + 1
print('xrefs to 0xAD49D0 (imm32) found at:')
for h in hits[:60]:
    print('  0x%08X' % h)

# ---- STEP 3: the proc-eval region. The main proc function on 3.3.5 reads a
# per-spell proc record. We look near the spell-record decoder for a second
# table pointer. Print any DWORD constants in 0xBE7xxx-0xBE9xxx range seen.
print()
print('#'*78)
print('# STEP 3: dump hits with a small disasm window + all BE-range refs')
print('#'*78)
watch = {0x00AD49D0:'spell table obj', 0x00BE6D88:'spell table',
         0x00BE7D98:'category table', 0x00BE8D98:'spell count'}
for h in hits[:40]:
    disasm_range(h-24 if h-24>0x401000 else h, 0x60, 'xref@0x%08X' % h, watch)
