# Applied one-shot patch scripts

Every file here was written to make ONE edit to the tree and was run once. They
are kept because they record HOW a change was made, not because anything calls
them - nothing does (verified: no reference from any .py/.ps1/.md outside this
folder).

`_rebuild_main.py` was archived 2026-08-03. It is not merely stale, it is
BROKEN AGAINST THE CURRENT SUITE and running it corrupts the file:

* it splits `tests/run_suite_tests.py` on the marker
  `# ==== GENERATED TAIL (tools/_rebuild_main.py) ...`, and **that marker no
  longer exists in the file**. `split(MARK)[0]` therefore returns the WHOLE
  file, and the generated tail is APPENDED to it - a second copy of `main()`,
  `GROUPS` and `_source_guards`. Python uses the last definition, which is why
  regenerating dispatched 46 groups against 36 real ones;
* the duplicate `_source_guards` is old enough to resurrect a retired guard,
  "no C_Timer.After defer in Executor cast path", against an Executor whose
  `C_Timer.After(0)` deliberately prevents a VM-corrupting crash. So the
  corrupted suite stays red until someone "fixes" the Executor by reintroducing
  a client crash;
* and its whole remaining job is obsolete. The module now derives
  `GROUPS = _discover_groups()` from its own namespace precisely so a
  hand-maintained registry cannot disagree with the functions beside it. The
  generator still emits that hand-maintained registry.

Adding a test group needs NO bookkeeping now: define `test_*` in
`tests/run_suite_tests.py` and auto-discovery dispatches it.

Do not add to this folder. Prefer editing files directly; a throwaway script that
survives in `tools/` looks like a tool and costs a reader time every time they
scan the directory.
