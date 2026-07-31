"""Recover main() from the stale .pyc after the harness file was truncated.

The .py lost everything from partway through main() to EOF, so the suite has been
running nothing and exiting 0 - the worst possible failure for a test harness,
because it looks exactly like success. The .pyc predates the truncation and holds
main() as a compiled code object, including the large inline Lua blocks as string
constants. This dumps what is there so the tail can be rebuilt faithfully rather
than guessed at.
"""
import dis
import importlib.util
import marshal
import sys
from pathlib import Path

PYC = Path(r"C:\Ascension\Workspace\RaijinLab\tests\__pycache__\run_suite_tests.cpython-312.pyc")
raw = PYC.read_bytes()
code = marshal.loads(raw[16:])          # 3.7+ header is 16 bytes

mains = [c for c in code.co_consts
         if hasattr(c, "co_name") and c.co_name == "main"]
if not mains:
    print("no main() in pyc")
    sys.exit(1)
m = mains[0]

print("=== main() recovered ===")
print("consts:", len(m.co_consts), " names:", len(m.co_names))

# Which test_* functions main() calls, in bytecode order.
called = []
for ins in dis.get_instructions(m):
    if ins.opname in ("LOAD_GLOBAL", "LOAD_NAME") and isinstance(ins.argval, str):
        n = ins.argval.lstrip("+")
        if n.startswith("test_") or n.startswith("_check_"):
            if n not in called:
                called.append(n)
print("\n=== groups main() invokes, in order ===")
for c in called:
    print("   ", c)

out = Path(r"C:\Ascension\Workspace\RaijinLab\tools\_main_consts.txt")
with out.open("w", encoding="utf-8") as f:
    for i, c in enumerate(m.co_consts):
        if isinstance(c, str):
            f.write(f"\n===== CONST {i} (len {len(c)}) =====\n{c}\n")
print("\nstring constants written to", out)

# Also recover the module-level tail (anything defined after the truncation point)
tail = [c.co_name for c in code.co_consts if hasattr(c, "co_name")]
print("\n=== all top-level defs in the pyc ===")
print(", ".join(tail))
