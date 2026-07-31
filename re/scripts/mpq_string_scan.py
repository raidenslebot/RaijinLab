import os, re
from pathlib import Path
data = Path(r"C:\Ascension\Launcher\resources\ascension-live\Data")
patterns = [b"Interface\\AddOns\\", b"Interface/AddOns/", b"AscensionUI", b"Ascension_Character", b"FrameXML.toc", b"GlueXML.toc"]
# scan files under 2.5GB
hits = []
for p in sorted(data.rglob("*.MPQ")) + sorted(data.rglob("*.mpq")):
    size = p.stat().st_size
    if size > 2_500_000_000:
        print("skip huge", p.name)
        continue
    print("scan", p.name, f"{size/1e6:.0f}MB")
    with open(p, "rb") as f:
        # read in chunks
        buf = b""
        pos = 0
        found_here = set()
        while True:
            chunk = f.read(8*1024*1024)
            if not chunk:
                break
            data_c = buf[-64:] + chunk
            for pat in patterns:
                start = 0
                while True:
                    i = data_c.find(pat, start)
                    if i < 0: break
                    # extract ascii around
                    abs_i = pos - len(buf[-64:] if buf else b"") + i
                    # get string
                    s = data_c[i:i+120]
                    s = s.split(b"\x00")[0].decode("latin1","ignore")
                    if s not in found_here:
                        found_here.add(s)
                        hits.append((p.name, s))
                    start = i+1
            buf = chunk
            pos += len(chunk)
        if found_here:
            print(" ", len(found_here), "hits")
out = Path(r"C:\Ascension\Workspace\RaijinLab\re\mpq_extract\interface_string_hits.txt")
out.write_text("\n".join(f"{a}\t{b}" for a,b in hits), encoding="utf-8")
print("TOTAL hits", len(hits), "->", out)
# unique paths-like
paths = sorted(set(b for _,b in hits))
print("unique samples:")
for s in paths[:80]:
    print(" ", s)
