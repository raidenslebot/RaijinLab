from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

# ---- 1. the menu store whitelist must know about "vision" ------------------
OLD = '''        src = {"quest": quest_src, "gather": gather_src}.get(store)'''
NEW = '''        # "vision" is edited by the Debug tab's world-rendering toggles and is
        # consumed by core/Vision.lua rather than a module file, so it needs its
        # own source here - otherwise the guard reports a real, wired panel as
        # editing an unknown store.
        vision_src = (ADDON / "core/Vision.lua").read_text(encoding="utf-8")
        src = {"quest": quest_src, "gather": gather_src,
               "vision": vision_src}.get(store)'''
assert OLD in s, "store map not found"
s = s.replace(OLD, NEW, 1)

# ---- 2. the default is now ON, by explicit request -------------------------
OLD2 = '''-- ---- layers are off by default and individually toggleable ----
vc("nothing is on by default", V.any() == false)
V.set("grid", true)
vc("a layer can be turned on", V.enabled("grid") == true)
vc("...without turning on the others", V.enabled("path") == false)
V.set("grid", false)
vc("and off again", V.any() == false)'''
NEW2 = '''-- ---- layers default ON and are individually toggleable ----
--
-- CHANGED DELIBERATELY (user request): every layer now ships enabled. Rendering
-- is the only way to see what the bot believes, and shipping it dark meant the
-- one tool for diagnosing "it looks confused" was itself off, silently.
--
-- The important half of the old contract is KEPT and strengthened below: an
-- explicit false must survive, because a default that re-asserts itself over a
-- user's choice makes the off switch look broken. That is why cfg() defaults
-- only a nil, never a false.
vc("every layer is on by default", V.enabled("grid") == true and V.enabled("path") == true)
vc("any() is true by default", V.any() == true)
V.set("grid", false)
vc("a layer can be turned off", V.enabled("grid") == false)
vc("...without turning off the others", V.enabled("path") == true)
-- the crucial one: re-reading config must NOT resurrect the disabled layer
vc("an explicit off survives a re-read", V.enabled("grid") == false)
V.set("grid", true)
vc("and on again", V.enabled("grid") == true)'''
assert OLD2 in s, "vision default block not found"
s = s.replace(OLD2, NEW2, 1)
p.write_text(s, encoding="utf-8")
print("tests updated: vision defaults ON, off survives; menu knows the vision store")
