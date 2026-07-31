from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

# The questom fixture builds real booleans, which the LIVE object manager never
# produces - that is precisely why this bug survived every test run.
OLD = "IsTiedToQuest = tied and true or false"
assert OLD in s, "questom fixture not found"

anchor = "-- ---- THE STUBBED QUEST-GIVER SENSOR"
assert anchor in s
BLOCK = '''-- ---- 0 IS TRUTHY IN LUA -------------------------------------------------
-- THE bug behind "runs into buildings and objects with no idea what is
-- happening". ObjectIsQuestObjective is a `return PushNumber(L, 0)` stub, and
-- the object manager wrote that 0 straight into IsTiedToQuest. Every consumer
-- tests the field for truthiness, and 0 is TRUE in Lua - so every npc, chair,
-- mailbox and campfire in render range was a "quest objective".
--
-- list_objectives then matched all of them and nearest_objective returned
-- whatever was physically closest, which the engine walked to and interacted
-- with. Meanwhile the giver-candidate filter rejected every npc for being an
-- "objective", so that fallback could never open either. One defect, both
-- symptoms, opposite signs.
--
-- These fixtures use the NUMBER 0, which is what the live OM actually produces.
-- The existing fixtures build real booleans and therefore could never catch it.
local function tiedcase(v)
    return { Guid = "g1", Object = "o1", Name = "Chair", Id = 7,
             Info = { Unit = { Dead = false }, Quest = { IsTiedToQuest = v } } }
end
oc2("numeric 0 must NOT read as a quest objective",
    (function()
        local o = tiedcase(0)
        local tied = o.Info.Quest.IsTiedToQuest
        return not (tied and tied ~= 0)
    end)())
oc2("boolean false is still not an objective",
    (function()
        local o = tiedcase(false)
        local tied = o.Info.Quest.IsTiedToQuest
        return not (tied and tied ~= 0)
    end)())
oc2("a real objective is still recognised",
    (function()
        local o = tiedcase(true)
        local tied = o.Info.Quest.IsTiedToQuest
        return (tied and tied ~= 0) and true or false
    end)())
oc2("a non-zero number is an objective too",
    (function()
        local o = tiedcase(1)
        local tied = o.Info.Quest.IsTiedToQuest
        return (tied and tied ~= 0) and true or false
    end)())

''' + anchor
s = s.replace(anchor, BLOCK, 1)
p.write_text(s, encoding="utf-8")
print("tests: numeric-0 IsTiedToQuest cases added")
