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


def fo2va(fo):
    for n, v, vsz, r, rsz in secs:
        if r <= fo < r + rsz:
            return v + (fo - r), n
    return None, None


md = Cs(CS_ARCH_X86, CS_MODE_32)

# Xrefs to g_WorldFrame (0xB7436C). For each, back up to find the enclosing
# function (scan back to a push ebp prologue within ~0x200 bytes) and show it.
fo_targets = [0x3bbe, 0x661d, 0x6ec2, 0xf593f, 0xf5961, 0xf6654, 0xf6684,
              0xf9f7d, 0xfa3c6, 0xfad7f, 0x112902, 0x112d63, 0x112dc2,
              0x1186d2, 0x11f893, 0x11f922, 0x11f98c, 0x11facf, 0x1243ea,
              0x12533c]

for fo in fo_targets:
    va, sec = fo2va(fo)
    if sec != '.text':
        continue
    # find enclosing function: scan back up to 0x300 bytes for push ebp / ret
    pro = None
    for back in range(0x300):
        probe = fo - back
        if probe < 0:
            break
        b0 = data[probe]
        if b0 == 0x55:  # push ebp
            # require a recent ret before it
            proto = data[probe - 1] if probe - 1 >= 0 else 0
            if proto in (0xC3, 0xCC):
                pro = probe
                break
    if pro is None:
        print('FO 0x%05X VA 0x%08X (no enclosing fn found)' % (fo, va))
        continue
    fva = fo2va(pro)[0]
    # dump the bytes around the xref (the instruction using g_WorldFrame)
    code = data[fo - 8:fo + 16]
    instrs = '; '.join('%s %s' % (i.mnemonic, i.op_str) for i in md.disasm(code, va - 8))
    print('FO 0x%05X VA 0x%08X fn=0x%08X :: %s' % (fo, va, fva, instrs))
