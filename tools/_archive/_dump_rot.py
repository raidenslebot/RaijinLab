from pathlib import Path
import re

p = Path(r"C:\Ascension\Launcher\resources\ascension-live\WTF\Account\testpurpose\SavedVariables\RaijinLab.lua")
t = p.read_text(encoding="utf-8", errors="ignore")
print("active_config:", re.findall(r'active_config\s*=\s*"([^"]+)"', t))
print("active_rotation:", re.findall(r'active_rotation\s*=\s*"([^"]+)"', t))
# Find Raiden Reaper block roughly
for name in ("Raiden Reaper", "Raiden", "Reaper", "Default"):
    i = t.find('["' + name + '"]')
    print(name, "at", i)

# Dump a large chunk around Raiden Reaper
key = '["Raiden Reaper"]'
i = t.find(key)
if i < 0:
    # try without space variants
    for m in re.finditer(r'\["([^"]*Reaper[^"]*)"\]', t):
        print("reaper-like", m.group(1), "at", m.start())
        i = m.start()
        key = m.group(0)
        break
if i >= 0:
    # extract nested braces roughly
    start = t.find("{", i)
    depth = 0
    end = start
    for j in range(start, min(start + 50000, len(t))):
        c = t[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    block = t[i:end]
    Path(r"C:\Ascension\Workspace\RaijinLab\tools\_raiden_dump.txt").write_text(block, encoding="utf-8")
    print("wrote dump len", len(block))
    # summarize slots
    spells = re.findall(r'\["spell_id"\]\s*=\s*(\d+)', block)
    names = re.findall(r'\["name"\]\s*=\s*"([^"]+)"', block)
    conds = re.findall(r'\["id"\]\s*=\s*"([^"]+)"', block)
    print("spell_ids", spells)
    print("names", names[:40])
    print("condition ids", conds)
else:
    print("NOT FOUND")
    # list top-level rotation keys under rotations
    for m in re.finditer(r'\["rotations"\]\s*=\s*\{', t):
        print("rotations table at", m.start())
        chunk = t[m.start(): m.start() + 2000]
        print(chunk[:1500])
