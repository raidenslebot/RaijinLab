import re, json
from pathlib import Path
from collections import Counter

dump = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps")
interesting = re.compile(
    rb'(?i)(anticheat|anti.?cheat|warden|mmgr|extension|inject|hook|detour|vmprotect|themida|vmp|ban|kick|scan|module|integrity|checksum|hash|driver|\.sys|ntdll|NtQuery|CreateRemote|WriteProcess|ReadProcess|VirtualAlloc|VirtualProtect|LoadLibrary|GetProcAddress|IsDebugger|NtSetInformation|SeDebug|Process32|EnumProcess|OpenProcess|TerminateProcess|cheat|hack|bot|unlocker|lua|addon|IsLinuxClient|EWT|MinHook|EasyHook|polyhook|discord|ascension|raijin|cxmplex)'
)
ascii_re = re.compile(rb'[\x20-\x7e]{6,}')

report = {}
for p in sorted(dump.glob("*")):
    data = p.read_bytes()
    strings = [m.group().decode('ascii', errors='ignore') for m in ascii_re.finditer(data)]
    hits = []
    for s in strings:
        if interesting.search(s.encode('ascii', errors='ignore')) or any(k in s.lower() for k in [
            'anticheat','warden','vmp','themida','mmgr','extension','inject','detour',
            'ntdll','virtualprotect','isdebugger','ascension','cheat','bot','lua unlock'
        ]):
            hits.append(s)
    # unique preserve order
    seen=set(); uniq=[]
    for h in hits:
        if h not in seen:
            seen.add(h); uniq.append(h)
    report[p.name] = {
        "string_count": len(strings),
        "interesting_count": len(uniq),
        "interesting": uniq[:200],
    }
    print("="*60, p.name)
    print("strings:", len(strings), "interesting:", len(uniq))
    for s in uniq[:60]:
        print(" ", s[:160])

out = Path(r"C:\Ascension\Workspace\RaijinLab\re\string_scan.json")
out.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("\nWrote", out)
