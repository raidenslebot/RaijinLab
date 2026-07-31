-- ============================================================
-- RaijinLab - robust SavedVariables persistence
-- ============================================================
-- WoW writes SavedVariables to disk ONLY on a clean logout, /reload, or exit.
-- A crash discards every change made since the last flush. This module makes
-- persistence as durable as the client allows:
--   1. SANITIZE - strip any value SavedVariables can't serialize (functions,
--      frames/userdata, threads, cyclic tables). A single bad value anywhere in
--      RaijinLabDB can make WoW silently fail to write the ENTIRE file, which
--      looks exactly like "nothing saves". We guarantee the tree is always clean.
--   2. FLUSH ON LOGOUT - re-commit the active rotation right before the file is
--      written, capturing any editor state that wasn't explicitly saved.
--   3. SCHEMA VERSION - tag the DB so future format changes migrate instead of
--      wiping data.
--
-- NOTE (surfaced to the user): edits are held in RaijinLabDB the instant you make
-- them, but only reach disk on clean exit or /reload. If the client crashes, the
-- OS never gets the write. `/raijin save` reminds you; `/reload` force-persists.
-- ============================================================

local RL = RaijinLab
if not RL then return end

RL.DB_SCHEMA_VERSION = 3

-- True when a stored rotation holds at least one real spell (not a blank shell).
-- Empty "Default" placeholders must NEVER overwrite real configs on sync/migrate.
function RL.IsRealRotation(rot)
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

-- Merge one rotation into a store: never replace a real rotation with a shell.
-- Returns true if store[name] changed.
function RL.MergeRotationInto(store, name, data)
    if type(store) ~= "table" or type(name) ~= "string" or name == "" then return false end
    if type(data) ~= "table" then return false end
    if not RL.IsRealRotation(data) then
        -- Only seed a placeholder if the name is completely missing.
        if store[name] == nil then
            store[name] = data
            return true
        end
        return false
    end
    local live = store[name]
    if live == nil or not RL.IsRealRotation(live) then
        store[name] = data
        return true
    end
    -- Both real: prefer the one with more filled slots (protect richer edit).
    local function filled(r)
        local n = 0
        for _, sl in ipairs((r and r.slots) or {}) do
            if type(sl) == "table" and (tonumber(sl.spell_id) or 0) ~= 0 then n = n + 1 end
        end
        return n
    end
    if filled(data) >= filled(live) then
        store[name] = data
        return true
    end
    return false
end

-- Build the per-character namespace key. Falls back to a fixed sentinel when
-- called at character-select (UnitName/GetRealmName return nil there) so we
-- don't wipe user data by writing to a "<nil>|<nil>" bucket.
function RL:CharacterKey()
    local name = (UnitName and UnitName("player")) or nil
    local realm = (GetRealmName and GetRealmName()) or nil
    if not name or not realm or name == "" or realm == "" then
        return nil
    end
    return name .. "-" .. realm
end

-- Return (or create) the per-character bucket under RaijinLabDB.characters[key].
-- Returns nil at character-select (no key). Callers must gate on that.
-- On first create, seeds from account-level legacy rotations (never empty shell
-- when real account configs exist).
function RL:CharacterDB()
    local key = self:CharacterKey()
    if not key then return nil end
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.characters = RaijinLabDB.characters or {}
    local c = RaijinLabDB.characters[key]
    local created = false
    if not c then
        c = {
            rotations = {},           -- name -> serialized rotation
            active_config = "Default",
        }
        RaijinLabDB.characters[key] = c
        created = true
    end
    c.rotations = c.rotations or {}
    c.active_config = c.active_config or "Default"
    -- Import / heal from account-level mirror whenever character store is empty
    -- or only has placeholders (migration race, empty Default seed).
    if type(RaijinLabDB.rotations) == "table" then
        local any_real = false
        for _, r in pairs(c.rotations) do
            if RL.IsRealRotation(r) then any_real = true; break end
        end
        if created or not any_real then
            for name, data in pairs(RaijinLabDB.rotations) do
                if type(name) == "string" and type(data) == "table" then
                    local copy = (self.Sanitize and self.Sanitize(data)) or data
                    RL.MergeRotationInto(c.rotations, name, copy)
                end
            end
            local act = RaijinLabDB.active_rotation
            if type(act) == "string" and act ~= "" and c.rotations[act] then
                c.active_config = act
            end
        end
    end
    return c, key
end

-- Deep-copy that keeps only SavedVariables-serializable data. Drops functions,
-- userdata (frames), and threads; skips table keys that aren't string/number;
-- breaks reference cycles. Returns nil for anything unserializable so callers
-- can omit the key entirely.
local function sanitize(v, seen)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
        return v
    elseif t == "table" then
        seen = seen or {}
        if seen[v] then return nil end          -- cycle guard
        seen[v] = true
        local out = {}
        for k, val in pairs(v) do
            local kt = type(k)
            if kt == "string" or kt == "number" then
                local sv = sanitize(val, seen)
                if sv ~= nil then out[k] = sv end
            end
        end
        seen[v] = nil
        return out
    end
    return nil                                   -- function / userdata / thread
end
RL.Sanitize = sanitize

-- Rewrite every top-level key of RaijinLabDB through the sanitizer, IN PLACE so
-- the table identity the SavedVariables system tracks is preserved. Called right
-- before logout so the write can never be poisoned.
function RL:SanitizeDB()
    if type(RaijinLabDB) ~= "table" then return end
    for k, val in pairs(RaijinLabDB) do
        local sv = sanitize(val)
        RaijinLabDB[k] = sv                       -- nil drops an unserializable key
    end
end

-- Force the active rotation back into the DB. Edits already write through on
-- Save(), so this is belt-and-suspenders - it also captures the case where the
-- editor mutated the live object without an explicit Save.
function RL:FlushRotations()
    local Ex = RL.RotationExecutor
    if Ex and Ex.flush then
        local ok = pcall(Ex.flush)
        return ok
    end
    return false
end

-- PERIODIC COMMIT. Until now the ONLY thing that moved an edited rotation out of
-- the editor's live object and into RaijinLabDB was the logout flush. Any exit
-- that is not a clean logout - a crash, a hang that gets force-killed, a power
-- cut - therefore discarded every rotation edit made since login, which is
-- exactly the "my rotations keep resetting" report. WoW still only writes the
-- file on a clean exit, but committing continuously means the in-memory DB (and
-- so the ConfigBackup mirror, which CAN be written any time) is always current.
RL.AUTOCOMMIT_INTERVAL = 20

function RL:StartAutoCommit()
    if RL._autocommit then return end
    local function commit()
        local Ex = RL.RotationExecutor
        -- Only when there is something to commit: a needless serialize every
        -- 20s is pure garbage for the collector to chase.
        if Ex and Ex._dirty_since_flush then
            local ok = pcall(RL.FlushRotations, RL)
            local Tel = RL.Telemetry
            if Tel then Tel.debug("config", "autocommit", { ok = ok and true or false }) end
        end
    end
    if C_Timer and C_Timer.NewTicker then
        RL._autocommit = C_Timer.NewTicker(RL.AUTOCOMMIT_INTERVAL, commit)
    else
        local f = CreateFrame("Frame")
        local acc = 0
        f:SetScript("OnUpdate", function(_, e)
            acc = acc + e
            if acc >= RL.AUTOCOMMIT_INTERVAL then acc = 0; commit() end
        end)
        RL._autocommit = f
    end
end

-- Schema versioning + migration. Runs at VARIABLES_LOADED, after the raw DB is
-- loaded from disk. Add migration branches here as the format evolves; each must
-- be idempotent and preserve user data.
function RL:InitPersistence()
    RaijinLabDB = RaijinLabDB or {}
    local from = tonumber(RaijinLabDB.schema_version) or 1

    if from < 2 then
        -- v1 -> v2: ensure rotations container + active pointer exist; normalize
        -- every stored rotation through the engine so legacy/partial rows can't
        -- crash the loader later.
        RaijinLabDB.rotations = RaijinLabDB.rotations or {}
        RaijinLabDB.active_rotation = RaijinLabDB.active_rotation or "Default"
        local Engine = RL.RotationEngine
        if Engine and Engine.deserialize and Engine.serialize then
            for name, data in pairs(RaijinLabDB.rotations) do
                local okd, norm = pcall(function()
                    return Engine.serialize(Engine.deserialize(data))
                end)
                if okd and type(norm) == "table" then
                    RaijinLabDB.rotations[name] = norm
                end
            end
        end
    end

    if from < 3 then
        -- v2 -> v3: rotations move under RaijinLabDB.characters[realm-name].
        -- Legacy top-level RaijinLabDB.rotations is preserved as a fallback
        -- and copied into the CURRENT character's bucket on first login on
        -- that character (see CharacterDB() call path). We can't do the copy
        -- here - VARIABLES_LOADED fires before PLAYER_LOGIN, so UnitName is
        -- nil and CharacterKey() returns nil. Just create the container.
        RaijinLabDB.characters = RaijinLabDB.characters or {}
    end

    RaijinLabDB.schema_version = RL.DB_SCHEMA_VERSION
    RL._persistence_ready = true
end

-- Copy any legacy top-level rotations into the current character's bucket the
-- first time they log in on that character. Called from Events.lua on
-- PLAYER_LOGIN when the character namespace is finally addressable.
function RL:MigrateLegacyRotationsToCharacter()
    local c, key = self:CharacterDB()
    if not c or not key then return end
    local moved = 0
    if type(RaijinLabDB.rotations) == "table" then
        for name, data in pairs(RaijinLabDB.rotations) do
            if type(name) == "string" and name ~= "" and type(data) == "table" then
                local copy = (self.Sanitize and self.Sanitize(data)) or data
                -- Empty character shells must not block real legacy configs.
                if type(copy) == "table" and RL.MergeRotationInto(c.rotations, name, copy) then
                    if RL.IsRealRotation(copy) then moved = moved + 1 end
                end
            end
        end
    end
    -- Push real character rotations up into the account mirror too.
    RaijinLabDB.rotations = RaijinLabDB.rotations or {}
    for name, data in pairs(c.rotations or {}) do
        if type(name) == "string" and RL.IsRealRotation(data) then
            RL.MergeRotationInto(RaijinLabDB.rotations, name, data)
        end
    end
    -- Prefer a REAL active config (never stick on empty Default when better exists).
    local active = c.active_config or "Default"
    if not c.rotations[active] or not RL.IsRealRotation(c.rotations[active]) then
        local fallback = RaijinLabDB.active_rotation
        if fallback and RL.IsRealRotation(c.rotations[fallback]) then
            c.active_config = fallback
        else
            local best, bestN = nil, 0
            for n, r in pairs(c.rotations) do
                if type(n) == "string" and RL.IsRealRotation(r) then
                    local cnt = 0
                    for _, sl in ipairs(r.slots or {}) do
                        if (tonumber(sl.spell_id) or 0) ~= 0 then cnt = cnt + 1 end
                    end
                    if cnt > bestN then best, bestN = n, cnt end
                end
            end
            if best then
                c.active_config = best
            elseif not c.rotations[active] then
                c.active_config = "Default"
                if not c.rotations[c.active_config] then
                    c.rotations[c.active_config] = {
                        name = c.active_config, enabled = true, slots = {},
                    }
                end
            end
        end
    end
    RaijinLabDB.active_rotation = c.active_config
    if moved > 0 and not c._legacy_migrated then
        print(string.format(
            "|cff7ec8e3RaijinLab|r migrated/healed %d rotation%s into %s",
            moved, moved == 1 and "" or "s", key))
    end
    c._legacy_migrated = true
    local Ex = RL.RotationExecutor
    if Ex then
        Ex._active_cache = nil
        Ex._active_name = nil
        Ex._resolved_from = nil
    end
    return moved
end

-- Mirror character → account WITHOUT destroying real account configs.
-- Empty shells must never clobber a populated account-level rotation.
function RL:SyncActiveCharacterToLegacy()
    local c = self:CharacterDB()
    if not c then return false end
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.rotations = RaijinLabDB.rotations or {}
    for name, data in pairs(c.rotations or {}) do
        if type(name) == "string" and type(data) == "table" then
            local copy = (self.Sanitize and self.Sanitize(data)) or data
            if type(copy) == "table" then
                RL.MergeRotationInto(RaijinLabDB.rotations, name, copy)
            end
        end
    end
    local act = c.active_config
    if type(act) == "string" and act ~= ""
        and RL.IsRealRotation(RaijinLabDB.rotations[act]) then
        RaijinLabDB.active_rotation = act
    elseif not RL.IsRealRotation(RaijinLabDB.rotations[RaijinLabDB.active_rotation or ""]) then
        for n, r in pairs(RaijinLabDB.rotations) do
            if RL.IsRealRotation(r) then
                RaijinLabDB.active_rotation = n
                break
            end
        end
    end
    return true
end

-- Zone transitions (PLAYER_LEAVING_WORLD) fire on EVERY loading screen. Running
-- the full SanitizeDB there deep-copied every persisted table several times an
-- hour, which is both wasteful and destructive: sanitize returns NEW tables, so
-- any code holding a reference to a stored record (POI records, Patrol's visited
-- set) silently lost its identity. Zone changes only need the durability flush.
function RL:OnZoneOut()
    pcall(function() self:FlushRotations() end)
    pcall(function() self:SyncActiveCharacterToLegacy() end)
end

-- Final durability step before WoW serializes the file to disk.
function RL:OnLogout()
    pcall(function() self:FlushRotations() end)
    pcall(function() self:SyncActiveCharacterToLegacy() end)
    pcall(function() self:SanitizeDB() end)
    local Ex = RL.RotationExecutor
    if Ex then Ex._dirty_since_flush = false end
end
