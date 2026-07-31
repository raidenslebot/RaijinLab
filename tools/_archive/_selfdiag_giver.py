from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestOM.lua")
s = p.read_text(encoding="utf-8")

OLD = """    if seen == 0 then return end          -- nothing to learn from an empty list
    if hit > 0 then
        QuestOM._probe_rounds = 0
        return
    end
    QuestOM._probe_rounds = (QuestOM._probe_rounds or 0) + 1
end"""

NEW = """    if seen == 0 then
        -- An empty npc list is itself a finding: it means the object manager has
        -- nothing to offer and no amount of status-reading will help.
        QuestOM._diag_empty = (QuestOM._diag_empty or 0) + 1
        QuestOM._report_probe(0, 0, nil)
        return
    end
    QuestOM._report_probe(seen, hit, dist)
    if hit > 0 then
        QuestOM._probe_rounds = 0
        return
    end
    QuestOM._probe_rounds = (QuestOM._probe_rounds or 0) + 1
end

-- SELF-REPORTING, BECAUSE ASKING A HUMAN TO RUN A DIAGNOSTIC IS NOT A DIAGNOSTIC.
--
-- The engine sat in turnin:searching for hundreds of samples while nothing said
-- WHY: whether the npc list was empty, whether statuses came back zero, or
-- whether they came back non-zero but matched none of the configured code sets.
-- Those three have completely different fixes and were indistinguishable from
-- the log, so every diagnosis needed a human to run /raijin quest givers.
--
-- Now the search path prints the actual distribution on a slow cadence. One log
-- line separates "the runtime is blind", "the OM is empty" and "the codes are
-- wrong" - which are the only three things this can be.
function QuestOM._report_probe(seen, hit, dist)
    local DL = RaijinLab and RaijinLab.DevLog
    if not (DL and DL.log_every) then return end
    local parts = {}
    if dist then
        for st, n in pairs(dist) do parts[#parts + 1] = tostring(st) .. "x" .. tostring(n) end
        table.sort(parts)
    end
    local avail, comp = status_sets()
    local aset, cset = {}, {}
    for k in pairs(avail) do aset[#aset + 1] = tostring(k) end
    for k in pairs(comp) do cset[#cset + 1] = tostring(k) end
    table.sort(aset); table.sort(cset)
    DL.log_every("qg_probe", 5.0, "quest",
        "giver-probe npcs=%d nonzero=%d statuses={%s} want_avail={%s} want_complete={%s} verdict=%s",
        seen or 0, hit or 0,
        table.concat(parts, ","),
        table.concat(aset, ","), table.concat(cset, ","),
        tostring(QuestOM.status_source_alive()))
end"""
assert OLD in s, "probe_sensor tail not found"
s = s.replace(OLD, NEW, 1)

# collect the distribution while probing
OLD2 = """    local seen, hit = 0, 0
    for i = 1, #om.npcs do
        local g = om.npcs[i] and om.npcs[i].Guid
        if g then
            seen = seen + 1
            local st = QuestOM.giver_status(g)
            if st and st ~= 0 then hit = hit + 1 end
        end
    end"""
NEW2 = """    local seen, hit = 0, 0
    local dist = {}
    for i = 1, #om.npcs do
        local g = om.npcs[i] and om.npcs[i].Guid
        if g then
            seen = seen + 1
            -- raw value, NOT giver_status(): we need to see the 0s too, because
            -- "all zero" and "non-zero but unmatched" are different defects
            local raw = 0
            if RaijinLab.ObjectQuestGiverStatus then
                local ok, v = pcall(RaijinLab.ObjectQuestGiverStatus, RaijinLab, g)
                raw = (ok and tonumber(v)) or 0
            end
            dist[raw] = (dist[raw] or 0) + 1
            local st = QuestOM.giver_status(g)
            if st and st ~= 0 then hit = hit + 1 end
        end
    end"""
assert OLD2 in s, "probe loop not found"
s = s.replace(OLD2, NEW2, 1)
p.write_text(s, encoding="utf-8")
print("QuestOM: search path now logs the real status distribution")
