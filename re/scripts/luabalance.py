"""Crude Lua keyword-balance check for the modified addon files."""
import re

files = [
    r"c:\Ascension\Workspace\RaijinLab\addon\core\World.lua",
    r"c:\Ascension\Workspace\RaijinLab\addon\core\rotation\Executor.lua",
    r"c:\Ascension\Workspace\RaijinLab\addon\core\rotation\BasicRules.lua",
    r"c:\Ascension\Workspace\RaijinLab\addon\core\rotation\Engine.lua",
    r"c:\Ascension\Workspace\RaijinLab\addon\core\rotation\Conditions.lua",
]
OPEN = re.compile(r"\b(if|function|do|while|for|repeat)\b")
CLOSE = re.compile(r"\b(end|until)\b")
for fp in files:
    s = open(fp, encoding="utf-8", errors="replace").read()
    # strip comments and string literals crudely
    s2 = re.sub(r"--.*", "", s)
    s2 = re.sub(r'"(\\.|[^"\\])*"', "S", s2)
    s2 = re.sub(r"'(\\.|[^'\\])*'", "S", s2)
    opens = len(OPEN.findall(s2))
    ends = len(CLOSE.findall(s2))
    print(fp.split("addon")[-1], "opens=", opens, "ends=", ends,
          "BALANCED" if opens == ends else "*** UNBALANCED ***")
