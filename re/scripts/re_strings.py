"""Read the error format strings at 0x9e0e50 / 0x9e1ad0 and the 0xbd078c object
context (its two writers), to understand the canCast-fail message + object."""
from pathlib import Path
import pefile

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase

def read_cstr(va, maxlen=128):
    off = pe.get_offset_from_rva(va - base)
    s = b""
    for i in range(maxlen):
        b = data[off+i]
        if b == 0: break
        s += bytes([b])
    return s.decode('latin1')

for va in (0x9E0E50, 0x9E1AD0, 0x9E0E24, 0x9E289C, 0xA00A88, 0xA082EC, 0xA082D0):
    try:
        print(f"{hex(va)}: {read_cstr(va)!r}")
    except Exception as e:
        print(f"{hex(va)}: <err {e}>")
