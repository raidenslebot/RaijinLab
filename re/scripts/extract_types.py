from pathlib import Path
import re
data = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps\DivxTac.dll").read_bytes()
types = sorted(set(re.findall(rb'[A-Za-z_][A-Za-z0-9_]+(?:\.[A-Za-z_][A-Za-z0-9_]+)+', data)))
keys = [b'Anti', b'Cheat', b'Ban', b'Detour', b'Hack', b'Process', b'Module', b'Debug', b'Managed', b'Offset', b'Service', b'Thread']
types = [t.decode('ascii') for t in types if any(k in t for k in keys)]
Path(r"C:\Ascension\Workspace\RaijinLab\re\divxtac_types.txt").write_text("\n".join(types), encoding="utf-8")
print("types", len(types))
for t in types:
    print(t)
ext = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps\Extensions.dll").read_bytes()
natives = sorted(set(re.findall(rb'(?:Get|Set|Is|Load|Toggle|Open|Close|Send|Request)Ascension[A-Za-z0-9_]+', ext)))
natives = [n.decode() for n in natives]
Path(r"C:\Ascension\Workspace\RaijinLab\notes\06_ascension_getters.txt").write_text("\n".join(natives), encoding="utf-8")
print("natives", len(natives))
for n in natives:
    print(n)
