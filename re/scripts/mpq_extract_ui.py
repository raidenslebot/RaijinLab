"""Improved MPQ extract for known UI paths from enUS patches."""
import struct, zlib, os
from pathlib import Path

def crypt_table():
    t = [0]*0x500
    seed = 0x00100001
    for i in range(0x100):
        for j in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t[i + j*0x100] = t1 | (seed & 0xFFFF)
    return t
CT = crypt_table()

def hash_string(s, ht):
    s = s.upper().replace('/','\\').encode('ascii')
    seed1, seed2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in s:
        seed1 = CT[(ht*0x100)+ch] ^ ((seed1+seed2)&0xFFFFFFFF)
        seed1 &= 0xFFFFFFFF
        seed2 = (ch + seed1 + seed2 + (seed2<<5) + 3) & 0xFFFFFFFF
    return seed1

def decrypt(data, key):
    seed = 0xEEEEEEEE
    out = bytearray()
    for i in range(0, len(data)//4*4, 4):
        seed = (seed + CT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        val = struct.unpack_from('<I', data, i)[0]
        val = (val ^ ((key + seed) & 0xFFFFFFFF)) & 0xFFFFFFFF
        out += struct.pack('<I', val)
        key = (((~key << 21) + 0x11111111) | (key >> 11)) & 0xFFFFFFFF
        seed = (val + seed + (seed << 5) + 3) & 0xFFFFFFFF
    return bytes(out) + data[len(data)//4*4:]

class MPQ:
    def __init__(self, path):
        self.path = path
        with open(path,'rb') as f: self.data = f.read()
        off = self.data.find(b'MPQ\x1a')
        if off < 0: raise ValueError('no header')
        self.base = off
        h = self.data[off:off+32]
        self.header_size, self.archive_size, self.format_version, self.block_size_shift = struct.unpack_from('<IIHH', h, 4)
        self.hash_table_pos, self.block_table_pos, self.hash_table_size, self.block_table_size = struct.unpack_from('<IIII', h, 16)
        self.sector_size = 512 << self.block_size_shift
        ht_raw = self.data[off+self.hash_table_pos:off+self.hash_table_pos+self.hash_table_size*16]
        ht = decrypt(ht_raw, hash_string('(hash table)', 3))
        self.hash_table = [struct.unpack_from('<IIHHI', ht, i*16) for i in range(self.hash_table_size)]
        bt_raw = self.data[off+self.block_table_pos:off+self.block_table_pos+self.block_table_size*16]
        bt = decrypt(bt_raw, hash_string('(block table)', 3))
        self.block_table = [struct.unpack_from('<IIII', bt, i*16) for i in range(self.block_table_size)]

    def find(self, name):
        ha, hb = hash_string(name,1), hash_string(name,2)
        start = hash_string(name,0) % self.hash_table_size
        i = start
        while True:
            a,b,loc,plat,bi = self.hash_table[i]
            if bi == 0xFFFFFFFF: return None
            if bi != 0xFFFFFFFE and a==ha and b==hb: return bi
            i = (i+1)%self.hash_table_size
            if i==start: return None

    def extract(self, name):
        bi = self.find(name)
        if bi is None: return None
        fpos, csize, fsize, flags = self.block_table[bi]
        if not (flags & 0x80000000): return None
        data = self.data[self.base+fpos:self.base+fpos+csize]
        key = None
        if flags & 0x00010000:
            key = hash_string(name.replace('/','\\').split('\\')[-1], 3)
            if flags & 0x00020000:
                key = (key + fpos) ^ fsize
            data = decrypt(data, key)
        # single unit
        if flags & 0x01000000:
            if flags & 0x00000200:
                return self._decomp(data, fsize)
            return data[:fsize]
        # sectors
        if flags & (0x200|0x100):
            nsec = (fsize + self.sector_size - 1) // self.sector_size
            # sector offset table is (nsec+1) DWORDs, may be encrypted with key-1
            table_size = (nsec+1)*4
            soff = data[:table_size]
            if key is not None:
                soff = decrypt(soff, (key - 1) & 0xFFFFFFFF)
            offsets = [struct.unpack_from('<I', soff, i*4)[0] for i in range(nsec+1)]
            out = bytearray()
            for s in range(nsec):
                chunk = data[offsets[s]:offsets[s+1]]
                if key is not None:
                    # sector key = key + sector index
                    chunk = decrypt(chunk, (key + s) & 0xFFFFFFFF)
                if flags & 0x200:
                    expect = min(self.sector_size, fsize - s*self.sector_size)
                    if len(chunk) < expect:
                        dec = self._decomp(chunk, expect)
                        if dec is None: return None
                        out += dec
                    else:
                        out += chunk[:expect]
                else:
                    out += chunk
            return bytes(out[:fsize])
        return data[:fsize]

    def _decomp(self, data, fsize):
        if not data: return b''
        mask = data[0]
        payload = data[1:]
        # zlib
        if mask & 0x02:
            try:
                return zlib.decompress(payload)
            except Exception:
                try:
                    return zlib.decompress(data)  # sometimes no mask
                except Exception:
                    return None
        if mask == 0:
            return payload[:fsize]
        # try raw zlib
        try:
            return zlib.decompress(data)
        except Exception:
            return data[:fsize]

PATHS = [
 "Interface\\FrameXML\\FrameXML.toc",
 "Interface\\GlueXML\\GlueXML.toc",
 "Interface\\FrameXML\\ChatFrame.lua",
 "Interface\\FrameXML\\UIParent.lua",
 "Interface\\FrameXML\\WorldMapFrame.lua",
 "Interface\\FrameXML\\GameTooltip.lua",
 "Interface\\FrameXML\\UIParent.xml",
 "Interface\\AddOns\\AscensionUI\\AscensionUI.toc",
 "Interface\\AddOns\\Ascension_CharacterAdvancement\\Ascension_CharacterAdvancement.toc",
 "Interface\\AddOns\\Ascension_NamePlates\\Ascension_NamePlates.toc",
 "Interface\\AddOns\\Ascension_RandomModeShared\\Ascension_RandomModeShared.toc",
 "Interface\\AddOns\\Postal\\Postal.toc",
 "Interface\\AddOns\\AscensionUI\\AscensionUI.lua",
]

# also try reading FrameXML.toc content for more includes
mpqs = [
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\enUS\patch-enUS.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\enUS\patch-enUS-2.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\enUS\patch-enUS-3.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-A.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-R.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-N.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-I.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-Q.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-U.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-V.MPQ"),
 Path(r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-Z.MPQ"),
]
out = Path(r"C:\Ascension\Workspace\RaijinLab\re\mpq_extract\ui")
out.mkdir(parents=True, exist_ok=True)
extracted = 0
for mpq_path in mpqs:
    if not mpq_path.exists():
        continue
    size = mpq_path.stat().st_size
    print(f"=== {mpq_path.name} {size/1e6:.0f}MB ===")
    try:
        m = MPQ(str(mpq_path))
    except Exception as e:
        print(" open fail", e); continue
    for name in PATHS:
        if m.find(name) is None:
            continue
        data = m.extract(name)
        print(f"  {name}: find=OK extract={'OK '+str(len(data)) if data else 'FAIL'}")
        if data:
            dest = out / name.replace('\\','/')
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            extracted += 1
            if name.endswith('.toc'):
                try:
                    print(data.decode('utf-8','replace')[:500])
                except: pass
print("extracted files:", extracted)
