import re
from pathlib import Path
api=Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\API.lua").read_text(encoding="utf-8",errors="replace")
calls=sorted(set(re.findall(r'RLCall\(\s*["\']([^"\']+)["\']', api)))
Path(r"C:\Ascension\Workspace\RaijinLab\runtime\API_SURFACE.txt").write_text("\n".join(calls), encoding="utf-8")
print(len(calls))
for c in calls:
    print(c)
