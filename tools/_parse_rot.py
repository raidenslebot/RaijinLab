import pathlib, re, sys

paths = list(pathlib.Path(r"C:\Ascension\Launcher\resources\ascension-live\Logs").glob("raijinlab_config_*.lua"))
paths += list(pathlib.Path(r"C:\Ascension\Launcher\resources\ascension-live\WTF").rglob("RaijinLab.lua"))
paths = sorted(paths, key=lambda p: p.stat().st_mtime, reverse=True)[:3]
for p in paths:
    print("FILE", p)
    t = p.read_text(encoding="utf-8", errors="ignore")
    for m in re.finditer(r"active_rotation[^\n]{0,80}", t):
        print(" ", m.group(0)[:80])
    for name in ("Plague Strike", "Icy Touch", "Consecration"):
        pos = 0
        n = 0
        while n < 3:
            i = t.find('["name"] = "%s"' % name, pos)
            if i < 0:
                i = t.find('["name"]="%s"' % name, pos)
            if i < 0:
                i = t.find('name"] = "%s"' % name, pos)
            if i < 0:
                break
            chunk = t[max(0, i - 100) : i + 900]
            print("====", name, n, "====")
            print(chunk[:850])
            print()
            pos = i + 1
            n += 1
    print("---")
