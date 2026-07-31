"""Search large MPQs for Ascension addon paths without loading full file into RAM."""
import struct, os, zlib
from pathlib import Path

def crypt_table():
    t=[0]*0x500; seed=0x00100001
    for i in range(0x100):
        for j in range(5):
            seed=(seed*125+3)%0x2AAAAB; t1=(seed&0xFFFF)<<16
            seed=(seed*125+3)%0x2AAAAB; t[i+j*0x100]=t1|(seed&0xFFFF)
    return t
CT=crypt_table()
def hash_string(s, ht):
    s=s.upper().replace('/','\\').encode('ascii'); seed1,seed2=0x7FED7FED,0xEEEEEEEE
    for ch in s:
        seed1=CT[(ht*0x100)+ch]^((seed1+seed2)&0xFFFFFFFF); seed1&=0xFFFFFFFF
        seed2=(ch+seed1+seed2+(seed2<<5)+3)&0xFFFFFFFF
    return seed1
def decrypt(data,key):
    seed=0xEEEEEEEE; out=bytearray()
    for i in range(0,len(data)//4*4,4):
        seed=(seed+CT[0x400+(key&0xFF)])&0xFFFFFFFF
        val=struct.unpack_from('<I',data,i)[0]
        val=(val^((key+seed)&0xFFFFFFFF))&0xFFFFFFFF
        out+=struct.pack('<I',val)
        key=(((~key<<21)+0x11111111)|(key>>11))&0xFFFFFFFF
        seed=(val+seed+(seed<<5)+3)&0xFFFFFFFF
    return bytes(out)+data[len(data)//4*4:]

class MPQLazy:
    def __init__(self, path):
        self.path=path
        self.f=open(path,'rb')
        # find header in first 0x1000
        head=self.f.read(0x1000)
        off=head.find(b'MPQ\x1a')
        if off<0:
            # search further
            self.f.seek(0)
            chunk=self.f.read(1024*1024)
            off=chunk.find(b'MPQ\x1a')
        if off<0: raise ValueError('no mpq')
        self.base=off
        self.f.seek(off)
        h=self.f.read(32)
        self.header_size,self.archive_size,self.format_version,self.block_size_shift=struct.unpack_from('<IIHH',h,4)
        self.hash_table_pos,self.block_table_pos,self.hash_table_size,self.block_table_size=struct.unpack_from('<IIII',h,16)
        self.sector_size=512<<self.block_size_shift
        self.f.seek(off+self.hash_table_pos)
        ht_raw=self.f.read(self.hash_table_size*16)
        ht=decrypt(ht_raw, hash_string('(hash table)',3))
        self.hash_table=[struct.unpack_from('<IIHHI',ht,i*16) for i in range(self.hash_table_size)]
        self.f.seek(off+self.block_table_pos)
        bt_raw=self.f.read(self.block_table_size*16)
        bt=decrypt(bt_raw, hash_string('(block table)',3))
        self.block_table=[struct.unpack_from('<IIII',bt,i*16) for i in range(self.block_table_size)]
    def find(self,name):
        ha,hb=hash_string(name,1),hash_string(name,2)
        start=hash_string(name,0)%self.hash_table_size
        i=start
        while True:
            a,b,loc,plat,bi=self.hash_table[i]
            if bi==0xFFFFFFFF: return None
            if bi!=0xFFFFFFFE and a==ha and b==hb: return bi
            i=(i+1)%self.hash_table_size
            if i==start: return None
    def close(self): self.f.close()

ADDONS=[
"AscensionUI","Ascension_CharacterAdvancement","Ascension_NamePlates","Ascension_RandomModeShared",
"Ascension_RandomMode","Ascension_SkillCards","Ascension_HandOfFate","Ascension_Collections",
"Ascension_AuctionHouse","Ascension_LFG","Ascension_Mythic","Ascension_Store","Ascension_Reforge",
"Ascension_TalentBuilder","Ascension_Spellbook","Ascension_CharacterPanel","Ascension_Map",
"Ascension_Minimap","Ascension_ActionBars","Ascension_Chat","Ascension_Tooltips","Ascension_UnitFrames",
"Ascension_GMTools","Postal","DBM-Core","WeakAuras","Details","BigWigs","TomTom","Questie",
"Ascension_Ironman","Ascension_Felforged","Ascension_Wildcard","Ascension_Crusader","Ascension_Survivalist",
"Ascension_Nightmare","Ascension_Resolute","Blizzard_CombatLog"
]
# more from FrameXML load log
extras=["Ascension_RandomModeShared"]
paths=[]
for a in ADDONS:
    paths += [
      f"Interface\\AddOns\\{a}\\{a}.toc",
      f"Interface\\AddOns\\{a}\\{a}.lua",
      f"Interface\\AddOns\\{a}\\{a}.xml",
    ]

data=Path(r"C:\Ascension\Launcher\resources\ascension-live\Data")
mpqs=sorted(list(data.glob("patch*.MPQ"))+list(data.glob("patch*.mpq"))+list((data/"enUS").glob("*.MPQ")), key=lambda p:p.stat().st_size)
# include medium/large custom
found={}
for mpq in mpqs:
    if mpq.stat().st_size < 50_000: continue
    try:
        m=MPQLazy(str(mpq))
    except Exception as e:
        continue
    hits=[]
    for name in paths:
        if m.find(name) is not None:
            hits.append(name)
    m.close()
    if hits:
        found[mpq.name]=hits
        print(mpq.name, "->", len(hits), "hits")
        for h in hits[:20]: print(" ", h)
print("DONE total mpqs with hits", len(found))
Path(r"C:\Ascension\Workspace\RaijinLab\re\mpq_extract\addon_locations.json").write_text(__import__('json').dumps(found,indent=2),encoding='utf-8')
