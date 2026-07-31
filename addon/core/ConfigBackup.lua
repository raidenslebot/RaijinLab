-- ConfigBackup - config that survives an unclean shutdown.
--
-- WoW writes SavedVariables ONLY on a clean logout, /reload, or exit. If the
-- client crashes, hangs and gets killed, or the machine dies, EVERYTHING since
-- login is silently lost - which is exactly what "my config reset randomly" feels
-- like. Nothing in the addon can change when the client writes that file.
--
-- But the injected runtime can write files whenever we like. So the expensive,
-- hand-made parts of the config (rotations above all) are mirrored to our own
-- file on a timer, and restored if the saved variables come back empty.
--
-- SAFETY RULES, because a restore that guesses wrong destroys the very data it
-- exists to protect:
--   * NEVER overwrite live data. A restore only fills things that are MISSING.
--   * A backup is only written when it has something to say - never blank over a
--     good backup with an empty one.
--   * Rotating slots, so one bad write cannot take the history with it.
--   * The user is always told, loudly, when a restore happens.
--
-- The bulky learned stores (world mesh, POI, traversability) are deliberately NOT
-- backed up: they are large and the bot re-learns them for free, whereas a
-- rotation represents real human effort.

local CB = {}

CB.SLOTS = 3               -- rotating backup files
CB.INTERVAL = 180          -- seconds between automatic backups
CB._last = 0
CB._running = false

local function now() return (GetTime and GetTime()) or 0 end
local function TT() return RaijinLab and RaijinLab.Telemetry end

-- The keys worth protecting: user effort, not machine-learned data.
CB.KEYS = {
    "rotations", "active_rotation", "characters", "active_config",
    "quest", "vendor", "rest", "trainer", "death", "watchdog", "telemetry",
    "combat", "gather", "grind", "looter", "modules", "objects_to_track",
    "enabled_lists", "schema_version", "mount", "travel",
}

function CB.dir()
    local d = RaijinLab and RaijinLab.GetWoWDirectory and RaijinLab:GetWoWDirectory()
    if not d or d == "" then return nil end
    return d .. "\\Logs"
end

function CB.path(slot)
    local d = CB.dir()
    if not d then return nil end
    return d .. "\\raijinlab_config_" .. tostring(slot or 1) .. ".lua"
end

-- ---- serialization -------------------------------------------------------
-- Emits plain Lua that loadstring can read back. Bounded depth so a cyclic or
-- pathological table can never hang the client while trying to protect it.
local function ser(v, depth, out)
    depth = depth or 0
    if depth > 12 then out[#out + 1] = "nil"; return end
    local t = type(v)
    if t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" then
        -- 14 significant digits: enough to round-trip every value we store, and
        -- the same budget the packed world-mesh word is designed around.
        if v == math.floor(v) and math.abs(v) < 1e15 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.14g", v)
        end
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "table" then
        out[#out + 1] = "{"
        for k, val in pairs(v) do
            local kt, vt = type(k), type(val)
            if (kt == "string" or kt == "number")
                and (vt == "string" or vt == "number" or vt == "boolean" or vt == "table") then
                if kt == "string" then
                    out[#out + 1] = "[" .. string.format("%q", k) .. "]="
                else
                    out[#out + 1] = "[" .. string.format("%.14g", k) .. "]="
                end
                ser(val, depth + 1, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "nil"
    end
end

function CB.serialize(tbl)
    local out = { "RaijinLabConfigBackup = " }
    ser(tbl, 0, out)
    out[#out + 1] = "\n"
    return table.concat(out)
end

-- ---- what we protect -----------------------------------------------------

function CB.collect()
    if type(RaijinLabDB) ~= "table" then return nil end
    -- COMMIT BEFORE SNAPSHOTTING. The rotation the user is editing lives in
    -- Executor._active_cache and only reaches RaijinLabDB when flush() runs at
    -- logout. Backing up without flushing first captured the STALE rotation
    -- every time - so a crash lost the edits AND the backup faithfully preserved
    -- the version without them. That is how a rotation ends up saved by name
    -- with zero spells in it.
    if RaijinLab and RaijinLab.FlushRotations then
        pcall(RaijinLab.FlushRotations, RaijinLab)
    end
    local snap = {}
    local any = false
    for _, k in ipairs(CB.KEYS) do
        local v = RaijinLabDB[k]
        if v ~= nil then snap[k] = v; any = true end
    end
    if not any then return nil end
    return snap
end

-- Does this rotation contain any ACTUAL work? When a character's store is empty
-- the Executor auto-creates a placeholder "Default" holding a single blank slot
-- (spell_id 0) so the editor has something to show. Counting that as a rotation
-- is what made this whole safety net useless: a freshly-seeded account looked
-- "populated", looks_reset() said no, and a backup full of real rotations was
-- never offered. An empty placeholder is the ABSENCE of work, not work.
function CB.is_real_rotation(rot)
    if type(rot) ~= "table" then return false end
    local slots = rot.slots
    if type(slots) ~= "table" then return false end
    for _, sl in pairs(slots) do
        if type(sl) == "table" then
            local id = tonumber(sl.spell_id or 0) or 0
            if id ~= 0 then return true end
        end
    end
    return false
end

-- Count real rotations everywhere they can live: the account-level table AND
-- every per-character bucket. Rotations are stored per character, so counting
-- only the account-level mirror under-reports badly.
function CB.count_rotations(tbl)
    if type(tbl) ~= "table" then return 0 end
    local n = 0
    if type(tbl.rotations) == "table" then
        for _, r in pairs(tbl.rotations) do
            if CB.is_real_rotation(r) then n = n + 1 end
        end
    end
    if type(tbl.characters) == "table" then
        for _, c in pairs(tbl.characters) do
            if type(c) == "table" and type(c.rotations) == "table" then
                for _, r in pairs(c.rotations) do
                    if CB.is_real_rotation(r) then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- Is this snapshot worth writing? A backup whose rotations are empty must never
-- replace one that has them - that would turn a transient empty state into
-- permanent loss.
function CB.worth_writing(snap)
    if type(snap) ~= "table" then return false end
    return CB.count_rotations(snap) > 0
end

function CB.save(force)
    local t = now()
    if not force and (t - (CB._last or 0)) < CB.INTERVAL then return false, "throttled" end
    local snap = CB.collect()
    if not snap then return false, "nothing" end
    if not CB.worth_writing(snap) then return false, "empty" end
    CB._last = t
    CB._slot = ((CB._slot or 0) % CB.SLOTS) + 1
    local path = CB.path(CB._slot)
    if not (path and RaijinLab.WriteFile) then return false, "no_io" end
    local ok = pcall(RaijinLab.WriteFile, RaijinLab, path, CB.serialize(snap))
    local Tel = TT()
    if Tel then Tel.info("config", "backup", { slot = CB._slot, ok = ok and true or false }) end
    return ok and true or false
end

-- ---- restore -------------------------------------------------------------

-- Load a backup slot. Runs the file in an EMPTY environment: a backup is data,
-- and must never be able to execute anything against the addon.
function CB.load(slot)
    local path = CB.path(slot)
    if not (path and RaijinLab.ReadFile) then return nil end
    local ok, text = pcall(RaijinLab.ReadFile, RaijinLab, path)
    if not ok or type(text) ~= "string" or text == "" then return nil end
    -- Portability: WoW's Lua 5.1 has loadstring/setfenv; 5.2+ replaced both with
    -- load(chunk, name, mode, env). Support both so this is testable headless AND
    -- correct in game - the same trap that math.atan2 set earlier.
    local env = {}
    local chunk
    if loadstring then
        chunk = loadstring(text)
        if chunk and setfenv then setfenv(chunk, env) end
    elseif load then
        -- "t" = text only: a backup is DATA and must never be loadable bytecode.
        chunk = load(text, "raijinlab_backup", "t", env)
    end
    if not chunk then return nil end
    local ran = pcall(chunk)
    if not ran then return nil end
    local snap = env.RaijinLabConfigBackup
    if type(snap) ~= "table" then return nil end
    return snap
end

-- The newest backup that actually contains rotations.
function CB.best()
    local best, bestslot = nil, nil
    for slot = 1, CB.SLOTS do
        local snap = CB.load(slot)
        if snap and CB.worth_writing(snap) then
            -- prefer the one with the most rotations; ties keep the later slot
            if not best or CB.count_rotations(snap) >= CB.count_rotations(best) then
                best, bestslot = snap, slot
            end
        end
    end
    return best, bestslot
end

-- Does the LIVE db look like it lost the user's work?
function CB.looks_reset()
    if type(RaijinLabDB) ~= "table" then return true end
    return not CB.worth_writing(RaijinLabDB)
end

-- Restore ONLY what is missing. Never clobbers live data - if the DB already has
-- a key, the backup's copy is ignored, because the live one is newer by
-- definition and a "helpful" overwrite is how a restore destroys real work.
function CB.restore(opts)
    opts = opts or {}
    local snap, slot = CB.best()
    if not snap then return false, "no_backup" end
    RaijinLabDB = RaijinLabDB or {}
    local filled = {}
    for _, k in ipairs(CB.KEYS) do
        if RaijinLabDB[k] == nil and snap[k] ~= nil then
            RaijinLabDB[k] = snap[k]
            filled[#filled + 1] = k
        end
    end
    -- Rotations get a per-name merge: a character can legitimately have SOME
    -- rotations while missing others.
    --
    -- "Missing" has to include the auto-created empty placeholder, not just nil.
    -- The Executor seeds a blank "Default" into any empty store, so a lost
    -- rotation does not leave a nil to fill - it leaves a decoy sitting on the
    -- name. Filling only nils meant the restore skipped precisely the case it
    -- exists for. Overwriting a placeholder is still non-destructive: by
    -- definition it holds no spells, so there is nothing to lose.
    local function should_fill(live, backup)
        if not CB.is_real_rotation(backup) then return false end   -- never restore junk
        if live == nil then return true end
        return not CB.is_real_rotation(live)                       -- live is a placeholder
    end

    if type(snap.rotations) == "table" then
        RaijinLabDB.rotations = RaijinLabDB.rotations or {}
        for name, data in pairs(snap.rotations) do
            if should_fill(RaijinLabDB.rotations[name], data) then
                RaijinLabDB.rotations[name] = data
                filled[#filled + 1] = "rotation:" .. tostring(name)
            elseif RaijinLab.MergeRotationInto then
                if RaijinLab.MergeRotationInto(RaijinLabDB.rotations, name, data) then
                    filled[#filled + 1] = "rotation:" .. tostring(name)
                end
            end
        end
    end

    -- PER-CHARACTER buckets. Rotations actually live at
    -- RaijinLabDB.characters[<name>-<realm>].rotations; the account-level table
    -- is only a mirror. Restoring just the mirror left every character still
    -- looking empty, which is what the user sees.
    if type(snap.characters) == "table" then
        RaijinLabDB.characters = RaijinLabDB.characters or {}
        for key, src in pairs(snap.characters) do
            if type(src) == "table" and type(src.rotations) == "table" then
                local dst = RaijinLabDB.characters[key]
                if type(dst) ~= "table" then
                    dst = { rotations = {}, active_config = src.active_config or "Default" }
                    RaijinLabDB.characters[key] = dst
                end
                dst.rotations = dst.rotations or {}
                for name, data in pairs(src.rotations) do
                    if should_fill(dst.rotations[name], data) then
                        dst.rotations[name] = data
                        filled[#filled + 1] = tostring(key) .. "/" .. tostring(name)
                    elseif RaijinLab.MergeRotationInto then
                        if RaijinLab.MergeRotationInto(dst.rotations, name, data) then
                            filled[#filled + 1] = tostring(key) .. "/" .. tostring(name)
                        end
                    end
                end
                -- Heal active_config if it points at an empty shell.
                if src.active_config and CB.is_real_rotation(dst.rotations[src.active_config]) then
                    if not CB.is_real_rotation(dst.rotations[dst.active_config or ""]) then
                        dst.active_config = src.active_config
                    end
                end
            end
        end
    end
    local Tel = TT()
    if Tel then Tel.warn("config", "restored", { slot = slot, keys = #filled }) end
    if #filled > 0 and print then
        print("|cffffcc00RaijinLab|r recovered " .. #filled ..
              " item(s) from backup slot " .. tostring(slot) .. ":")
        for i = 1, math.min(#filled, 12) do print("   |cff10ff10+|r " .. tostring(filled[i])) end
        if #filled > 12 then print("   ... and " .. (#filled - 12) .. " more") end
        print("|cffffcc00RaijinLab|r note: rotations are saved per LOGIN ACCOUNT " ..
              "(WTF/Account/<account>/SavedVariables). Logging in on a different " ..
              "account shows a different set - the originals are not deleted.")
    end
    return #filled > 0, filled
end

-- Called at VARIABLES_LOADED, before anything reads the config.
function CB.on_load()
    local reset = CB.looks_reset()
    local Tel = TT()
    if Tel then Tel.info("config", "load", { looks_reset = reset }) end
    if reset then
        CB.restore()
    end
    -- Always take a fresh backup once we are up, so a good state is banked.
    CB.save(true)
end

function CB.start()
    if CB._running then return end
    CB._running = true
    if C_Timer and C_Timer.NewTicker then
        CB._ticker = C_Timer.NewTicker(CB.INTERVAL, function() pcall(CB.save) end)
    end
end

function CB.stop()
    if CB._ticker then CB._ticker:Cancel(); CB._ticker = nil end
    CB._running = false
end

function CB.stats()
    local slots = {}
    for i = 1, CB.SLOTS do
        local s = CB.load(i)
        local n = 0
        if s and type(s.rotations) == "table" then for _ in pairs(s.rotations) do n = n + 1 end end
        slots[#slots + 1] = { slot = i, present = s ~= nil, rotations = n }
    end
    return { slots = slots, looks_reset = CB.looks_reset(), dir = CB.dir() }
end

if RaijinLab then RaijinLab.ConfigBackup = CB end
return CB
