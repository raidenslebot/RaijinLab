"""
Rebrand cxmplexpack -> RaijinLab across all Lua/TOC/MD files.
Also apply Ascension-oriented TOC and disable SL-only modules by default.
"""
from pathlib import Path
import re

ROOT = Path(r"C:\Ascension\Workspace\RaijinLab\addon")

# Order matters for nested replacements
REPLACEMENTS = [
    # saved vars / globals first (longer forms first)
    ("cxmplex_savedvars", "RaijinLabDB"),
    ("cxmplexpack", "RaijinLab"),
    ("CxmplexPack", "RaijinLab"),
    ("CXMPLEX", "RAIJINLAB"),
    ("cxmplex", "RaijinLab"),
    ("Cxmplex", "RaijinLab"),
]

# Auth token from old unlocker FS APIs — rename to RaijinLab marker (runtime will define)
OLD_TOKEN = "r9svH6YxEQbNTZGH"
NEW_TOKEN = "RaijinLabRuntime"

def transform(text: str, path: Path) -> str:
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    text = text.replace(OLD_TOKEN, NEW_TOKEN)
    # unlocker entry: keep IsLinuxClient as runtime bridge name documented,
    # but also provide alias path via comment - actually keep IsLinuxClient
    # since that's what unlockers historically inject. We'll wrap it.
    return text

toc = """## Interface: 30300
## Title: |cff7ec8e3Raijin|r|cffffffffLab|r
## Notes: Ascension automation lab — object manager, drawing, farming, travel, loot
## Author: RaijinLab
## Version: 0.1.0-ascension
## SavedVariables: RaijinLabDB
## DefaultState: enabled
## X-Website: local
## X-Category: Development
## X-RaijinLab-Target: Ascension 3.3.5
libs\\bitops.lua
core\\Variables.lua
core\\API.lua
core\\Hooks.lua
core\\objects\\Functions.lua
core\\objects\\Manager.lua
core\\objects\\Tracker.lua
core\\Drawing.lua
core\\Events.lua
core\\Farming.lua
modules\\arena\\Awareness.lua
modules\\travel\\Travel.lua
modules\\loot\\Looter.lua
modules\\farming\\Farms.lua
modules\\farming\\Farmer.lua
modules\\questing\\Quests.lua
core\\ChatHandler.lua
init.lua
"""

readme = """# RaijinLab

**Ascension-targeted** evolution of the former cxmplexpack unlocker addon.

## Target

- Client: Ascension Live (3.3.5 / 12340 class)
- Requires: RaijinLab Runtime (unlocker APIs; see `../runtime/CONTRACT.md`)
- Does **not** run as a vanilla addon — needs injected Lua natives

## Modules

| Module | Status on Ascension |
|--------|---------------------|
| Object Manager / Tracker | Core — keep |
| Drawing | Core — keep |
| Farming / Loot / Travel | Core — keep |
| Arena Awareness | Keep (PvP) |
| Quest helpers | Partial (3.3.5 quest APIs) |
| Torghast | **Removed** from TOC (SL-only) |

## Install (dev)

```
Interface/AddOns/RaijinLab/   <- copy contents of this `addon/` folder
```

## Namespace

- Global: `RaijinLab`
- SavedVariables: `RaijinLabDB`
- Runtime bridge: `IsLinuxClient` (historical unlocker symbol) or `RaijinLab.Runtime`

## Version

0.1.0-ascension — rebrand + TOC port in progress
"""

count = 0
for path in ROOT.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix.lower() not in {".lua", ".toc", ".md", ".formatrc", ".txt"}:
        continue
    raw = path.read_text(encoding="utf-8", errors="replace")
    new = transform(raw, path)
    if new != raw:
        path.write_text(new, encoding="utf-8", newline="\n")
        count += 1
        print("updated", path.relative_to(ROOT))

(ROOT / "RaijinLab.toc").write_text(toc, encoding="utf-8", newline="\n")
(ROOT / "README.md").write_text(readme, encoding="utf-8", newline="\n")
print("files content-updated:", count)
print("TOC written")

# verify residual cxmplex
left = []
for path in ROOT.rglob("*"):
    if path.suffix.lower() not in {".lua", ".toc", ".md"}:
        continue
    t = path.read_text(encoding="utf-8", errors="replace")
    if re.search(r"cxmplex", t, re.I):
        left.append(str(path.relative_to(ROOT)))
print("residual cxmplex refs:", left or "NONE")
