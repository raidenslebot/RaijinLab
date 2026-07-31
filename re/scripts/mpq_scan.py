"""
Minimal WoW MPQ reader: locate files by hash using (listfile) when present,
or brute known paths. Supports MPQ v1 (3.3.5 era) basic tables.
"""
import struct, os, sys, zlib, io
from pathlib import Path

# crypt table
_crypt = None
def crypt_table():
    global _crypt
    if _crypt is not None:
        return _crypt
    _crypt = [0]*0x500
    seed = 0x00100001
    for i in range(0x100):
        for j in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            _crypt[i + j*0x100] = t1 | t2
    return _crypt

def hash_string(s, hash_type):
    s = s.upper().replace('/','\\').encode('ascii', 'ignore')
    seed1 = 0x7FED7FED
    seed2 = 0xEEEEEEEE
    ct = crypt_table()
    for ch in s:
        seed1 = ct[(hash_type * 0x100) + ch] ^ ((seed1 + seed2) & 0xFFFFFFFF)
        seed1 &= 0xFFFFFFFF
        seed2 = (ch + seed1 + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return seed1

def decrypt(data, key):
    ct = crypt_table()
    seed = 0xEEEEEEEE
    out = bytearray()
    for i in range(0, len(data) - len(data)%4, 4):
        seed = (seed + ct[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        val = struct.unpack_from('<I', data, i)[0]
        val = (val ^ ((key + seed) & 0xFFFFFFFF)) & 0xFFFFFFFF
        out += struct.pack('<I', val)
        key = (((~key << 21) + 0x11111111) | (key >> 11)) & 0xFFFFFFFF
        seed = (val + seed + (seed << 5) + 3) & 0xFFFFFFFF
    return bytes(out)

class MPQ:
    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        data = self.f.read(32)
        # find MPQ header
        self.f.seek(0)
        blob = self.f.read()
        off = blob.find(b'MPQ\x1a')
        if off < 0:
            raise ValueError('no MPQ header')
        self.base = off
        h = blob[off:off+32]
        self.header_size, self.archive_size, self.format_version, self.block_size = struct.unpack_from('<IIHH', h, 4)
        self.hash_table_pos, self.block_table_pos, self.hash_table_size, self.block_table_size = struct.unpack_from('<IIII', h, 16)
        # read hash table
        ht_off = self.base + self.hash_table_pos
        ht_raw = blob[ht_off:ht_off + self.hash_table_size * 16]
        ht_dec = decrypt(ht_raw, hash_string('(hash table)', 3))
        self.hash_table = []
        for i in range(self.hash_table_size):
            e = struct.unpack_from('<IIHHI', ht_dec, i*16)
            self.hash_table.append({'hash_a':e[0],'hash_b':e[1],'locale':e[2],'platform':e[3],'block_index':e[4]})
        bt_off = self.base + self.block_table_pos
        bt_raw = blob[bt_off:bt_off + self.block_table_size * 16]
        bt_dec = decrypt(bt_raw, hash_string('(block table)', 3))
        self.block_table = []
        for i in range(self.block_table_size):
            e = struct.unpack_from('<IIII', bt_dec, i*16)
            self.block_table.append({'file_pos':e[0],'comp_size':e[1],'file_size':e[2],'flags':e[3]})
        self.blob = blob  # keep for small archives; for large, re-read
        self._full = blob if len(blob) < 200_000_000 else None
        if self._full is None:
            # don't keep 2GB in ram
            self.blob = None
            self.f.seek(0)

    def _read(self, pos, size):
        if self.blob is not None:
            return self.blob[pos:pos+size]
        self.f.seek(pos)
        return self.f.read(size)

    def find(self, name):
        ha = hash_string(name, 1)
        hb = hash_string(name, 2)
        start = hash_string(name, 0) % self.hash_table_size
        i = start
        while True:
            e = self.hash_table[i]
            if e['block_index'] == 0xFFFFFFFF:
                return None
            if e['block_index'] != 0xFFFFFFFE and e['hash_a']==ha and e['hash_b']==hb:
                return e['block_index']
            i = (i+1) % self.hash_table_size
            if i == start:
                return None

    def extract(self, name):
        bi = self.find(name)
        if bi is None:
            return None
        b = self.block_table[bi]
        flags = b['flags']
        # FILE_EXISTS
        if not (flags & 0x80000000):
            return None
        data = self._read(self.base + b['file_pos'], b['comp_size'])
        # encrypted?
        if flags & 0x00010000:  # encrypted
            key = hash_string(name.split('\\')[-1].split('/')[-1], 3)
            if flags & 0x00020000:  # fix key
                key = (key + b['file_pos']) ^ b['file_size']
            data = decrypt(data[:len(data)-len(data)%4], key) + data[len(data)-len(data)%4:]
        # compressed single unit?
        if flags & 0x01000000:  # single unit
            if flags & 0x00000200:  # compressed
                # first byte compression mask
                if data[0] == 0x02:  # zlib
                    return zlib.decompress(data[1:])
                if data[0] == 0x10:  # bzip2 - skip
                    return None
            return data[:b['file_size']]
        # sector compression - simplified
        if flags & 0x00000200 or flags & 0x00000100:
            # try zlib on whole if small
            try:
                if data[0:1] in (b'\x02',):
                    return zlib.decompress(data[1:])
            except: pass
            # sector table
            sector_size = 512 << (self.block_size if hasattr(self,'block_size') else 3)
            # block_size in header is power of 2 shift from 512
            return None  # complex path
        return data[:b['file_size']]

    def close(self):
        self.f.close()

KNOWN = [
    "(listfile)",
    "Interface\\FrameXML\\FrameXML.toc",
    "Interface\\GlueXML\\GlueXML.toc",
    "Interface\\AddOns\\AscensionUI\\AscensionUI.toc",
    "Interface\\AddOns\\Ascension_CharacterAdvancement\\Ascension_CharacterAdvancement.toc",
    "Interface\\AddOns\\Ascension_NamePlates\\Ascension_NamePlates.toc",
    "Interface\\AddOns\\Ascension_RandomModeShared\\Ascension_RandomModeShared.toc",
    "Interface\\AddOns\\Postal\\Postal.toc",
    "Interface\\FrameXML\\ChatFrame.lua",
    "Interface\\FrameXML\\UIParent.lua",
    "DBFilesClient\\Spell.dbc",
    "DBFilesClient\\SkillLine.dbc",
]

def scan_mpq(path, out_dir, extract_ui=True):
    path = Path(path)
    print(f"=== {path.name} ({path.stat().st_size/1e6:.1f} MB) ===")
    try:
        m = MPQ(str(path))
    except Exception as e:
        print("  open fail:", e)
        return []
    found = []
    # listfile
    lf = m.extract("(listfile)")
    names = list(KNOWN)
    if lf:
        try:
            text = lf.decode('utf-8', errors='replace')
            paths = [ln.strip() for ln in text.splitlines() if ln.strip()]
            print(f"  listfile entries: {len(paths)}")
            # filter Interface
            ui = [p for p in paths if 'Interface' in p or p.endswith('.toc') or p.endswith('.lua')]
            print(f"  interface-ish: {len(ui)}")
            names = list(dict.fromkeys(names + ui[:5000]))
            (out_dir / f"{path.stem}_listfile.txt").write_text(text[:2_000_000], encoding='utf-8', errors='replace')
        except Exception as e:
            print("  listfile decode fail", e)
    else:
        print("  no listfile")

    for name in names[:2000]:
        bi = m.find(name)
        if bi is not None:
            found.append(name)
            if extract_ui and (name.endswith(('.lua','.toc','.xml','.txt')) or 'listfile' in name.lower()):
                data = m.extract(name)
                if data:
                    dest = out_dir / path.stem / name.replace('\\','/').replace('..','_')
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(data)
    print(f"  found {len(found)} known/listed paths")
    m.close()
    return found

def main():
    data = Path(r"C:\Ascension\Launcher\resources\ascension-live\Data")
    out = Path(r"C:\Ascension\Workspace\RaijinLab\re\mpq_extract")
    out.mkdir(parents=True, exist_ok=True)
    # Prefer smaller custom patches first (C* series often has custom content)
    mpqs = sorted(data.glob("patch-C*.MPQ"), key=lambda p: p.stat().st_size)
    mpqs += [data/"patch.MPQ", data/"lichking.MPQ", data/"expansion.MPQ"]
    # also enUS patch
    mpqs += list((data/"enUS").glob("patch*.MPQ")) if (data/"enUS").exists() else []
    all_found = {}
    for mpq in mpqs:
        if not mpq.exists():
            continue
        # skip huge ones for full extract first pass - only listfile probe under 500MB unless C series
        size = mpq.stat().st_size
        if size > 800_000_000 and not mpq.name.startswith("patch-C"):
            print(f"SKIP large {mpq.name}")
            continue
        try:
            found = scan_mpq(mpq, out, extract_ui=True)
            all_found[mpq.name] = found
        except Exception as e:
            print("ERR", mpq, e)
    (out/"_found_summary.json").write_text(__import__('json').dumps(all_found, indent=2), encoding='utf-8')
    print("DONE")

if __name__ == "__main__":
    main()
