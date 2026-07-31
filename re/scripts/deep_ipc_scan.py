import re
from pathlib import Path
from collections import Counter

dump = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps")
patterns = [
    rb'MemoryBridge[A-Za-z0-9_]*',
    rb'MMgr[A-Za-z0-9_]*',
    rb'DivxTac[A-Za-z0-9_]*',
    rb'AntiCheat[A-Za-z0-9_.]*',
    rb'ClientExtensions[A-Za-z0-9_]*',
    rb'protocol[= ]?\d',
    rb'SharedMemory[A-Za-z0-9_]*',
    rb'CreateFileMapping[A-Za-z0-9A]*',
    rb'MapViewOfFile[A-Za-z0-9A]*',
    rb'OpenFileMapping[A-Za-z0-9A]*',
    rb'NamedPipe[A-Za-z0-9_\\]*',
    rb'\\\\\.\\pipe\\[A-Za-z0-9_]+',
    rb'Global\\[A-Za-z0-9_]+',
    rb'Local\\[A-Za-z0-9_]+',
    rb'ascension[A-Za-z0-9_\-]*',
    rb'Warden[A-Za-z0-9_]*',
    rb'IsLinuxClient',
    rb'FrameScript_[A-Za-z0-9_]+',
    rb'RegisterLua[A-Za-z0-9_]*',
    rb'lua_[a-z]+',
]
ascii_re = re.compile(rb'[\x20-\x7e]{4,}')

for name in ['MMgr64.exe','Extensions.dll','DivxTac.dll','Ascension.exe']:
    data = (dump/name).read_bytes()
    print("="*70, name)
    # all interesting pattern hits
    for pat in patterns:
        found = sorted(set(m.group().decode('ascii','ignore') for m in re.finditer(pat, data, re.I)))
        if found:
            print(f"  [{pat.decode('ascii','ignore')[:40]}] ({len(found)})")
            for f in found[:25]:
                print("   ", f[:120])
    # MemoryBridge nearby strings
    for m in re.finditer(rb'MemoryBridge[\x20-\x7e]{0,80}', data):
        print("  CTX:", m.group().decode('ascii','ignore')[:100])
