from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestOM.lua")
s = p.read_text(encoding="utf-8")

# ---- replace the statistical verdict with a proof-based one ----------------
i = s.index("-- Three-valued: yes it works, no it is dead, unknown while we have too little")
j = s.index("local function status_sets()")
NEW = '''-- IS THE STATUS SENSOR ALIVE? THREE-VALUED, AND PROOF BEATS STATISTICS.
--
-- The first version answered "dead" after 400 all-zero queries. That conflates
-- two very different worlds: a broken sensor, and a perfectly good sensor in an
-- area that genuinely has no quest givers. A bigger threshold is a bigger
-- number, not better evidence - and it was wrong enough to make three quest-
-- engine tests fail by sending the bot off to greet npcs instead of killing the
-- wolf it was sent to kill.
--
-- There is a proof available. When a quest frame OPENS for an npc, that npc is
-- definitively a quest giver - the client said so, no runtime read involved. If
-- the sensor reported nothing for that same npc, it is broken, and one such
-- observation settles it forever. No sample size, no false accusation.
--
-- witnessed_dead is therefore the primary signal. The counters remain only as a
-- weak secondary hint for the search path, which probes deliberately and can
-- afford to be wrong (its worst case is walking to an npc and saying hello).
QuestOM._witnessed_dead = false

-- Called from QuestFrame when a quest dialog opens: we KNOW this one is a giver.
function QuestOM.witness_giver(guid)
    if not guid then return end
    if QuestOM._witnessed_dead then return end
    local st = QuestOM.giver_status(guid)
    if st and st ~= 0 then
        -- sensor saw it too: it works, and that outranks any accumulated doubt
        QuestOM._status_nonzero = QuestOM._status_nonzero + 1
        return
    end
    QuestOM._witnessed_dead = true
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel and Tel.warn then
        Tel.warn("quest", "giver_sensor_dead",
            { note = "a quest frame opened for an npc the status call reports as 0" })
    end
end

-- Deliberate probe of the npcs actually in front of us. Only the SEARCH path
-- calls this, because only the search path has earned the right to conclude
-- anything from a run of zeros: it is looking for a giver and finding none.
QuestOM.PROBE_ROUNDS = 6          -- consecutive all-zero sweeps before we accept it

function QuestOM.probe_sensor()
    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not (om and om.npcs) then return end
    local seen, hit = 0, 0
    for i = 1, #om.npcs do
        local g = om.npcs[i] and om.npcs[i].Guid
        if g then
            seen = seen + 1
            local st = QuestOM.giver_status(g)
            if st and st ~= 0 then hit = hit + 1 end
        end
    end
    if seen == 0 then return end          -- nothing to learn from an empty list
    if hit > 0 then
        QuestOM._probe_rounds = 0
        return
    end
    QuestOM._probe_rounds = (QuestOM._probe_rounds or 0) + 1
end

function QuestOM.status_source_alive()
    if QuestOM._status_nonzero > 0 then return true end     -- it answered once: it works
    if QuestOM._witnessed_dead then return false end        -- proven against a real giver
    if (QuestOM._probe_rounds or 0) >= QuestOM.PROBE_ROUNDS then return false end
    return nil                                              -- not enough to say
end

local function status_sets()'''
s = s[:i] + NEW + s[j + len("local function status_sets()"):]
p.write_text(s, encoding="utf-8")
print("QuestOM: proof-based sensor verdict")

# ---- QuestFrame reports the proof -----------------------------------------
q = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestFrame.lua")
t = q.read_text(encoding="utf-8")
A = "    local nm = (UnitName and UnitName(\"npc\")) or (GetUnitName and GetUnitName(\"npc\")) or \"quest npc\""
N = """    -- An open quest frame PROVES this npc is a giver. Tell QuestOM, so that if
    -- the status sensor reported nothing for it we learn the sensor is broken
    -- from one observation instead of guessing from a run of zeros.
    local OM = RaijinLab.QuestOM
    if OM and OM.witness_giver and UnitGUID then
        pcall(OM.witness_giver, UnitGUID("npc"))
    end
""" + A
if "witness_giver" not in t:
    assert A in t, "remember_giver body not found"
    t = t.replace(A, N, 1)
    q.write_text(t, encoding="utf-8")
    print("QuestFrame: reports the proof")
else:
    print("QuestFrame: already wired")

# ---- the Suite search path probes deliberately ----------------------------
r = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\Suite.lua")
u = r.read_text(encoding="utf-8")
A2 = "        if (kind == \"giver\" or kind == \"turnin\") and RaijinLab.QuestOM.candidate_giver then"
N2 = """        -- Probe here and only here: this is the state that has actually failed
        -- to find a giver, so a run of zeros means something. Elsewhere it would
        -- just be an area without quest givers, which is not a defect.
        if (kind == "giver" or kind == "turnin") and RaijinLab.QuestOM.probe_sensor then
            pcall(RaijinLab.QuestOM.probe_sensor)
        end
""" + A2
if "probe_sensor" not in u:
    assert A2 in u, "suite fallback not found"
    u = u.replace(A2, N2, 1)
    r.write_text(u, encoding="utf-8")
    print("Suite: probes the sensor only while searching")
else:
    print("Suite: already wired")
