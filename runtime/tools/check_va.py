import struct
path = r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe"
with open(path, "rb") as f:
    pe = f.read()
e_lfanew = struct.unpack_from("<I", pe, 0x3C)[0]
magic = struct.unpack_from("<H", pe, e_lfanew + 24)[0]
if magic == 0x10B:
    image_base = struct.unpack_from("<I", pe, e_lfanew + 52)[0]
else:
    image_base = struct.unpack_from("<Q", pe, e_lfanew + 48)[0]
num_sec = struct.unpack_from("<H", pe, e_lfanew + 6)[0]
opt_size = struct.unpack_from("<H", pe, e_lfanew + 20)[0]
sec_off = e_lfanew + 24 + opt_size
print("image_base", hex(image_base))

def va_to_off(va):
    rva = va - image_base if va >= image_base else va
    for i in range(num_sec):
        off = sec_off + i * 40
        name = pe[off : off + 8].split(b"\0")[0]
        vsz, va_s, rsz, raw = struct.unpack_from("<IIII", pe, off + 8)
        if va_s <= rva < va_s + max(vsz, rsz):
            return raw + (rva - va_s), name.decode(errors="replace")
    return None, None

for va in [0x006FDA00, 0x00819210, 0x004D4D70, 0x004D3790, 0x004D4DB0, 0x0053E060, 0x00727400]:
    off, sec = va_to_off(va)
    if off is None:
        print(hex(va), "MISSING")
        continue
    b = pe[off : off + 12]
    print(f"{va:#010x} {sec:8s} file={off:#x} bytes={b.hex(' ')}")
