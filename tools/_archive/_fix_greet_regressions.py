"""Fix the four regressions the reviewers found in the greet / memory work."""
from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\Suite.lua")
s = p.read_text(encoding="utf-8")

# ---- 1. HIGH: a quest-less gossip window is a NEGATIVE, not a verdict ------
OLD1 = """local function greet_frame_open()
    return frame_shown(QuestFrameGreetingPanel) or frame_shown(GossipFrame)
        or frame_shown(QuestFrame)
end"""
NEW1 = """-- Did a QUEST dialog open? Three-valued on purpose.
--
-- Counting any shown GossipFrame as proof caused a livelock: an innkeeper or a
-- guard opens a gossip window with no quest options, QF.on_gossip returns nil, so
-- Suite.tick never takes its `if fr then` branch, the pending greet is cleared as
-- "answered", and the same npc is greeted again next tick. Forty interacts on one
-- guard, forever - the reviewer reproduced exactly that.
--
-- A quest-less gossip is not "wait longer", it is a definite NO: we asked, and
-- this npc has nothing. Rule it out at once rather than timing out.
--   "yes"     - a real quest dialog
--   "no"      - a gossip window that demonstrably carries no quests
--   nil       - nothing open yet; keep waiting
local function greet_frame_verdict()
    if frame_shown(QuestFrameDetailPanel) or frame_shown(QuestFrameProgressPanel)
        or frame_shown(QuestFrameRewardPanel) or frame_shown(QuestFrameGreetingPanel)
        or frame_shown(QuestFrame) then
        return "yes"
    end
    if frame_shown(GossipFrame) then
        local na = (GetNumGossipActiveQuests and GetNumGossipActiveQuests()) or 0
        local nv = (GetNumGossipAvailableQuests and GetNumGossipAvailableQuests()) or 0
        if (tonumber(na) or 0) + (tonumber(nv) or 0) > 0 then return "yes" end
        return "no"          -- it answered, and the answer is "nothing here"
    end
    return nil
end

local function greet_frame_open()
    return greet_frame_verdict() == "yes"
end"""
assert OLD1 in s, "greet_frame_open not found"
s = s.replace(OLD1, NEW1, 1)

# make greet_pending act on the negative immediately
import re
m = re.search(r"local function greet_pending\(\).*?\nend\n", s, re.S)
assert m, "greet_pending not found"
body = m.group(0)
new_body = """local function greet_pending()
    local g = Suite._greet_pending
    if not g then return nil end
    local v = greet_frame_verdict()
    if v == "yes" then
        Suite._greet_pending = nil
        return nil                          -- answered: the dialog drives from here
    end
    if v == "no" then
        -- Definite negative. Do not wait out the timer: this npc answered and has
        -- nothing, so retrying it is pure waste and closing the window frees the
        -- engine to move on.
        Suite._greet_pending = nil
        if RaijinLab.QuestOM and RaijinLab.QuestOM.rule_out then
            RaijinLab.QuestOM.rule_out(g.guid, "gossip_no_quests")
        end
        if CloseGossip then pcall(CloseGossip) end
        return nil
    end
    if (now() - (g.t or 0)) < (Suite.GREET_VERDICT_SECS or 6.0) then
        return g.name                       -- still waiting for an answer
    end
    -- Timed out with nothing shown at all: treat as no, but say why separately so
    -- the two causes stay distinguishable in the log.
    Suite._greet_pending = nil
    if RaijinLab.QuestOM and RaijinLab.QuestOM.rule_out then
        RaijinLab.QuestOM.rule_out(g.guid, "no_frame_timeout")
    end
    return nil
end
"""
s = s.replace(body, new_body, 1)

# ---- 2. HIGH: the identity passed was the QUEST TITLE, not the npc name ----
OLD2 = """        if name then mem = QOM.remembered_giver(want, { name = name }) end
        if not mem then mem = QOM.remembered_giver(want) end"""
NEW2 = """        -- IDENTITY, NOT TITLE. This passed `name`, which at the turn-in call site
        -- is the QUEST TITLE, while turn-in POIs are keyed on the NPC name
        -- (QuestFrame records UnitName("npc")). A title never equals an npc name,
        -- so the filtered lookup always missed and the unfiltered one always won -
        -- leaving the "nearest turn-in of any quest" bug exactly as it was.
        --
        -- The quest id is the join that actually exists: POI.record/POI.nearest
        -- both support it. Prefer that, then an npc-name match, then anything.
        local qid = q and (q.questId or q.questID or q.id)
        if qid then mem = QOM.remembered_giver(want, { quest = qid }) end
        if not mem and name then mem = QOM.remembered_giver(want, { name = name }) end
        if not mem then mem = QOM.remembered_giver(want) end"""
assert OLD2 in s, "remembered_giver call not found"
s = s.replace(OLD2, NEW2, 1)
p.write_text(s, encoding="utf-8")
print("Suite: gossip-negative verdict + quest-id identity")

# ---- 3. record the quest id when learning a turn-in POI -------------------
q = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestFrame.lua")
t = q.read_text(encoding="utf-8")
OLD3 = '    pcall(P.record, kind, { x = x, y = y, z = z, name = nm })'
NEW3 = ("""    -- Record the quest id too: without it the only join between "which quest"
    -- and "where do I hand it in" is the npc name, which the caller does not
    -- know at lookup time. POI.nearest already filters on `quest`.
    local qid = nil
    if GetQuestID then local ok, v = pcall(GetQuestID); qid = ok and v or nil end
    if (not qid or qid == 0) and RaijinLab.QuestLog and RaijinLab.QuestLog.selected_id then
        local ok, v = pcall(RaijinLab.QuestLog.selected_id); qid = ok and v or qid
    end
    pcall(P.record, kind, { x = x, y = y, z = z, name = nm, quest = qid })""")
if OLD3 in t:
    t = t.replace(OLD3, NEW3, 1)
    q.write_text(t, encoding="utf-8")
    print("QuestFrame: turn-in POIs now carry the quest id")
else:
    print("QuestFrame: record call shape changed - SKIPPED, needs manual check")
