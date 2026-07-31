from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestFrame.lua")
s = p.read_text(encoding="utf-8")

HELPER = '''-- WHERE GIVER MEMORY ACTUALLY COMES FROM.
--
-- QuestOM.observe() was the only writer of the "giver"/"turnin" POI kinds, and
-- it records what nearest_giver() found - which is nothing, because the runtime
-- command behind it is a `return 0` stub. So the remembered-giver fallback was
-- structurally empty: a memory that could only be filled by the sensor it was
-- supposed to compensate for.
--
-- An open quest dialog is PROOF. Whatever we are talking to is a quest giver,
-- the client says so by showing the frame, and no runtime read is involved. It
-- costs nothing to record here, and it is the one signal that cannot lie.
--
-- Recorded on accept AND on turn-in because the two are frequently different
-- npcs, and the turn-in location is the one the bot has to travel back to.
local function remember_giver(kind)
    local R = RaijinLab
    local P = R and R.POI
    if not (P and P.record and R.ObjectPosition) then return end
    local x, y, z = R:ObjectPosition("player")
    if not x then return end
    -- The player's own position, not the npc's: we are standing in interact
    -- range, which is close enough to navigate back to, and it needs no object
    -- lookup that could itself be stubbed out.
    local nm = (UnitName and UnitName("npc")) or (GetUnitName and GetUnitName("npc")) or "quest npc"
    pcall(P.record, kind, { x = x, y = y, z = z, name = nm })
    local Tel = R.Telemetry
    if Tel and Tel.every then
        Tel.every("quest:giver_poi", 10, "quest", 3, "learned_giver",
            { kind = kind, name = tostring(nm) })
    end
end

'''

ANCHOR = "function QF.on_quest_detail()"
assert ANCHOR in s
s = s.replace(ANCHOR, HELPER + ANCHOR, 1)

# accept path
OLD_A = '''    if CompleteQuest then CompleteQuest() end
        return "complete"'''
# (guarded below - do the two precise edits instead)

# 1. on_quest_detail: accepting a quest proves this npc is a giver
import re as _re
m = _re.search(r"function QF\.on_quest_detail\(\).*?\nend", s, _re.S)
assert m, "on_quest_detail not found"
blk = m.group(0)
if "AcceptQuest" in blk:
    nb = blk.replace("if AcceptQuest then AcceptQuest() end",
                     'if AcceptQuest then AcceptQuest() end\n    remember_giver("giver")', 1)
    assert nb != blk, "AcceptQuest call site not matched"
    s = s.replace(blk, nb, 1)

# 2. on_quest_complete: claiming a reward proves this npc is a turn-in
m2 = _re.search(r"function QF\.on_quest_complete\(\).*?\nend", s, _re.S)
assert m2, "on_quest_complete not found"
blk2 = m2.group(0)
if "GetQuestReward" in blk2:
    nb2 = _re.sub(r"(\n(\s*)if GetQuestReward then GetQuestReward\([^\n]*\n)",
                  r"\1\2remember_giver(\"turnin\")\n", blk2, count=1)
    assert nb2 != blk2, "GetQuestReward call site not matched"
    s = s.replace(blk2, nb2, 1)

p.write_text(s, encoding="utf-8")
print("QuestFrame: quest dialogs now seed giver/turnin POI memory")
