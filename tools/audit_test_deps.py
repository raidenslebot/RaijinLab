"""Which test groups exercise only the DEPENDENCY-ABSENT branch?

Found twice on 2026-08-03, both times as a mutation reading MISSED:

  * test_gatherer did not load Know, so RaijinLab.Know was nil, every
    `if Kn then` branch in Gatherer.lua was dead, and the "fishing defaults ON"
    mutation landed in unreachable code.
  * the Executor GCD tests did not mock the bridge, so
    runtime_cooldown_remaining returned 0 at its `HasRuntime()` guard and the
    "runtime cooldown path loses the gate" mutation changed nothing.

Both looked like a missing test. Neither was. A test environment that omits a
dependency does not test a SIMPLER version of the code - it tests a DIFFERENT
BRANCH, and the branch it tests is usually the trivial one.

THIS TOOL DOES NOT REPORT BUGS. Plenty of groups omit a dependency on purpose:
test_facing and test_cast_facing_arc both force RaijinLab.HasRuntime to false
precisely so the pure-Lua fallback is what gets exercised. That is correct and
deliberate. What this prints is a TRIAGE LIST - for each entry, ask: does this
group mean to test the fallback, or does it think it is testing the real path?

Run:  python tools/audit_test_deps.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon"
SUITE = ROOT / "tests" / "run_suite_tests.py"

# dependency -> (marker that the LOADED addon file needs it,
#                markers that the TEST BODY provides or deliberately stubs it)
DEPS = {
    "Know": (("RaijinLab.Know",), ("RaijinLab.Know", "core/Know.lua")),
    "runtime bridge": (("RuntimeCall", "HasRuntime"), ("HasRuntime", "RuntimeCall")),
}


def audit():
    src = SUITE.read_text(encoding="utf-8", errors="replace")
    parts = re.split(r"^def (test_[a-z_0-9]+)\(\) -> list:", src, flags=re.M)
    rows = []
    for i in range(1, len(parts), 2):
        name, body = parts[i], parts[i + 1]
        files = re.findall(r'ADDON / "([^"]+\.lua)"', body)
        if not files:
            continue
        loaded = ""
        for rel in files:
            f = ADDON / rel
            if f.exists():
                loaded += f.read_text(encoding="utf-8", errors="replace")
        missing = []
        for dep, (needs, provides) in DEPS.items():
            if any(n in loaded for n in needs) and not any(p in body for p in provides):
                missing.append(dep)
        if missing:
            rows.append((name, ", ".join(missing), files))
    return rows


def main() -> int:
    rows = audit()
    if not rows:
        print("every group provides the dependencies its modules reach for")
        return 0
    print("TRIAGE: groups exercising only the dependency-absent branch")
    print("(not necessarily wrong - a fallback test SHOULD omit the dependency)")
    print()
    for name, missing, files in rows:
        print("  %-32s missing %-22s loads %s" % (name, missing, ", ".join(files[:2])))
    print()
    print("%d group(s) to triage. For each: is the fallback the intended subject?" % len(rows))
    # Deliberately exit 0. This is a triage aid, not a gate - failing the build
    # on it would push someone to silence it, and a silenced audit is worse than
    # none. The gate that matters is the mutation: if a mutation reads MISSED,
    # check THIS list before concluding the test is absent.
    return 0


if __name__ == "__main__":
    sys.exit(main())
