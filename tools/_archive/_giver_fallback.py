from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestOM.lua")
s = p.read_text(encoding="utf-8")

OLD = """    consider(om.gameobjects)
    if best then
        return { struct = best, name = best.Name, id = best.Id, guid = best.Guid, dist = bestd }
    end
    return nil
end"""

NEW = """    consider(om.gameobjects)
    if best then
        return { struct = best, name = best.Name, id = best.Id, guid = best.Guid, dist = bestd }
    end

    -- FALLBACK: THE STATUS SENSOR IS DEAD, SO ASK THE NPC DIRECTLY.
    --
    -- ObjectQuestGiverStatus is `return PushNumber(L, 0)` in the runtime for
    -- every object, so the loop above can never match and this function returned
    -- nil forever. Observed live: the bot held a COMPLETED quest ("Rude
    -- Awakening"), entered turnin:searching, and swept belief-field legs across
    -- the zone hunting a turn-in npc it is structurally blind to - which reads as
    -- "it just ran off into the woods in a random direction". Meanwhile quest
    -- givers stood next to it unaccepted, and world memory stayed at poi=1
    -- because observe() only records what THIS function finds.
    --
    -- Detecting the dead sensor is not enough; questing has to work anyway. The
    -- client itself is the authority we still have: open a dialog and it tells
    -- us definitively. So when the sensor is provably dead, nominate the nearest
    -- npc we have not already ruled out and let the dialog adjudicate.
    -- QuestFrame records a giver/turnin POI the moment a quest frame opens, so
    -- every success permanently seeds the memory this fallback exists to
    -- bootstrap - it gets cheaper the longer it runs.
    --
    -- Guarded by status_source_alive() == false specifically: while the sensor
    -- works, or while we cannot yet tell, we must NOT go poking every npc in
    -- sight. false here is a measured verdict (400 queries, none non-zero), not
    -- an assumption.
    if QuestOM.status_source_alive() == false then
        return QuestOM.candidate_giver(px, py, pz)
    end
    return nil
end

-- NPCs we have interacted with that produced no quest frame. Without this the
-- fallback re-nominates the same closest npc forever and the bot stands in front
-- of one guard for the rest of the session.
QuestOM._ruled_out = {}
QuestOM.RULE_OUT_FOR = 900        -- secs; re-try eventually, quests do appear later
QuestOM.CANDIDATE_MAX = 60        -- yd; only npcs we could actually walk to and greet

local function _now()
    return (GetTime and GetTime()) or 0
end

function QuestOM.rule_out(guid, why)
    if not guid then return end
    QuestOM._ruled_out[tostring(guid)] = _now()
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.every then
        Tel.every("quest:ruleout", 10, "quest", 4, "ruled_out",
            { guid = tostring(guid), why = tostring(why or "no_quest") })
    end
end

function QuestOM.is_ruled_out(guid)
    local t = QuestOM._ruled_out[tostring(guid or "")]
    if not t then return false end
    if (_now() - t) > QuestOM.RULE_OUT_FOR then
        QuestOM._ruled_out[tostring(guid)] = nil
        return false
    end
    return true
end

-- Nearest living npc worth greeting. Deliberately NOT "nearest object": a
-- gameobject or a critter is not something a quest dialog can come from, and
-- walking to one burns the same time as walking to a real candidate.
function QuestOM.candidate_giver(px, py, pz)
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not (om and om.npcs) then return nil end
    if not px then px, py, pz = ppos() end
    if not px then return nil end
    local best, bestd = nil, math.huge
    for i = 1, #om.npcs do
        local s = om.npcs[i]
        local ok = s and s.Guid ~= nil
        -- A corpse hands out nothing.
        if ok and s.Info and s.Info.Unit and s.Info.Unit.Dead then ok = false end
        if ok and QuestOM.is_ruled_out(s.Guid) then ok = false end
        -- Something we can attack is not a quest giver; skip without a runtime
        -- call, since UnitCanAttack needs a unit token we do not have here.
        if ok and s.Info and s.Info.Unit and s.Info.Unit.Hostile then ok = false end
        if ok then
            local d = dist_of(s, px, py, pz) or math.huge
            if d < bestd and d <= QuestOM.CANDIDATE_MAX then best, bestd = s, d end
        end
    end
    if not best then return nil end
    return { struct = best, name = best.Name, id = best.Id, guid = best.Guid,
             dist = bestd, guessed = true }
end"""
assert OLD in s, "nearest_giver tail not found"
s = s.replace(OLD, NEW, 1)
p.write_text(s, encoding="utf-8")
print("QuestOM: interact-and-learn fallback when the status sensor is dead")
