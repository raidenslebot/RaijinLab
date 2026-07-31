from lupa import LuaRuntime
from pathlib import Path

lua = LuaRuntime(unpack_returned_tuples=True)
check = lua.eval(
    "function(s, n)\n"
    "  local ld = load or loadstring\n"
    "  local f, e = ld(s, n)\n"
    "  if f then return 'ok' else return tostring(e) end\n"
    "end"
)
root = Path(r"C:\Ascension\Workspace\RaijinLab")
for rel in [
    "addon/core/API.lua",
    "addon/core/World.lua",
    "addon/core/rotation/Executor.lua",
    "addon/core/ChatHandler.lua",
]:
    print(rel, check((root / rel).read_text(encoding="utf-8"), "@" + rel))
bad = 0
for p in (root / "addon").rglob("*.lua"):
    if "archive" in p.parts:
        continue
    for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if any(ord(c) > 127 for c in line):
            print("ASCII", p, i, repr(line[:80]))
            bad += 1
            break
print("ascii_bad", bad)
