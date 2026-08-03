import struct
from capstone import *

exe = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(exe, 'rb').read()

pe = struct.unpack_from('<I', data, 0x3C)[0]
num = struct.unpack_from('<H', data, pe + 6)[0]
opt = struct.unpack_from('<H', data, pe + 20)[0]
sect = pe + 24 + opt
secs = []
for i in range(num):
    off = sect + i * 40
    name = data[off:off + 8].split(b'\0')[0].decode('latin1')
    vsz, vaddr, rsz, raddr = struct.unpack_from('<IIII', data, off + 8)
    secs.append((name, vaddr, vsz, raddr, rsz))

text = next(s for s in secs if s[0] == '.text')
t_va, t_off, t_vsz, t_rsz = text[1], text[3], text[2], text[4]

# Image base + section VA math (this exe: image base 0x400000; rva->va = +base)
IMAGE_BASE = 0x400000
t_va, t_off, t_vsz, t_rsz = text[1], text[3], text[2], text[4]
# true VA of .text start
TEXT_VA = IMAGE_BASE + t_va


def rva_to_fo(rva):
    return t_off + (rva - t_va)


def rva_to_va(rva):
    return IMAGE_BASE + rva


# scan the .text bytes for disp32 == 0xB7436C (mov reg,[0xB7436C])
target = 0x00B7436C
pat = struct.pack('<I', target)
textbytes = data[t_off:t_off + t_rsz]

md = Cs(CS_ARCH_X86, CS_MODE_32)
hits = []
start = 0
while True:
    i = textbytes.find(pat, start)
    if i < 0:
        break
    rva = t_va + i
    hits.append(rva)
    start = i + 1

print('total [0xB7436C] disp refs in .text:', len(hits))
for rva in hits:
    fo = rva_to_fo(rva)
    va = rva_to_va(rva)
    pro = None
    for back in range(1, 0x400):
        p = fo - back
        if p < t_off:
            break
        if data[p] == 0x55:
            prev = data[p - 1] if p - 1 >= t_off else 0
            if prev == 0xC3:
                pro = p
                break
    fva = (IMAGE_BASE + t_va + (pro - t_off)) if pro else 0
    code = textbytes[max(0, i - 4): i + 16]
    instr = '; '.join('%s %s' % (x.mnemonic, x.op_str) for x in md.disasm(code, va - 4))
    print('VA 0x%08X fn=0x%08X :: %s' % (va, fva, instr))

