# Applied one-shot patch scripts

Every file here was written to make ONE edit to the tree and was run once. They
are kept because they record HOW a change was made, not because anything calls
them - nothing does (verified: no reference from any .py/.ps1/.md outside this
folder). `_rebuild_main.py` stayed in `tools/` because it IS still referenced.

Do not add to this folder. Prefer editing files directly; a throwaway script that
survives in `tools/` looks like a tool and costs a reader time every time they
scan the directory.
