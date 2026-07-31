from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestOM.lua")
s = p.read_text(encoding="utf-8")

OLD = """    local function consider(list)
        for i = 1, #(list or {}) do
            local s = list[i]
            if s and s.Object and RaijinLab.ObjectQuestGiverStatus then
                local st = RaijinLab:ObjectQuestGiverStatus(s.Object)
                if st and set[st] then
                    local d = dist_of(s, px, py, pz) or math.huge
                    if d < bestd then best, bestd = s, d end
                end
            end
        end
    end"""

NEW = """    -- THE SENSOR THIS WAS BUILT ON DOES NOT EXIST.
    --
    -- ObjectQuestGiverStatus is a hardcoded stub in the runtime: Dispatch.cpp
    -- groups it with ObjectDescriptor / ObjectField / GameObjectType /
    -- ObjectIsQuestObjective and does `return PushNumber(L, 0)`. There is no
    -- memory read behind it anywhere in runtime/src. Every object, always, 0.
    --
    -- The old guard here was `if s.Object and RaijinLab.ObjectQuestGiverStatus`,
    -- which tests that the LUA WRAPPER is defined - it always is - and then
    -- `if st and set[st]`. 0 is TRUTHY in Lua, so the first half passed and
    -- set[0] was nil for both {5,6} and {7,8}. The body was unreachable for every
    -- npc in the world. nearest_giver() returned nil forever, so no quest was
    -- ever accepted and no quest was ever handed in - silently, with the bot
    -- standing next to a lit-up "!" doing nothing.
    --
    -- Worse, this could not heal: observe() below is the ONLY writer of the
    -- "giver"/"turnin" POI kinds in the addon and it runs downstream of this
    -- function, so the remembered-giver fallback could never learn anything
    -- either. A dead sensor and an empty memory that depends on it.
    --
    -- 0 is therefore UNKNOWN here, not "not a quest giver". We cannot tell those
    -- apart from one call - but we can tell across many, which is what
    -- _note_status does: if every object we have ever asked about answered 0,
    -- the source is dead rather than the world being empty.
    local function consider(list)
        for i = 1, #(list or {}) do
            local s = list[i]
            if s and s.Object then
                local st = QuestOM.giver_status(s.Object)
                if st and st ~= 0 and set[st] then
                    local d = dist_of(s, px, py, pz) or math.huge
                    if d < bestd then best, bestd = s, d end
                end
            end
        end
    end"""
assert OLD in s, "consider() loop not found"
s = s.replace(OLD, NEW, 1)

# ---- the status wrapper + liveness accounting ------------------------------
ANCHOR = """local function status_sets()"""
ADD = """-- Every status query and every non-zero answer. If asked is high and nonzero is
-- zero, the sensor is not reporting "no quest givers here" - it is not reporting.
QuestOM._status_asked = 0
QuestOM._status_nonzero = 0

-- Wrapper so exactly one place decides what a status value means.
-- Returns nil for "cannot tell", never 0-as-an-answer.
function QuestOM.giver_status(obj)
    local f = RaijinLab and RaijinLab.ObjectQuestGiverStatus
    if not f then return nil end
    local ok, st = pcall(f, RaijinLab, obj)
    if not ok then return nil end
    QuestOM._status_asked = QuestOM._status_asked + 1
    if st and st ~= 0 then
        QuestOM._status_nonzero = QuestOM._status_nonzero + 1
        return st
    end
    return nil
end

-- Three-valued: yes it works, no it is dead, unknown while we have too little
-- evidence. SAMPLE is deliberately large - a character standing in an empty
-- field legitimately sees a long run of zeros, and accusing the runtime on that
-- basis would be the same mistake in the other direction.
QuestOM.STATUS_SAMPLE = 400

function QuestOM.status_source_alive()
    if QuestOM._status_nonzero > 0 then return true end
    if QuestOM._status_asked < QuestOM.STATUS_SAMPLE then return nil end
    return false
end

local function status_sets()"""
assert ANCHOR in s
s = s.replace(ANCHOR, ADD, 1)
p.write_text(s, encoding="utf-8")
print("QuestOM: giver_status wrapper + liveness accounting")

# ---- a contract that names the defect and the remedy -----------------------
c = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Contracts.lua")
t = c.read_text(encoding="utf-8")
CA = """    C._installed = true
    return true
end"""
CN = """    -- CAUGHT NOTHING FOR MANY SESSIONS: quest giver detection reads a runtime
    -- command that is a hardcoded `return 0` stub, so no quest could ever be
    -- accepted or handed in. Nothing anywhere counted the zeros, so it looked
    -- exactly like "no quest givers nearby" forever.
    Contract.invariant("quest_giver_detection_alive", {
        when = function()
            local Q = RL() and RL().QuestOM
            return master_on() and mods().quest and Q ~= nil
                   and Q.status_source_alive ~= nil
                   and Q.status_source_alive() == false
        end,
        require = function() return false end,   -- reaching `when` IS the failure
        within = 5,
        explain = function()
            local Q = RL().QuestOM
            return string.format(
                "quest-giver detection is DEAD: %d objects queried, not one " ..
                "returned a status. ObjectQuestGiverStatus is a stub in the " ..
                "runtime (Dispatch.cpp returns 0 for every object), so no quest " ..
                "can be accepted or turned in. Needs a real implementation in " ..
                "the DLL, or /raijin quest giver-scan to fall back to interacting",
                Q._status_asked or 0)
        end,
    })

    C._installed = true
    return true
end"""
assert CA in t
t = t.replace(CA, CN, 1)
c.write_text(t, encoding="utf-8")
print("Contracts: quest_giver_detection_alive")
