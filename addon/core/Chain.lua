-- Chain - walk the whole questing pipeline and name the FIRST broken link.
--
-- WHY THIS EXISTS. Every failure in this project has looked identical from the
-- outside: the character stands still, or jogs somewhere pointless. "It has no
-- idea where anything is" is a true description of a dozen different faults, and
-- telling them apart has repeatedly cost days - because each layer only reports
-- its own verdict, and a layer that is starved reports exactly what a layer that
-- is broken reports.
--
-- The chain is strictly ordered: each link needs the one above it. So the FIRST
-- broken link is the only one worth acting on, and everything below it is noise.
-- Reporting them in order, and stopping at the first hard failure, turns "the
-- bot is stupid" into "link 4 of 9, here is the value it returned".
--
-- Every check is read-only and pcall'd. This must never be the thing that breaks
-- a session it was written to diagnose.

local Chain = {}
RaijinLab.Chain = Chain

-- A link: name, why it matters, and run() -> ok, detail
--   ok == true   healthy, keep going
--   ok == false  BROKEN - the first of these is the answer
--   ok == nil    cannot tell (precondition absent); reported, not blamed
Chain.LINKS = {
    {
        name = "runtime",
        why = "the injected DLL answers; without it nothing below can work",
        run = function()
            if not (RaijinLab.HasRuntime and RaijinLab:HasRuntime()) then
                return false, "no bridge - inject the DLL, then /reload"
            end
            local v = RaijinLab.RuntimeVersion and RaijinLab:RuntimeVersion()
            return true, tostring(v or "connected")
        end,
    },
    {
        name = "om_enabled",
        why = "object enumeration is gated by om.enable; off means an empty world",
        run = function()
            local armed = RaijinLab._runtime_armed and true or false
            local frame = (RaijinLab.GetObjManagerFrame
                and RaijinLab:GetObjManagerFrame()) and true or false
            if not armed then return false, "ArmRuntimeSystems never ran (not in world?)" end
            if not frame then return false, "object manager OnUpdate not started" end
            return true, "armed, ticking"
        end,
    },
    {
        name = "bridge_units",
        why = "the DLL's own enumeration; the upper bound on what we can see",
        run = function()
            local n = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("GetUnitCount")
            n = tonumber(n)
            if n == nil then return false, "GetUnitCount unhandled (nil)" end
            if n == 0 then return nil, "0 units - genuinely empty area, or om.enable off" end
            return true, tostring(n) .. " units"
        end,
    },
    {
        name = "engine_snapshot",
        why = "what the ENGINE holds. Empty here while the bridge sees units is "
           .. "the classic blindness: classification or publishing failed",
        run = function()
            local L = RaijinLab.om and RaijinLab.om.object_list
            if not L then return false, "om.object_list missing" end
            local npcs = L.npcs and #L.npcs or -1
            local raw = L.raw and L.raw.npcs and #L.raw.npcs or -1
            if npcs == -1 then return false, "object_list.npcs does not exist" end
            if raw > 0 and npcs == 0 then
                return false, "raw=" .. raw .. " but npcs=0 - ObjectProcessor never published"
            end
            if npcs == 0 then return nil, "snapshot empty (see bridge_units above)" end
            return true, tostring(npcs) .. " npcs, raw " .. tostring(raw)
        end,
    },
    {
        name = "quest_log",
        why = "the objective's NAME comes from here; it is our most reliable source",
        run = function()
            local QL = RaijinLab.QuestLog
            if not (QL and QL.first_incomplete_objective) then
                return false, "QuestLog module missing"
            end
            local q, o = QL.first_incomplete_objective({})
            if not q then return nil, "no incomplete quests in the log" end
            return true, string.format("%s -> %s", tostring(q.title or q.questId),
                tostring(o and (o.name or o.text) or "?"))
        end,
    },
    {
        name = "questdb",
        why = "RaijinQuest supplies spawn coordinates for things we cannot see",
        run = function()
            local QDB = RaijinLab.QuestDB
            if not QDB then return false, "QuestDB module missing" end
            if not QDB.available() then
                return false, "RaijinQuest database not loaded (check the TOC entries)"
            end
            return true, "database loaded"
        end,
    },
    {
        name = "zone_calibration",
        why = "database coords are zone PERCENTAGES; without a solved transform "
           .. "they cannot become world coordinates and every lookup returns nil",
        run = function()
            local QDB = RaijinLab.QuestDB
            if not QDB then return nil, "no QuestDB" end
            -- database zone id, the one spawns are actually keyed by
            local map = QDB.current_zone and QDB.current_zone()
            if not map then return nil, "zone id unresolved" end
            -- WHAT MATTERS IS WHETHER COORDINATES CONVERT, not which mechanism
            -- did it. This used to report the FITTED transform's state and said
            -- "NOT solved - walk a little" while the exact dbc rectangle was
            -- already converting the player's own position to the yard. A
            -- diagnostic that names the wrong blocker sends every reader after
            -- the wrong bug.
            if QDB.dbc_matches_zone and QDB.dbc_matches_zone(map) then
                return true, string.format("map %s exact (WorldMapArea dbc)", tostring(map))
            end
            local c = QDB._cal and QDB._cal[map]
            if c and c.t_solved then
                return true, string.format("map %s fitted, err %.1fyd",
                    tostring(map), c.err or 0)
            end
            -- Prove it end to end rather than trusting either flag: convert the
            -- player's own map position and see whether it lands on the player.
            if GetPlayerMapPosition and QDB.to_world and RL().ObjectPosition then
                local ok, mx, my = pcall(GetPlayerMapPosition, "player")
                local px, py = RL():ObjectPosition("player")
                if ok and mx and px then
                    local okw, wx, wy = pcall(QDB.to_world, map, mx, my)
                    if okw and wx then
                        local e = math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2)
                        if e <= 12 then
                            return true, string.format("map %s converts, err %.1fyd",
                                tostring(map), e)
                        end
                        return false, string.format(
                            "map %s converts but is %.0fyd WRONG", tostring(map), e)
                    end
                end
            end
            return false, string.format("map %s cannot convert coordinates - "
                .. "no dbc rectangle and no fitted transform", tostring(map))
        end,
    },
    {
        name = "target_known",
        why = "the actual question: do we know where the current objective is?",
        run = function()
            local QL = RaijinLab.QuestLog
            local S = RaijinLab.QuestSuite
            if not (QL and S and S.known_target) then return nil, "suite not loaded" end
            local q, o = QL.first_incomplete_objective({})
            local name = o and (o.name or o.text)
            if not name then return nil, "no objective name to look up" end
            local px, py = RaijinLab.ObjectPosition
                and RaijinLab:ObjectPosition("player")
            if not px then return nil, "no player position" end
            local x, y = S.known_target(name, px, py)
            if not x then
                return nil, string.format("'%s' not in the database - the belief "
                    .. "field will be used (this is correct, not a fault)", tostring(name))
            end
            local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
            return true, string.format("'%s' at (%.0f,%.0f), %.0fyd", tostring(name), x, y, d)
        end,
    },
    {
        name = "navigator",
        why = "and can we actually steer there",
        run = function()
            local N = RaijinLab.Navigator
            if not N then return false, "Navigator missing" end
            if N._last_err then
                return false, "navigation stopped by an error: " .. tostring(N._last_err)
            end
            return true, "state " .. tostring(N.state or "idle")
        end,
    },
}

-- Returns rows plus the index of the first hard failure (nil when healthy).
function Chain.evaluate()
    local rows, first_bad = {}, nil
    for i, link in ipairs(Chain.LINKS) do
        local ok, detail
        local success, a, b = pcall(link.run)
        if not success then
            ok, detail = false, "check errored: " .. tostring(a)
        else
            ok, detail = a, b
        end
        rows[#rows + 1] = { name = link.name, ok = ok, detail = detail, why = link.why }
        if ok == false and not first_bad then first_bad = i end
    end
    return rows, first_bad
end

return Chain
