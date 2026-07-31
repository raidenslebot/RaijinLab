import marshal
from pathlib import Path

PYC = Path(r"C:\Ascension\Workspace\RaijinLab\tests\__pycache__\run_suite_tests.cpython-312.pyc")
code = marshal.loads(PYC.read_bytes()[16:])
m = [c for c in code.co_consts if hasattr(c, "co_name") and c.co_name == "main"][0]

OUT = Path(r"C:\Ascension\Workspace\RaijinLab\tools\recovered")
OUT.mkdir(exist_ok=True)

big = []
banners = []
for i, c in enumerate(m.co_consts):
    if not isinstance(c, str):
        continue
    if len(c) > 400:
        f = OUT / f"lua_block_{i}.lua"
        f.write_text(c, encoding="utf-8")
        big.append((i, len(c), f.name))
    elif c.startswith("===") or c.startswith("ALL ") or "FAILED" in c or "PASSED" in c:
        banners.append((i, c))

print("=== inline Lua blocks extracted ===")
for i, n, f in big:
    print(f"  const {i}: {n} chars -> {f}")

print("\n=== report / banner strings, in const order ===")
for i, b in banners:
    print(f"  {i}: {b!r}")
