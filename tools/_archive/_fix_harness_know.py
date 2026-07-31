from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

# 1. Remove the mangled insertion (a real newline landed inside a py string).
lines = s.split("\n")
out, i = [], 0
while i < len(lines):
    if lines[i].strip().startswith('lua.execute("RaijinLab = RaijinLab or {}'):
        # drop this broken statement and its continuation line
        i += 1
        while i < len(lines) and 'qf_src' not in lines[i]:
            i += 1
        continue
    out.append(lines[i])
    i += 1
s = "\n".join(out)

# also drop the orphaned comment block if it survived
for junk in (
    "    # QuestFrame resolves its gate through RaijinLab.Know in game. If the harness\n",
    "    # leaves Know absent the tests silently exercise the fallback branch instead of\n",
    "    # the real one - passing while proving nothing about production. Load it first.\n",
    "    know_src = (ADDON / \"core/Know.lua\").read_text(encoding=\"utf-8\")\n",
):
    s = s.replace(junk, "")

anchor = '    qf_src = (ADDON / "modules/questing/QuestFrame.lua").read_text(encoding="utf-8")'
assert anchor in s, "anchor gone - refusing to guess"

# 2. Re-insert correctly, building the Lua with an f-string over a real newline.
NL = chr(10)
ins = (
    "    # QuestFrame resolves its gate through RaijinLab.Know in game. If the harness\n"
    "    # leaves Know absent, these tests silently exercise the FALLBACK branch instead\n"
    "    # of the real one - passing while proving nothing about production code.\n"
    '    know_src = (ADDON / "core/Know.lua").read_text(encoding="utf-8")\n'
    '    lua.execute("RaijinLab = RaijinLab or {}")\n'
    '    lua.execute("RaijinLab.Know = (function()" + chr(10) + know_src + chr(10) + "end)()")\n'
    + anchor
)
s = s.replace(anchor, ins, 1)
p.write_text(s, encoding="utf-8")
print("harness repaired: Know loaded before QuestFrame")
