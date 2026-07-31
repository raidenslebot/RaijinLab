"""Kill the 0-is-truthy defect at its source.

ObjectIsQuestObjective is a hardcoded `return PushNumber(L, 0)` stub in the
runtime. 0 is TRUTHY in Lua, so IsTiedToQuest became "true" for every object in
the world, and that one fact produced both halves of the user's complaint:

  * list_objectives matched EVERY npc and gameobject, so nearest_objective
    returned whatever was physically closest - a mailbox, a chair, a guard - and
    the engine walked to it and interacted. That is "runs into buildings and
    objects with no idea what is happening".
  * candidate_giver's "an objective is never the giver" filter rejected every
    npc, so the greet fallback could never open no matter what its gate said.

Fixed at the boundary (the API wrapper) so no consumer has to know the bridge
answers 0-for-unknown, plus the two consumers that read the raw field.
"""
from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- 1. the wrapper must treat 0 as NO ANSWER, not as yes ------------------
a = R / "addon/core/API.lua"
s = a.read_text(encoding="utf-8")
OLD = """        local res = RLCall('ObjectIsQuestObjective', object, unknown)
        local type = RaijinLab:ObjectIsQuestObjectType(object)
        if not res and type then
            res = RaijinLab:GameObjectIsQuestObjective(object, type)
        end
        if not res or RaijinLab:ObjectIsUnit(object) then
            local result = RaijinLab:ScanToolTipForQuestInfo(guid, id)
            if not res then res = result end
        end"""
NEW = """        -- THE BRIDGE ANSWERS 0 FOR "I DO NOT KNOW", AND 0 IS TRUTHY IN LUA.
        --
        -- ObjectIsQuestObjective is a hardcoded `return PushNumber(L, 0)` stub in
        -- the runtime. Every `not res` test below was therefore FALSE for every
        -- object: the GameObject fallback was skipped, the tooltip scan ran and
        -- its answer was thrown away, and this returned 0 - which every consumer
        -- then read as "yes, this is a quest objective".
        --
        -- Consequences, both observed live: list_objectives matched every npc and
        -- gameobject in range so the engine walked to whatever was nearest (a
        -- chair, a mailbox, a guard), and the quest-giver candidate filter
        -- rejected every npc because it thought they were all objectives.
        --
        -- Normalise here, at the boundary, so no consumer has to know the bridge
        -- lies. `res` leaves this function as a real boolean or nil - never 0.
        local raw = RLCall('ObjectIsQuestObjective', object, unknown)
        local res = nil
        if type(raw) == "boolean" then
            res = raw
        elseif tonumber(raw) then
            local n = tonumber(raw)
            -- 0 from a stub is UNKNOWN, not "no". Leave res nil so the real
            -- fallbacks below get their turn.
            if n ~= 0 then res = true end
        end
        local otype = RaijinLab:ObjectIsQuestObjectType(object)
        if res == nil and otype then
            local g = RaijinLab:GameObjectIsQuestObjective(object, otype)
            if g ~= nil and g ~= 0 then res = (g and true or false) end
        end
        if res == nil or RaijinLab:ObjectIsUnit(object) then
            local result = RaijinLab:ScanToolTipForQuestInfo(guid, id)
            if res == nil and result ~= nil then
                res = (result and result ~= 0) and true or false
            end
        end
        if res == nil then res = false end   -- no source could tell: not an objective"""
assert OLD in s, "ObjectIsQuestObjective body not found"
s = s.replace(OLD, NEW, 1)
a.write_text(s, encoding="utf-8")
print("API.lua: 0 is unknown; tooltip fallback no longer discarded")

# ---- 2. the OM must store a boolean, not whatever the bridge returned ------
m = R / "addon/core/objects/Manager.lua"
t = m.read_text(encoding="utf-8")
n = t.count("IsTiedToQuest = RaijinLab:ObjectIsQuestObjective(")
t = t.replace("IsTiedToQuest = RaijinLab:ObjectIsQuestObjective(",
              "IsTiedToQuest = _tied(RaijinLab:ObjectIsQuestObjective(")
# close the extra paren on those lines
import re
t = re.sub(r"(IsTiedToQuest = _tied\(RaijinLab:ObjectIsQuestObjective\([^\n]*?)\)(\s*(?:,|\n))",
           r"\1))\2", t)
HELPER = """-- Belt and braces: whatever the bridge or wrapper returns, what LANDS in the
-- object struct is a real boolean. A numeric 0 here reads as true in Lua and
-- silently turned every object in the world into a quest objective.
local function _tied(v)
    if v == nil or v == false then return false end
    local n = tonumber(v)
    if n then return n ~= 0 end
    return true
end

"""
if "_tied" in t and "local function _tied" not in t:
    # place the helper before first use
    i = t.index("IsTiedToQuest = _tied(")
    j = t.rfind("\n", 0, t.rfind("\n", 0, i))
    # insert near the top instead: after the first line
    first_nl = t.index("\n") + 1
    t = t[:first_nl] + HELPER + t[first_nl:]
m.write_text(t, encoding="utf-8")
print(f"Manager.lua: normalised {n} IsTiedToQuest assignment(s) to booleans")

# ---- 3. consumers that read the raw field ---------------------------------
q = R / "addon/modules/questing/QuestOM.lua"
u = q.read_text(encoding="utf-8")
u = u.replace(
    "        if ok and s.Info and s.Info.Quest and s.Info.Quest.IsTiedToQuest then ok = false end",
    "        -- tied may still arrive as a number from an older cached struct; a\n"
    "        -- numeric 0 must not read as \"this is an objective\".\n"
    "        local tied = s.Info and s.Info.Quest and s.Info.Quest.IsTiedToQuest\n"
    "        if ok and tied and tied ~= 0 then ok = false end", 1)
q.write_text(u, encoding="utf-8")
print("QuestOM.lua: candidate filter no longer rejects every npc")
