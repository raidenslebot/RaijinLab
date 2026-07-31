"""Prove the quest-gate tests exercise the PRODUCTION path, not the fallback.

If the harness were still leaving Know absent, mutating the Know branch would
change nothing and the suite would stay green - a test that proves nothing while
looking like proof. So: break only the Know branch and require a failure.
"""
import subprocess
import sys
from pathlib import Path

QF = Path(r"C:\Ascension\Workspace\RaijinLab\modules")  # placeholder, fixed below
QF = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestFrame.lua")
orig = QF.read_text(encoding="utf-8")

TARGET = 'completable = K.assume(K.probe(IsQuestCompletable), true, "quest_completable")'
assert TARGET in orig, "Know branch not found - mutation would be vacuous"

# invert the collapse: unknown now REFUSES instead of attempting
mutated = orig.replace(
    TARGET,
    'completable = K.assume(K.probe(IsQuestCompletable), false, "quest_completable")',
    1,
)
QF.write_text(mutated, encoding="utf-8")
try:
    r = subprocess.run([sys.executable, "tests/run_suite_tests.py"],
                       cwd=r"C:\Ascension\Workspace\RaijinLab",
                       capture_output=True, text=True, timeout=600)
    code = r.returncode
finally:
    QF.write_text(orig, encoding="utf-8")

print("mutated exit =", code, "(must be non-zero)")
if code == 0:
    print("VACUOUS: the tests do not reach the Know branch")
    sys.exit(1)
print("OK: the tests drive the production path")
