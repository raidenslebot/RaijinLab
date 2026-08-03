"""Quick Lua syntax check on the files I edited."""
import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except Exception as e:  # noqa: BLE001
    print("lupa not available:", e)
    sys.exit(0)

lua = LuaRuntime(unpack_returned_tuples=False)
files = [
    r"addon\core\Actions.lua",
    r"addon\core\rotation\Executor.lua",
]
bad = 0
for f in files:
    src = Path(f).read_text(encoding="utf-8", errors="replace")
    try:
        lua.execute(src)
        print("OK  :", f)
    except Exception as e:  # noqa: BLE001
        bad += 1
        print("FAIL:", f, "->", e)
sys.exit(1 if bad else 0)
