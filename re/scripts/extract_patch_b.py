"""Extract Ascension addon sources from patch-B.MPQ"""
import struct, zlib
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

class MPQ:
    def __init__(self, path):
        with open(path,'rb') as f: self.data=f.read()
        off=self.data.find(b'MPQ\x1a'); self.base=off
        h=self.data[off:off+32]
        _,_,_,self.block_size_shift=struct.unpack_from('<IIHH',h,4)
        self.hash_table_pos,self.block_table_pos,self.hash_table_size,self.block_table_size=struct.unpack_from('<IIII',h,16)
        self.sector_size=512<<self.block_size_shift
        ht=decrypt(self.data[off+self.hash_table_pos:off+self.hash_table_pos+self.hash_table_size*16], hash_string('(hash table)',3))
        self.hash_table=[struct.unpack_from('<IIHHI',ht,i*16) for i in range(self.hash_table_size)]
        bt=decrypt(self.data[off+self.block_table_pos:off+self.block_table_pos+self.block_table_size*16], hash_string('(block table)',3))
        self.block_table=[struct.unpack_from('<IIII',bt,i*16) for i in range(self.block_table_size)]
    def find(self,name):
        ha,hb=hash_string(name,1),hash_string(name,2)
        start=hash_string(name,0)%self.hash_table_size; i=start
        while True:
            a,b,loc,plat,bi=self.hash_table[i]
            if bi==0xFFFFFFFF: return None
            if bi!=0xFFFFFFFE and a==ha and b==hb: return bi
            i=(i+1)%self.hash_table_size
            if i==start: return None
    def extract(self,name):
        bi=self.find(name)
        if bi is None: return None
        fpos,csize,fsize,flags=self.block_table[bi]
        if not (flags&0x80000000): return None
        data=self.data[self.base+fpos:self.base+fpos+csize]
        key=None
        if flags&0x10000:
            key=hash_string(name.replace('/','\\').split('\\')[-1],3)
            if flags&0x20000: key=(key+fpos)^fsize
            data=decrypt(data,key)
        if flags&0x01000000:
            if flags&0x200: return self._decomp(data,fsize)
            return data[:fsize]
        if flags&(0x200|0x100):
            nsec=(fsize+self.sector_size-1)//self.sector_size
            table_size=(nsec+1)*4
            soff=data[:table_size]
            if key is not None: soff=decrypt(soff,(key-1)&0xFFFFFFFF)
            offsets=[struct.unpack_from('<I',soff,i*4)[0] for i in range(nsec+1)]
            out=bytearray()
            for s in range(nsec):
                chunk=data[offsets[s]:offsets[s+1]]
                if key is not None: chunk=decrypt(chunk,(key+s)&0xFFFFFFFF)
                expect=min(self.sector_size,fsize-s*self.sector_size)
                if flags&0x200 and len(chunk)<expect:
                    dec=self._decomp(chunk,expect)
                    if dec is None: return None
                    out+=dec
                else:
                    out+=chunk[:expect]
            return bytes(out[:fsize])
        return data[:fsize]
    def _decomp(self,data,fsize):
        if not data: return b''
        if data[0]&0x02:
            try: return zlib.decompress(data[1:])
            except: pass
        try: return zlib.decompress(data)
        except: return data[:fsize]

# Get listfile from patch-B
mpq_path=r"C:\Ascension\Launcher\resources\ascension-live\Data\patch-B.MPQ"
m=MPQ(mpq_path)
out=Path(r"C:\Ascension\Workspace\RaijinLab\re\mpq_extract\ascension_addons")
out.mkdir(parents=True, exist_ok=True)
lf=m.extract("(listfile)")
names=[]
if lf:
    text=lf.decode('utf-8','replace')
    (out/'_listfile.txt').write_text(text,encoding='utf-8')
    names=[ln.strip() for ln in text.splitlines() if ln.strip()]
    print("listfile", len(names))
else:
    print("no listfile, using known")
    names=[]

# filter interface
ui=[n for n in names if 'Interface' in n or n.lower().endswith(('.lua','.toc','.xml','.xml'))]
print("ui paths in listfile", len(ui))
# also known
known='''Interface\AddOns\AscensionUI\AscensionUI.toc
Interface\AddOns\AscensionUI\AscensionUI.lua
Interface\AddOns\Ascension_CharacterAdvancement\Ascension_CharacterAdvancement.toc
Interface\AddOns\Ascension_NamePlates\Ascension_NamePlates.toc
Interface\AddOns\Ascension_NamePlates\Ascension_NamePlates.lua
Interface\AddOns\Ascension_RandomModeShared\Ascension_RandomModeShared.toc
Interface\AddOns\Ascension_SkillCards\Ascension_SkillCards.toc
Interface\AddOns\Ascension_Collections\Ascension_Collections.toc
Interface\AddOns\Postal\Postal.toc
Interface\AddOns\Postal\Postal.lua
Interface\AddOns\Ascension_Wildcard\Ascension_Wildcard.toc'''.splitlines()
all_names=list(dict.fromkeys(ui+known))
# If listfile has more Interface\AddOns files, take all of them
addons=[n for n in all_names if n.replace('/','\\').lower().startswith('interface\\addons')]
print("extracting", len(addons), "addon files")
ok=0
for name in addons:
    name=name.replace('/','\\')
    data=m.extract(name)
    if not data:
        # try
        continue
    dest=out/name.replace('\\','/')
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    ok+=1
    if name.endswith('.toc'):
        print("===", name, "===", len(data))
        print(data.decode('utf-8','replace')[:800])
print("extracted", ok)
