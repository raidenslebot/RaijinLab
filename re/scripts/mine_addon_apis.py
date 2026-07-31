import re
from pathlib import Path
root=Path(r"C:\Ascension\Workspace\RaijinLab\re\mpq_extract\ascension_addons")
apis=set(); events=set()
for p in root.rglob("*.lua"):
    t=p.read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"\b([A-Za-z0-9_]*Ascension[A-Za-z0-9_]*)\b", t):
        apis.add(m.group(1))
    for m in re.finditer(r"\b(Get|Set|Is|Has|Can|Toggle|Open|Load|Request|Send)[A-Z][A-Za-z0-9_]{3,}\b", t):
        if "Ascension" in m.group(0) or m.group(0).startswith(("GetCustom","LoadAscension")):
            apis.add(m.group(0))
    for m in re.finditer(r"['\"]([A-Z][A-Z0-9_]{5,})['\"]", t):
        s=m.group(1)
        if "ASCENSION" in s or s.startswith("PLAYER_") or "CARD" in s or "MYTHIC" in s:
            events.add(s)
out=Path(r"C:\Ascension\Workspace\RaijinLab\notes\08_extracted_addon_apis.txt")
out.write_text("\n".join(sorted(apis))+"\n---EVENTS---\n"+"\n".join(sorted(events)), encoding="utf-8")
print("apis", len(apis), "events", len(events), "files", sum(1 for _ in root.rglob("*") if _.is_file()))
for a in sorted(apis)[:60]:
    print(a)
