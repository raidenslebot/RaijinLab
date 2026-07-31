from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

ANCHOR = """    t = lua.eval("qom_fails")
    n = int(lua.eval("#qom_fails"))"""
assert ANCHOR in s, "questom tail not found"

BLOCK = '''    lua.execute(
        r"""
-- ---- THE STUBBED QUEST-GIVER SENSOR --------------------------------------
-- ObjectQuestGiverStatus is `return PushNumber(L, 0)` in the runtime for every
-- object. 0 is truthy in Lua, so the old `if st and set[st]` passed its first
-- test and then missed, forever, for every npc in the world. These pin the two
-- halves of the fix: 0 is not an answer, and an unbroken run of zeros is
-- eventually reported as a dead sensor rather than an empty world.
QuestOM._status_asked, QuestOM._status_nonzero = 0, 0

RaijinLab.ObjectQuestGiverStatus = function() return 0 end
oc("giver_status: stub 0 is not an answer", QuestOM.giver_status("x") == nil)

-- too little evidence is UNKNOWN, not an accusation: a character standing in an
-- empty field legitimately sees a long run of zeros
oc("status_source_alive: unknown before the sample fills",
   QuestOM.status_source_alive() == nil)

for _ = 1, QuestOM.STATUS_SAMPLE do QuestOM.giver_status("x") end
oc("status_source_alive: all-zero over the full sample = DEAD",
   QuestOM.status_source_alive() == false)

-- a single real answer proves the sensor works and must clear the accusation
QuestOM._status_asked, QuestOM._status_nonzero = 0, 0
RaijinLab.ObjectQuestGiverStatus = function() return 6 end
oc("giver_status: a real status passes through", QuestOM.giver_status("x") == 6)
oc("status_source_alive: one non-zero answer = ALIVE",
   QuestOM.status_source_alive() == true)

-- a missing or throwing api is cannot-tell, never a status
RaijinLab.ObjectQuestGiverStatus = nil
oc("giver_status: missing api -> nil", QuestOM.giver_status("x") == nil)
RaijinLab.ObjectQuestGiverStatus = function() error("boom") end
oc("giver_status: throwing api -> nil", QuestOM.giver_status("x") == nil)
"""
    )

''' + ANCHOR

s = s.replace(ANCHOR, BLOCK, 1)
p.write_text(s, encoding="utf-8")
print("questom: stub-sensor tests added")
