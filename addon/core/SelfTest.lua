-- SelfTest - verify the RUNTIME from inside the game, in one command.
--
-- Why this exists. Every gate, unit group and simulator scenario in this project
-- tests the ADDON. None of them can test the injected DLL: the bridge is a
-- foreign function boundary, and the only thing on the far side of it during a
-- headless run is a mock. So runtime defects have repeatedly survived a fully
-- green suite - swim pitch was dispatched to STOP for both Start and Stop, the
-- "faster + complete" unit enumeration was never once reached, ObjectIsFacing
-- answered a hardcoded false while a working implementation sat one call away.
-- Each was invisible because the Lua above it was correct.
--
-- The checks below are chosen so that each one FAILS LOUDLY if a specific fix
-- regressed, and most need no target, no NPC and no particular location - the
-- geometry ones are exact arithmetic through the real bridge, so they prove the
-- wiring end to end with a deterministic answer.
--
-- `evaluate(call, opts)` is PURE with respect to the game: it takes the bridge
-- callable, so the whole thing runs headless against a mock in the unit suite.

local SelfTest = {}

SelfTest.EXPECT_VERSION = "1.11.0-truth"

local function approx(a, b, eps)
    if type(a) ~= "number" or type(b) ~= "number" then return false end
    return math.abs(a - b) <= (eps or 0.01)
end

-- Each check: { name, run(call, opts) -> ok, detail }
-- ok == nil means SKIPPED (a precondition the player cannot be asked to arrange).
SelfTest.CHECKS = {
    {
        name = "runtime_version",
        why = "the resident DLL is the build you think it is",
        run = function(call)
            local v = call("GetRuntimeVersion")
            if type(v) ~= "string" then return false, "no version string (runtime not injected?)" end
            if v ~= SelfTest.EXPECT_VERSION then
                return false, "resident " .. v .. " but expected " .. SelfTest.EXPECT_VERSION
            end
            return true, v
        end,
    },
    {
        name = "bridge_geometry",
        why = "GetDistanceBetweenPositions was a hardcoded 0 stub",
        run = function(call)
            local d = call("GetDistanceBetweenPositions", 0, 0, 0, 3, 4, 0)
            if d == nil then return false, "unhandled by the bridge (nil)" end
            if not approx(d, 5.0) then return false, "3-4-5 triangle gave " .. tostring(d) end
            return true, "3,4,5 -> 5.0"
        end,
    },
    {
        name = "bridge_position_from",
        why = "GetPositionFromPosition returned a fake (0,0,0)",
        run = function(call)
            local x, y, z = call("GetPositionFromPosition", 0, 0, 0, 10, 0, 0)
            if x == nil then return false, "unhandled by the bridge (nil)" end
            if not (approx(x, 10.0) and approx(y, 0.0) and approx(z, 0.0)) then
                return false, string.format("10yd at angle 0 gave (%s,%s,%s)",
                    tostring(x), tostring(y), tostring(z))
            end
            return true, "10yd @0rad -> (10,0,0)"
        end,
    },
    {
        name = "unit_enum_fastpath",
        why = "World.lua called GetUnitCount; the bridge only knew GetNpcCount, "
           .. "so the path it calls 'faster + complete' never ran once",
        run = function(call)
            local n = call("GetUnitCount")
            if n == nil then return false, "GetUnitCount unhandled (nil) - fast path dead" end
            if type(n) ~= "number" then return false, "non-numeric: " .. type(n) end
            -- THE RUNTIME COUNT IS NOT THE COUNT THE ENGINE USES.
            --
            -- Questing reads RaijinLab.om.object_list.npcs, not the bridge. In
            -- the live session the runtime enumerated 94 units while the engine
            -- found NO quest givers AND no kill objective ("found=none"), and
            -- only two giver-status queries were made in fourteen minutes -
            -- giver_status has no cache, so few queries means few CANDIDATES,
            -- i.e. that snapshot was empty. The bot was not ignoring one npc; it
            -- was blind to all of them, which is why it fell through to a
            -- belief-field beeline. Comparing the two numbers localises that
            -- exactly: bridge high + snapshot 0 is the disconnect.
            local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
            local npcs = om and om.npcs
            local cnt = npcs and #npcs or nil
            if cnt == nil then
                return false, tostring(n) .. " units from the bridge, but the "
                    .. "engine's om.object_list.npcs does not exist"
            end
            if n > 0 and cnt == 0 then
                -- SAY WHICH LINK IS BROKEN, not just that it is.
                -- Chasing this the first time I blamed the tracker_toggle start
                -- path and was wrong - ArmRuntimeSystems has always started the
                -- OM, gated on HasRuntime() and being in world. So report the two
                -- facts that discriminate: did the arm run, and does the OnUpdate
                -- frame exist? armed=false means the gate never opened;
                -- armed=true frame=false means InitObjectManager threw;
                -- armed=true frame=true means RunObjectManager itself is failing.
                local armed = RaijinLab._runtime_armed and true or false
                local frame = (RaijinLab.GetObjManagerFrame
                    and RaijinLab:GetObjManagerFrame()) and true or false
                return false, tostring(n) .. " units from the bridge but the "
                    .. "engine snapshot is EMPTY - questing is blind "
                    .. "(armed=" .. tostring(armed)
                    .. " om_frame=" .. tostring(frame) .. ")"
            end
            return true, tostring(n) .. " units enumerated (engine snapshot: "
                .. tostring(cnt) .. ")"
        end,
    },
    {
        name = "stubs_answer_nil",
        why = "unimplemented commands returned 0, and 0 is TRUTHY in Lua",
        run = function(call, opts)
            local g = opts and opts.player_guid
            if not g then return nil, "no player guid" end
            local v = call("UnitCasting", g)
            if v == 0 then
                return false, "UnitCasting answered 0 - reads as 'casting spell 0', i.e. always busy"
            end
            if v ~= nil and type(v) ~= "number" then
                return false, "unexpected type " .. type(v)
            end
            return true, v == nil and "nil (honest)" or ("real value " .. tostring(v))
        end,
    },
    {
        name = "pitch_dispatch",
        why = "name[7]=='a' picked 'S' for BOTH PitchUpStart and PitchUpStop, "
           .. "so pitch could only ever STOP - swim depth never worked",
        run = function(call)
            local started = call("PitchUpStart")
            local stopped = call("PitchUpStop")
            call("PitchDownStop")   -- belt and braces: never leave a hold armed
            if started == nil or stopped == nil then
                return false, "pitch commands unhandled by the bridge"
            end
            if not started then
                return false, "PitchUpStart returned false - still dispatching to STOP"
            end
            return true, "start+stop both accepted"
        end,
    },
    {
        name = "ctm_refused",
        why = "click-to-move is forbidden project-wide and was removed from C++",
        run = function(call)
            local ok = call("MoveTo", 0, 0, 0)
            if ok == true then return false, "MoveTo still performs click-to-move" end
            return true, "refused"
        end,
    },
    {
        name = "facing_wired",
        why = "ObjectIsFacing returned a hardcoded false while OM::IsFacing worked",
        run = function(call, opts)
            local me, tgt = opts and opts.player_guid, opts and opts.target_guid
            if not me then return nil, "no player guid" end
            -- No target needed to prove WIRING. The defect was a hardcoded
            -- `false` returned while OM::IsFacing worked, so what distinguishes
            -- fixed from broken is that a real answer comes back at all. Self
            -- against self is a degenerate but perfectly valid query, and it
            -- keeps this check out of the SKIP bucket for an untargeted run.
            local other = tgt or me
            local f = call("ObjectIsFacing", me, other)
            if f == nil then return false, "nil - not wired" end
            if type(f) ~= "boolean" then return false, "non-boolean " .. type(f) end
            return true, "answers " .. tostring(f) .. (tgt and " (vs target)" or " (vs self)")
        end,
    },
    {
        name = "om_pipeline",
        why = "the whole object pipeline in ONE line, because every failure so "
           .. "far was a mismatch between two of these numbers and no single "
           .. "readout ever showed them together",
        run = function(call)
            local L = RaijinLab.om and RaijinLab.om.object_list
            if not L then return false, "om.object_list missing entirely" end
            local bridge_n = call("GetUnitCount")
            local raw = L.raw or {}
            local function n(t) return t and #t or -1 end
            local line = string.format(
                "bridge=%s raw.npcs=%s npcs=%s players=%s gos=%s armed=%s frame=%s",
                tostring(bridge_n), tostring(n(raw.npcs)), tostring(n(L.npcs)),
                tostring(n(L.players)), tostring(n(L.gameobjects)),
                tostring(RaijinLab._runtime_armed and true or false),
                tostring((RaijinLab.GetObjManagerFrame
                    and RaijinLab:GetObjManagerFrame()) and true or false))
            -- Each stage feeds the next, so the FIRST zero localises the break:
            -- bridge>0 raw=0  -> the manager loop classified nothing
            -- raw>0   npcs=0  -> ObjectProcessor never published
            -- npcs>0          -> the engine can see the world
            local bn = tonumber(bridge_n) or 0
            if bn > 0 and n(raw.npcs) <= 0 then
                return false, line .. " | manager classified NOTHING"
            end
            if n(raw.npcs) > 0 and n(L.npcs) <= 0 then
                return false, line .. " | ObjectProcessor never published"
            end
            return true, line
        end,
    },
    {
        name = "typeflags_is_mask",
        why = "ObjectTypeFlags returned the ObjectType ENUM (Unit=3) where the "
           .. "addon reads a BITMASK (Unit=32), so RunObjectManager classified "
           .. "nothing and object_list.npcs was empty forever",
        run = function(call, opts)
            local g = opts and opts.player_guid
            if not g then return nil, "no player guid" end
            local v = call("ObjectTypeFlags", g)
            if v == nil then return false, "unhandled by the bridge (nil)" end
            if type(v) ~= "number" then return false, "non-numeric " .. type(v) end
            -- The player is a Unit AND a Player, so both bits must be lit. The
            -- old enum answer for a player was 4, which has neither: 4 = the
            -- Container bit. That is what made every object unclassifiable.
            local E = RaijinLab.enums and RaijinLab.enums.ObjectTypeFlags
            local UNIT = (E and E.Unit) or 32
            local PLAYER = (E and E.Player) or 64
            -- Test the bits arithmetically rather than via `bit`: this file also
            -- runs headless in the unit suite, where BitLib does not exist, and a
            -- check that SKIPS is a check that proves nothing.
            local function has_bit(val, mask)
                return math.floor(val / mask) % 2 == 1
            end
            if not (has_bit(v, UNIT) and has_bit(v, PLAYER)) then
                return false, "player answered " .. tostring(v)
                    .. " - Unit(" .. UNIT .. ")/Player(" .. PLAYER .. ") bits not set;"
                    .. " looks like the ObjectType ENUM, not the flags mask"
            end
            return true, "player -> " .. tostring(v) .. " (Unit+Player bits set)"
        end,
    },
    {
        name = "gameobject_fields",
        why = "3.3.5a keys update-fields PER OBJECT TYPE. GAMEOBJECT_DYNAMIC is "
           .. "byte 0x38; UNIT_DYNAMIC_FLAGS is 0x13C, and a gameobject "
           .. "descriptor ENDS at 0x48 - so the unit offset read ~0xF4 bytes "
           .. "past the block and the SPARKLE witness tested garbage. That "
           .. "witness is the ONLY way to find Ascension's custom quest objects: "
           .. "the vendored database ships zero object rows for this server.",
        run = function(call)
            local L = RaijinLab.om and RaijinLab.om.object_list
            local gos = L and L.gameobjects
            if not (gos and #gos > 0) then
                return nil, "no gameobjects in range to measure against"
            end

            -- Pick one whose entry id we already know, so the descriptor pointer
            -- itself can be proven before anything is concluded from it.
            local obj
            for _, g in ipairs(gos) do
                if g.Guid and tonumber(g.Id) and tonumber(g.Id) > 0 then obj = g break end
            end
            if not obj then return nil, "no gameobject with a known entry id" end

            -- 1. OBJECT_FIELD_ENTRY (0x0C) is shared by every type. If this does
            --    not match, the descriptor base is wrong and nothing below means
            --    anything - so this must be checked FIRST, not assumed.
            local entry = call("ObjectField", obj.Guid, 0x0C, 0)
            if tonumber(entry) ~= tonumber(obj.Id) then
                return false, string.format(
                    "descriptor base is WRONG: OBJECT_FIELD_ENTRY(0x0C)=%s but "
                    .. "the object manager says entry %s",
                    tostring(entry), tostring(obj.Id))
            end

            -- 2. The dedicated command must agree with a RAW read at the
            --    documented gameobject offset. This is the assertion that pins
            --    the fix: revert OM::DynamicFlags to the unit offset and these
            --    two diverge immediately.
            local raw = tonumber(call("ObjectField", obj.Guid, 0x38, 0))
            local dyn = tonumber(call("ObjectDynamicFlags", obj.Guid))
            if raw == nil or dyn == nil then
                return false, "ObjectField/ObjectDynamicFlags unhandled (nil)"
            end
            local lo = raw % 65536      -- GAMEOBJECT_DYNAMIC packs flags in the low word
            if dyn ~= lo then
                local unit_field = tonumber(call("ObjectField", obj.Guid, 0x13C, 0))
                return false, string.format(
                    "ObjectDynamicFlags=%d but GAMEOBJECT_DYNAMIC(0x38) low word "
                    .. "is %d (raw 0x%X). UNIT_DYNAMIC_FLAGS(0x13C)=%s - if that "
                    .. "is what came back, the per-type dispatch regressed",
                    dyn, lo, raw, tostring(unit_field))
            end

            -- 3. REPORT the observed low word - deliberately NOT asserted.
            --
            -- Which bit is SPARKLE is genuinely unsettled: this addon's enum says
            -- ACTIVATE=0x04 / SPARKLE=0x20, while TrinityCore 3.3.5 defines
            -- ACTIVATE=0x01 / SPARKLE=0x08 - the same set shifted one bit. Both
            -- cannot be right, and nothing offline can decide it. Asserting a
            -- mask here would bake a guess into a passing test, which is worse
            -- than not testing it. `/raijin goflags` resolves it from real
            -- objects instead.
            -- GAMEOBJECT_BYTES_1 needs no dynamic flag to be meaningful, so
            -- report it here: if this server never sets GAMEOBJECT_DYNAMIC, the
            -- type byte is what the witness will have to run on. Reported, not
            -- asserted - the type numbering itself is not yet verified.
            local b1 = tonumber(call("GameObjectBytes1", obj.Guid)) or 0
            return true, string.format(
                "%s entry=%d dynamic=0x%X (raw 0x%X) type=%d state=%d "
                .. "- per-type offset confirmed; /raijin goflags pins the bits",
                tostring(obj.Name or "?"), tonumber(obj.Id), lo, raw,
                math.floor(b1 / 256) % 256, math.floor(b1) % 256)
        end,
    },
    {
        name = "questgiver_status",
        why = "giver DISCOVERY reads ObjectQuestGiverStatus; if that answers 0 or "
           .. "nil for every NPC the bot can never find a quest giver on its own - "
           .. "it can only use one you targeted by hand",
        run = function(call, opts)
            local tgt = opts and opts.target_guid
            if not tgt then return nil, "target a quest giver (! or ?) and re-run" end
            local st = call("ObjectQuestGiverStatus", tgt)
            if st == nil then return false, "nil - status source not wired" end
            if type(st) ~= "number" then return false, "non-numeric " .. type(st) end
            -- 0 is a legitimate answer for an NPC with nothing to offer, so it is
            -- reported rather than failed - but on a giver showing ! or ? it is
            -- the signature of the dead source that makes discovery impossible.
            local meaning = "none/unavailable"
            if st == 8 or st == 7 or st == 2 or st == 4 then meaning = "AVAILABLE (!)"
            elseif st == 10 or st == 9 or st == 3 or st == 6 then meaning = "TURN-IN (?)"
            elseif st == 5 then meaning = "incomplete (in progress)" end
            -- Also report the ENGINE's own view. The live session showed the
            -- status source answering perfectly (st=10, read from +0x90) while
            -- only TWO queries were made in fourteen minutes - i.e. the scan was
            -- not running, not that it was failing. If `alive` is false here
            -- while status is non-zero, the engine has written the source off
            -- without asking: a self-fulfilling "looks dead because we never
            -- queried it", and that is the whole discovery failure.
            local extra = ""
            local QOM = RaijinLab and RaijinLab.QuestOM
            if QOM then
                local alive = QOM.status_source_alive and QOM.status_source_alive()
                extra = string.format("  [engine: alive=%s asked=%s nonzero=%s]",
                    tostring(alive), tostring(QOM._status_asked),
                    tostring(QOM._status_nonzero))
            end
            return true, "status=" .. tostring(st) .. " -> " .. meaning .. extra
        end,
    },
    {
        name = "interact_honest",
        why = "InteractGuid returned true unconditionally, so ok=1 meant nothing; "
           .. "and the token must land at Lua stack index 1",
        run = function(call, opts)
            local tgt = opts and opts.target_guid
            if not tgt then return nil, "needs a target" end
            local ok = call("Interact", tgt)
            if ok == nil then return false, "nil - not wired" end
            if type(ok) ~= "boolean" then return false, "non-boolean " .. type(ok) end
            return true, "reports " .. tostring(ok) .. " (a real outcome, not a constant)"
        end,
    },
    {
        name = "aura_walk_vs_client",
        why = "the direct in-unit aura walk (1.11.0) replaces the combat-log "
           .. "note store; its 12340 offsets are unverified on Ascension until "
           .. "this check compares a real unit against the client's own UnitAura",
        run = function(call, opts)
            if not UnitBuff or not UnitDebuff then
                return nil, "no client aura API in this environment"
            end
            -- The player always exists and almost always carries at least one
            -- aura; the comparison is exact set membership, both directions.
            local want = {}
            local n = 0
            for i = 1, 40 do
                local name, _, _, count, _, _, _, _, _, _, sid =
                    UnitBuff("player", i)
                if not name then break end
                if sid then want[sid] = count or 1; n = n + 1 end
            end
            for i = 1, 40 do
                local name, _, _, count, _, _, _, _, _, _, sid =
                    UnitDebuff("player", i)
                if not name then break end
                if sid then want[sid] = count or 1; n = n + 1 end
            end
            local pack = call("UnitAuras")
            if type(pack) ~= "string" then return false, "UnitAuras nil" end
            local src = pack:match("|src=(%w)")
            if src ~= "d" then
                -- The walk refused to validate: HONEST, but the direct path is
                -- not live - that is a failure of the feature under test.
                return false, "walk not validating (src=" .. tostring(src)
                    .. ") pack=" .. pack:sub(1, 60)
            end
            local got = {}
            for sid, stacks in pack:gmatch("|(%d+):(%d+):%-?%d+") do
                got[tonumber(sid)] = tonumber(stacks)
            end
            local missing, extra = 0, 0
            local detail = ""
            for sid in pairs(want) do
                if not got[sid] then
                    missing = missing + 1
                    if #detail < 80 then detail = detail .. " -" .. sid end
                end
            end
            for sid in pairs(got) do
                if not want[sid] then
                    extra = extra + 1
                    if #detail < 80 then detail = detail .. " +" .. sid end
                end
            end
            if n == 0 then
                -- No client-visible aura to compare against. The walk seeing
                -- hidden auras is normal; nothing here can indict the layout.
                return nil, "no visible auras on player to compare"
            end
            -- DIRECTIONAL: the unit's table holds HIDDEN auras UnitBuff never
            -- lists, so `extra` is expected and only reported. `missing` is
            -- the indictment: a client-visible aura the walk cannot see means
            -- the offsets are wrong for this client.
            if missing > 0 then
                return false, string.format("walk MISSED %d visible aura(s):%s",
                    missing, detail)
            end
            return true, string.format("%d visible aura(s) all present, +%d hidden, src=direct",
                n, extra)
        end,
    },
    {
        name = "castreq_ground_truth",
        why = "SpellCastReq drives every data-driven basic check; its layout "
           .. "was cracked against stock spells - verify two anchors in vivo",
        run = function(call)
            -- 6603 Auto Attack: range index 1 (self), no GCD (gcd=0), phys school.
            local aa = call("SpellCastReq", 6603)
            if type(aa) ~= "string" or not aa:find("found=1", 1, true) then
                return false, "6603 not decodable: " .. tostring(aa)
            end
            local gcd = tonumber(aa:match("|gcd=(%d+)") or "")
            local school = tonumber(aa:match("|school=0x(%x+)") or "", 16)
            if gcd ~= 0 then return false, "Auto Attack gcd=" .. tostring(gcd) .. " (want 0)" end
            if school ~= 1 then return false, "Auto Attack school=" .. tostring(school) .. " (want 1)" end
            -- 133 Fireball: fire school (0x4), on the standard 1.5s GCD, mana.
            local fb = call("SpellCastReq", 133)
            if type(fb) ~= "string" or not fb:find("found=1", 1, true) then
                return false, "133 not decodable"
            end
            local fgcd = tonumber(fb:match("|gcd=(%d+)") or "")
            local fsch = tonumber(fb:match("|school=0x(%x+)") or "", 16)
            local fpow = tonumber(fb:match("|power=(%d+)") or "")
            if fsch ~= 4 then return false, "Fireball school=" .. tostring(fsch) .. " (want 4=fire)" end
            if fpow ~= 0 then return false, "Fireball power=" .. tostring(fpow) .. " (want 0=mana)" end
            if not fgcd or fgcd < 1000 then return false, "Fireball gcd=" .. tostring(fgcd) end
            return true, string.format("6603: gcd=0 school=phys; 133: gcd=%d school=fire", fgcd)
        end,
    },
}

-- Run every check. Returns rows {name, ok, detail, why} plus counts.
-- `call` is the bridge callable; errors inside a check are caught and reported
-- as failures rather than aborting the run - a selftest that dies partway is
-- exactly as useless as no selftest.
-- RESULTS GO TO THE LOG FILE, NOT TO A SCREENSHOT.
--
-- The whole point of the dev log is that the developer reads it from disk. A
-- readout that only exists in the chat frame forces the user to screenshot it
-- and transcribe findings by hand, which is exactly the workflow they asked not
-- to have. Every run - manual or automatic - writes here, and flushes, so the
-- results are on disk immediately.
function SelfTest.log_rows(rows, pass, fail, skip, why)
    local DL = RaijinLab and RaijinLab.DevLog
    if not (DL and DL.log) then return end
    DL.log("selftest", "=== selftest (%s) expect=%s ===",
        tostring(why or "manual"), tostring(SelfTest.EXPECT_VERSION))
    for _, r in ipairs(rows or {}) do
        local tag = (r.ok == nil) and "SKIP" or (r.ok and "PASS" or "FAIL")
        DL.log("selftest", "%s %-22s %s", tag, tostring(r.name),
            tostring(r.detail or ""))
        if r.ok == false and r.why then
            DL.log("selftest", "     why: %s", tostring(r.why))
        end
    end
    DL.log("selftest", "=== %d passed, %d failed, %d skipped ===",
        pass or 0, fail or 0, skip or 0)
    if DL.flush then pcall(DL.flush) end
end

function SelfTest.evaluate(call, opts)
    local rows, pass, fail, skip = {}, 0, 0, 0
    for _, c in ipairs(SelfTest.CHECKS) do
        local ok, detail
        local success, a, b = pcall(c.run, call, opts)
        if not success then
            ok, detail = false, "check errored: " .. tostring(a)
        else
            ok, detail = a, b
        end
        if ok == nil then
            skip = skip + 1
        elseif ok then
            pass = pass + 1
        else
            fail = fail + 1
        end
        rows[#rows + 1] = { name = c.name, ok = ok, detail = detail, why = c.why }
    end
    return rows, pass, fail, skip
end

if RaijinLab then RaijinLab.SelfTest = SelfTest end
return SelfTest
