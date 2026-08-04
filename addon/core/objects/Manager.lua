-- FORWARD DECLARATIONS.
--
-- ObjectProcessor is defined at the top of this file but uses helpers declared
-- further down. In Lua a function closes over the scope VISIBLE AT ITS
-- DEFINITION, so `local function ensure_flag_pairs` at line ~100 was invisible
-- to it: the call resolved to a GLOBAL, found nil, and every object-processing
-- pass died with "attempt to call a nil value" - which reads as an empty world.
-- Declaring the names here makes the later definitions assign to these locals.
local flag_pairs, decode_flags, ensure_flag_pairs
local UNIT_FLAG_PAIRS, UNIT_DFLAG_PAIRS, GO_FLAG_PAIRS, GO_DFLAG_PAIRS

local function ObjectProcessor(obj_type)
-- Belt and braces: whatever the bridge or wrapper returns, what LANDS in the
-- object struct is a real boolean. A numeric 0 here reads as true in Lua and
-- silently turned every object in the world into a quest objective.
local function _tied(v)
    if v == nil or v == false then return false end
    local n = tonumber(v)
    if n then return n ~= 0 end
    return true
end

    ensure_flag_pairs()
    local object_list = RaijinLab.om.object_list.raw[obj_type]
    if not object_list then return end
    local temp = {}
    local filtered = RaijinLab.om.object_list.filtered
    local interactable = RaijinLab.om.object_list.interactable
    local target = RaijinLab:UnitTarget("player")
    local track = RaijinLabDB and RaijinLabDB.objects_to_track
    local enabled = RaijinLabDB and RaijinLabDB.enabled_lists
    -- ObjectIsQuestObjective is a bridge call per unit; only while questing or
    -- the tracker is drawing quest objects. Idle/master-off skips entirely.
    local mods = RaijinLabDB and RaijinLabDB.modules
    local master_on = not (RaijinLab.Master and RaijinLab.Master.suppressed
        and RaijinLab.Master.suppressed())
    local _want_quest_tie = master_on and (
        (mods and mods.quest)
        or (RaijinLabDB and RaijinLabDB.track_quest_objects)
        or (RaijinLab.tracker_toggle)
    ) and true or false
    -- Rotation-only: skip flag decode + rare/loot/hidden probes (nameplates cover combat).
    local _light = master_on and mods and mods.rotation
        and not mods.quest and not mods.grind and not mods.gather
        and not _want_quest_tie
    -- All per-object field probes now come from the runtime snapshot (2026-08-02)
    -- - no per-object bridge calls / ObjectPtr game calls. Only the quest-tie
    -- probe stays a bridge call, gated behind quest/tracker mode.
    local UNIT_HIDE = (RaijinLab.enums and RaijinLab.enums.UnitDynamicFlags
        and RaijinLab.enums.UnitDynamicFlags.UNIT_DYNFLAG_HIDE_MODEL) or 0x20000
    local GO_NO_INTERACT = (RaijinLab.enums and RaijinLab.enums.GameObjectDynamicLowFlags
        and RaijinLab.enums.GameObjectDynamicLowFlags.GO_DYNFLAG_LO_NO_INTERACT) or 0x1
    local GO_INVERT = RaijinLab.enums and RaijinLab.enums.GameObjectTypesInverted
    -- Snapshot-derived dead: health 0 on a nonzero max (runtime authority;
    -- UnitIsDeadOrGhost(GUID) was nil for GUID-keyed objects).
    local function dead_from(s)
        local mhp = s and s._mhp or 0
        local hp = s and s._hp or 0
        return mhp and mhp > 0 and hp and hp <= 0
    end
    for i = 1, #object_list do
        local struct = object_list[i]
        local obj = struct.Object
        if obj_type == "players" then
            if not _light then
                struct.Flags.value = struct._flags or 0
                if struct.Flags.value then
                    struct.Flags.list = decode_flags(struct.Flags.value, UNIT_FLAG_PAIRS)
                end
                if struct.DynamicFlags.value then
                    struct.DynamicFlags.list = decode_flags(struct.DynamicFlags.value, UNIT_DFLAG_PAIRS)
                end
            end
            struct.Info.Unit.Dead = dead_from(struct)
            temp[#temp + 1] = struct
        elseif obj_type == "npcs" then
            if not _light then
                struct.Flags.value = struct._flags or 0
                if struct.Flags.value then
                    struct.Flags.list = decode_flags(struct.Flags.value, UNIT_FLAG_PAIRS)
                end
                if struct.DynamicFlags.value then
                    struct.DynamicFlags.list = decode_flags(struct.DynamicFlags.value, UNIT_DFLAG_PAIRS)
                end
                struct.Info.Unit.Rare = RaijinLab:UnitIsRare(obj)
                struct.Info.Unit.Hidden = bit.band(struct.DynamicFlags.value or 0, UNIT_HIDE) > 0
                -- Dead unit = lootable (snapshot authority).
                struct.Info.Unit.Lootable = dead_from(struct)
            end
            struct.Info.Unit.Dead = dead_from(struct)
            if _want_quest_tie then
                struct.Info.Quest.IsTiedToQuest = _tied(RaijinLab:ObjectIsQuestObjective(obj, struct.Id, struct.Guid, false))
            end
            temp[#temp + 1] = struct
        elseif obj_type == "gameobjects" then
            -- Rotation-only: skip GO processing entirely (quest/gather needs them).
            if _light then
                -- next object
            else
                -- GAMEOBJECT_BYTES_1 byte 1 = GO type (runtime snapshot field).
                local gb1 = struct._goBytes1 or 0
                local gtype = bit.rshift(bit.band(gb1, 0xFF00), 8)
                struct.Type.sub_type.id = gtype
                struct.Type.sub_type.name = GO_INVERT and GO_INVERT[gtype]
                struct.Flags.value = struct._flags or 0
                if struct.Flags.value then
                    struct.Flags.list = decode_flags(struct.Flags.value, GO_FLAG_PAIRS)
                end
                if struct.DynamicFlags.value then
                    struct.DynamicFlags.list = decode_flags(struct.DynamicFlags.value, GO_DFLAG_PAIRS)
                end
                if _want_quest_tie then
                    struct.Info.Quest.IsTiedToQuest = _tied(RaijinLab:ObjectIsQuestObjective(obj, struct.Id, struct.Guid, false))
                end
                struct.Info.GameObject.Interactable = bit.band(struct.DynamicFlags.value or 0, GO_NO_INTERACT) == 0
                temp[#temp + 1] = struct
                if track and enabled then
                    for list, items in pairs(track) do
                        if enabled[list] ~= nil then
                            if not filtered[list] then filtered[list] = {} end
                            if (list == "quest" and struct.Info.Quest.IsTiedToQuest)
                                or items[struct.Id] or items[struct.Name] then
                                filtered[list][#filtered[list] + 1] = struct
                            end
                        end
                    end
                end
                if struct.Info.GameObject.Interactable then
                    interactable[#interactable + 1] = struct
                end
            end
        end
        -- Unit post-process (players/npcs already appended to temp).
        if obj_type ~= "gameobjects" then
            if track and enabled and not _light then
                for list, items in pairs(track) do
                    if enabled[list] ~= nil then
                        if not filtered[list] then filtered[list] = {} end
                        if (list == "quest" and struct.Info.Quest.IsTiedToQuest)
                            or items[struct.Id] or items[struct.Name]
                            or struct.Info.Unit.Rare then
                            filtered[list][#filtered[list] + 1] = struct
                        end
                    end
                end
            end
            if not _light and struct.Info.Unit.Lootable then
                interactable[#interactable + 1] = struct
            end
            if struct.Object == target then
                TARGET_UNIT = struct
            end
        end
    end
    RaijinLab.om.object_list[obj_type] = temp
end

-- Pre-built flag mask tables: ObjectProcessor used pairs() over enums for every
-- unit every refresh (180 npcs x 20+ flags). Same bit decode, O(1) setup once.
function flag_pairs(enum)
    local out = {}
    if type(enum) ~= "table" then return out end
    for k, v in pairs(enum) do
        if type(v) == "number" then out[#out + 1] = { k, v } end
    end
    return out
end
function ensure_flag_pairs()
    if UNIT_FLAG_PAIRS then return end
    local E = RaijinLab and RaijinLab.enums
    if not E then return end
    UNIT_FLAG_PAIRS = flag_pairs(E.UnitFlags)
    UNIT_DFLAG_PAIRS = flag_pairs(E.UnitDynamicFlags)
    GO_FLAG_PAIRS = flag_pairs(E.GameObjectFlags)
    GO_DFLAG_PAIRS = flag_pairs(E.GameObjectDynamicLowFlags)
end

function decode_flags(value, pairs_list)
    if not value or not pairs_list then return {} end
    local flags = {}
    for i = 1, #pairs_list do
        local e = pairs_list[i]
        if bit.band(value, e[2]) > 0 then flags[e[1]] = true end
    end
    return flags
end

local function new_struct(objectGUID)
    return {
        Object = objectGUID,
        Name = "nil",
        Guid = objectGUID,
        Id = 0,
        Type = {
            base_type = { name = "nil" },
            sub_type = { id = 0, name = "nil" },
        },
        Flags = { value = 0, list = {} },
        DynamicFlags = { value = 0, list = {} },
        Info = {
            Quest = { IsTiedToQuest = false },
            Unit = {
                Dead = false, Hidden = false, Rare = false,
                Lootable = false, Skinnable = false,
            },
            Filter = { List = "nil" },
            GameObject = { Interactable = true },
        },
    }
end

local function RunObjectManager()
    -- ONE runtime call returns the whole cached OM packed. The runtime IS the
    -- object-manager authority (2026-08-02): this replaces the old per-object
    -- bridge calls (GetObjectWithIndex + ObjectTypeFlags + ObjectDynamicFlags
    -- + ObjectId + ObjectGUID per object = ~5 bridge calls/object/tick, each an
    -- ObjectPtr game call - the lag + Guard-recovery crash vector, live 1.10.68
    -- RVA 0x785A). 1 call + 1 string parse per tick instead. The snapshot packs
    -- every field the Lua OM consumed: guid/type-mask/entry/flags/dynflags/
    -- level/hp/mhp/pos/facing/faction/target/scale/goBytes1/npcFlags.
    local ok, packed = pcall(RaijinLab.RuntimeCall, RaijinLab, "OmSnapshot")
    if not ok or type(packed) ~= "string" or packed == "" or packed == "0" then
        RaijinLab.om.updated = false
        return
    end
    RaijinLab.om.updated = true
    if RaijinLab.force_update then
        RaijinLab.force_update = false
    end
    ensure_flag_pairs()

    -- REUSE structs by GUID. Was: allocate ~200 deep tables every 100ms -> GC
    -- spikes. Now: keep prior struct, refresh only fields that change, rebuild
    -- type buckets. More objects per second at a fraction of alloc cost.
    local prev_by_guid = (RaijinLab.om.object_list.indexes and RaijinLab.om.object_list.indexes.guid) or {}
    local players, gameobjects, npcs = {}, {}, {}
    local dynamicobjects, areatriggers, objects = {}, {}, {}
    local objects_by_guid, objects_by_name, objects_by_id = {}, {}, {}
    RaijinLab.om.active = true
    local count = 0
    local player_name = UnitName and UnitName("player")
    local OT = RaijinLab.enums and RaijinLab.enums.ObjectTypeFlags
    local MASK_PLAYER = OT and OT.Player or 0
    local MASK_GO = OT and OT.GameObject or 0
    local MASK_UNIT = OT and OT.Unit or 0
    local MASK_DO = OT and OT.DynamicObject or 0
    local MASK_AT = OT and OT.AreaTrigger or 0

    local first = true
    for part in string.gmatch(packed, "[^|]+") do
        if first then
            count = tonumber(part) or 0
            first = false
        else
            -- 0xGUID:TYPE:ENTRY:FLAGS:DYNFLAGS:LVL:HP:MHP:X:Y:Z:FACE:FACTION:0xTARGET:SCALE:GOBYTES1:NPCFLAGS:CREATURETYPE
            local objectGUID, tf, id, fl, df, lvl, hp, mhp,
                  x, y, z, face, fac, tg, sc, gb1, npcf, ct =
                string.match(part,
                    "^(0[xX]%x+):(%d+):(-?%d+):(%d+):(%d+):(-?%d+):(-?%d+):(-?%d+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+):(-?%d+):(0[xX]%x+):([%-%d%.]+):(%d+):(%d+):(-?%d+)$")
            if objectGUID then
                local struct = prev_by_guid[objectGUID]
                local is_new = not struct
                if is_new then struct = new_struct(objectGUID) end
                struct.Object = objectGUID
                struct.Guid = objectGUID

                -- Name: only resolve when missing or still a GUID placeholder.
                local need_name = is_new
                    or not struct.Name
                    or struct.Name == "nil"
                    or (type(struct.Name) == "string" and struct.Name:sub(1, 1) == "<")
                if need_name then
                    local unitName = UnitName and UnitName(objectGUID)
                    if not unitName then
                        local QDB = RaijinLab.QuestDB
                        if QDB and QDB.entry_name and id and id ~= 0 then
                            local okn, nm = pcall(QDB.entry_name, id, nil)
                            if okn and nm then unitName = nm end
                        end
                    end
                    if unitName and unitName == player_name then
                        -- do not publish self into lists
                        struct = nil
                    else
                        struct.Name = unitName or ("<" .. objectGUID .. ">")
                    end
                end
                if struct then
                    -- NORMALISE A REUSED STRUCT BEFORE WRITING INTO IT.
                    --
                    -- new_struct() builds Flags/DynamicFlags, but structs that
                    -- come back through prev_by_guid can predate that shape, and
                    -- indexing a nil field throws. This was invisible while
                    -- OmSnapshot returned "0" - the parser never ran. The moment
                    -- the snapshot carried real objects (185 of them) it threw 88
                    -- times: "attempt to index field 'DynamicFlags'". A latent
                    -- parser bug uncovered, not caused, by fixing the packer.
                    struct.Flags = struct.Flags or { value = 0, list = {} }
                    struct.DynamicFlags = struct.DynamicFlags or { value = 0, list = {} }
                    struct.Type = struct.Type or {
                        base_type = { name = "nil" },
                        sub_type = { id = 0, name = "nil" },
                    }
                    -- Snapshot fields (runtime authority - no per-object calls).
                    struct.Id = tonumber(id) or 0
                    struct.DynamicFlags.value = tonumber(df) or 0
                    struct._typeFlags = tonumber(tf) or 0
                    struct._flags = tonumber(fl) or 0
                    struct._level = tonumber(lvl) or 0
                    struct._hp = tonumber(hp) or 0
                    struct._mhp = tonumber(mhp) or 0
                    struct._posx, struct._posy, struct._posz = tonumber(x), tonumber(y), tonumber(z)
                    struct._facing = tonumber(face)
                    struct._faction = tonumber(fac)
                    struct._target = tg
                    struct._scale = tonumber(sc)
                    struct._goBytes1 = tonumber(gb1) or 0
                    struct._npcFlags = tonumber(npcf) or 0
                    struct._creatureType = tonumber(ct) or -1
                    local typeFlags = struct._typeFlags or 0
                    __om_seen = (__om_seen or 0) + 1
                    local __matched = false
                    local base = struct.Type.base_type
                    if MASK_PLAYER ~= 0 and bit.band(typeFlags, MASK_PLAYER) > 0 then
                        base.name = "Player"; __matched = true
                        players[#players + 1] = struct
                    elseif MASK_GO ~= 0 and bit.band(typeFlags, MASK_GO) > 0 then
                        base.name = "GameObject"; __matched = true
                        gameobjects[#gameobjects + 1] = struct
                    elseif MASK_UNIT ~= 0 and bit.band(typeFlags, MASK_UNIT) > 0
                        and (MASK_PLAYER == 0 or bit.band(typeFlags, MASK_PLAYER) == 0) then
                        base.name = "Unit"; __matched = true
                        npcs[#npcs + 1] = struct
                    elseif MASK_DO ~= 0 and bit.band(typeFlags, MASK_DO) > 0 then
                        base.name = "DynamicObject"; __matched = true
                        dynamicobjects[#dynamicobjects + 1] = struct
                    elseif MASK_AT ~= 0 and bit.band(typeFlags, MASK_AT) > 0 then
                        base.name = "AreaTrigger"
                        areatriggers[#areatriggers + 1] = struct
                    else
                        base.name = "Object"
                    end
                    if not __matched then
                        __om_unclassified = (__om_unclassified or 0) + 1
                        if not __om_example then
                            __om_example = string.format("%s flags=%s",
                                tostring(struct.Guid), tostring(typeFlags))
                        end
                    end
                    objects[#objects + 1] = struct
                    objects_by_guid[objectGUID] = struct
                    local nm = struct.Name
                    if nm then
                        local bucket = objects_by_name[nm]
                        if not bucket then
                            bucket = {}
                            objects_by_name[nm] = bucket
                        end
                        bucket[#bucket + 1] = struct
                    end
                    local idn = struct.Id or 0
                    local ib = objects_by_id[idn]
                    if not ib then
                        ib = {}
                        objects_by_id[idn] = ib
                    end
                    ib[#ib + 1] = struct
                end
            end
        end
    end

    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log_every then
        DL.log_every("om", 2.0, "om",
            "run count=%d players=%d npcs=%d gos=%d unclassified=%d%s",
            tonumber(count) or -1, #players, #npcs, #gameobjects,
            __om_unclassified or 0,
            __om_example and (" example=" .. __om_example) or "")
    end
    __om_seen, __om_unclassified, __om_example = 0, 0, nil

    RaijinLab.om.object_list.raw.players = players
    RaijinLab.om.object_list.raw.npcs = npcs
    RaijinLab.om.object_list.raw.gameobjects = gameobjects
    RaijinLab.om.object_list.dynamicobjects = dynamicobjects
    RaijinLab.om.object_list.areatriggers = areatriggers
    RaijinLab.om.object_list.objects = objects
    RaijinLab.om.object_list.indexes.guid = objects_by_guid
    RaijinLab.om.object_list.indexes.name = objects_by_name
    RaijinLab.om.object_list.indexes.id = objects_by_id
    RaijinLab.om.active = false

    RaijinLab.om.object_list.filtered = {}
    RaijinLab.om.object_list.interactable = {}
    -- Stagger processors across frames so one OM tick is not three full flag decodes.
    C_Timer.After(0, function() ObjectProcessor("players") end)
    C_Timer.After(0.02, function() ObjectProcessor("npcs") end)
    C_Timer.After(0.04, function() ObjectProcessor("gameobjects") end)
end

-- Menu / editor open: free frames for UI paint (set by Menu:Show/Hide too).
local function ui_open()
    if RaijinLab and RaijinLab._ui_open_hint then return true end
    local Menu = RaijinLab and RaijinLab.Menu
    if Menu and Menu.frame and Menu.frame.IsShown and Menu.frame:IsShown() then return true end
    local Ed = RaijinLab and RaijinLab.RotationEditor
    if Ed and Ed.frame and Ed.frame.IsShown and Ed.frame:IsShown() then return true end
    return false
end

function RaijinLab_SetUiOpenHint(on)
    RaijinLab = RaijinLab or {}
    RaijinLab._ui_open_hint = on and true or false
end

-- Adaptive OM rate: full fidelity when questing/grinding, lighter for
-- rotation-only (nameplates supply multi-dot tokens; full enum is overkill).
local function om_period()
    local M = RaijinLab and RaijinLab.Master
    if M and M.suppressed and M.suppressed() then
        if RaijinLab.tracker_toggle or (RaijinLabDB and RaijinLabDB.track_quest_objects) then
            return 0.25
        end
        return 1.5
    end
    if ui_open() then
        return 0.35
    end
    local d = RaijinLabDB and RaijinLabDB.modules
    if d and (d.quest or d.grind) then
        return 0.05 -- 20 Hz: quest needs dense NPC list
    end
    if d and d.combat then
        return 0.08
    end
    if d and d.rotation then
        -- Combat hostiles come from runtime NearbyHostiles (not this Lua OM).
        -- Keep Lua OM slow unless quest/gather needs object lists.
        return 0.35
    end
    if d and d.gather then
        return 0.15
    end
    return 0.25
end

local function ObjectManagerOnUpdate(self, elapsed)
    -- Suite-on warm window: skip entire Lua OM fan (GetUnitCount + per-object).
    -- Master freezes native OM and tears this frame down; if a stale frame
    -- survives, still fail-closed here.
    local M = RaijinLab.Master
    if M and M.in_suite_warm and M.in_suite_warm() then
        return
    end
    -- 2026-08-02 (idle power ~zero): when NOTHING consumes the Lua OM lists -
    -- master off and no tracker and no quest-object tracking - skip entirely.
    -- The rotation uses runtime NearbyHostiles/AuraSearch, not these lists.
    -- One OmSnapshot call is cheap, but zero calls when idle is cheaper.
    if M and M.suppressed and M.suppressed()
        and not RaijinLab.tracker_toggle
        and not (RaijinLabDB and RaijinLabDB.track_quest_objects) then
        return
    end
    if not self.last_time then
        self.last_time = 0
    end
    self.last_time = self.last_time + elapsed
    if self.last_time > om_period() then
        self.last_time = 0
        RunObjectManager()
    end
end

function RaijinLab:InitObjectManager()
    -- Never start Lua OM mid suite-on warm (caller may race timers).
    local M = RaijinLab.Master
    if M and M.in_suite_warm and M.in_suite_warm() then
        return
    end
    if RaijinLab.om.frames.object_manager then
        -- Already running - do not double-create frames.
        RaijinLab.om.running = true
        return
    end
    RaijinLab.om.frames = RaijinLab.om.frames or {}
    RaijinLab.om.frames.object_manager = CreateFrame("FRAME")
    RaijinLab.om.frames.object_manager:SetScript("OnUpdate", ObjectManagerOnUpdate)
    RaijinLab.om.frames.object_manager:RegisterEvent("PLAYER_ENTERING_WORLD")
    RaijinLab.om.frames.object_manager:SetScript("OnEvent", function(...) RaijinLab:ResetObjects() end)
    RaijinLab.om.running = true
end

function RaijinLab:DestroyObjectManager()
    local f = RaijinLab.om and RaijinLab.om.frames and RaijinLab.om.frames.object_manager
    if f then
        f:SetScript("OnUpdate", nil)
        f:SetScript("OnEvent", nil)
        f:UnregisterAllEvents()
    end
    if RaijinLab.om and RaijinLab.om.frames then
        RaijinLab.om.frames.object_manager = nil
    end
    if RaijinLab.om then RaijinLab.om.running = false end
end
