import re
from pathlib import Path
data = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps\Extensions.dll").read_bytes()
# extract format strings around MemoryBridge and table
for pat in [rb'MemoryBridge[^\x00]{0,120}', rb'Created table[^\x00]{0,80}', rb'Allocated[^\x00]{0,60}',
            rb'handle[^\x00]{0,40}', rb'protocol[^\x00]{0,60}', rb'object token[^\x00]{0,80}',
            rb'AnticheatMgr[^\x00]{0,80}', rb'ANTICHEAT[^\x00]{0,80}', rb'MMgr64[^\x00]{0,100}',
            rb'DivxTac[^\x00]{0,80}', rb'LoadLibrary[^\x00]{0,40}', rb'spawn[^\x00]{0,60}',
            rb'CreateProcess[^\x00]{0,60}']:
    hits = sorted(set(m.group().decode('latin1','ignore') for m in re.finditer(pat, data, re.I)))
    if hits:
        print("====", pat[:40])
        for h in hits[:40]:
            print(" ", repr(h)[:160])

print("\n==== MMgr64 format strings ====")
m = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps\MMgr64.exe").read_bytes()
for pat in [rb'MemoryBridge[^\x00]{0,140}', rb'table[^\x00]{0,80}', rb'protocol[^\x00]{0,60}',
            rb'command[^\x00]{0,80}', rb'token[^\x00]{0,80}', rb'PID[^\x00]{0,60}',
            rb'invalid[^\x00]{0,60}', rb'rejected[^\x00]{0,80}']:
    hits = sorted(set(x.group().decode('latin1','ignore') for x in re.finditer(pat, m, re.I)))
    if hits:
        print("====", pat[:40])
        for h in hits[:30]:
            print(" ", repr(h)[:160])
