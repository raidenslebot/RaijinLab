RaijinLab.om = {}
-- object manager updated objects
RaijinLab.om.updated = false
-- object manager currently interating objects
RaijinLab.om.active = false
-- standard object list, split into object type
RaijinLab.om.object_list = {}
RaijinLab.om.object_list.raw = {}
RaijinLab.om.object_list.players = {}
RaijinLab.om.object_list.npcs = {}
RaijinLab.om.object_list.gameobjects = {}
RaijinLab.om.object_list.dynamicobjects = {}
RaijinLab.om.object_list.areatriggers = {}
-- filtered and quest related objects
RaijinLab.om.object_list.filtered = {}
RaijinLab.om.object_list.interactable = {}
-- fast access indexes
RaijinLab.om.object_list.indexes = {}
RaijinLab.om.object_list.indexes.guid = {}
RaijinLab.om.object_list.indexes.name = {}
RaijinLab.om.object_list.indexes.id = {}
-- frame access for object manager control
RaijinLab.om.frames = {}
RaijinLab.om.frames.object_manager = nil
RaijinLab.om.frames.process_objects = nil

function RaijinLab:GetObjectList()
    return RaijinLab.om.object_list.objects
end

function RaijinLab:oGetObjectCount()
    return #RaijinLab.om.object_list.objects, RaijinLab.om.updated, nil, nil
end

function RaijinLab:oGetObjectWithIndex(index)
    return RaijinLab.om.object_list.objects[index]
end

RaijinLab.GetNpcCountCache = {}
RaijinLab.fGetNpcCount = {}
RaijinLab.fGetNpcCount.use_cache = false
function RaijinLab:GetNpcCount(pointer, range)
    if not range then range = 40 end
    if pointer and range then
        RaijinLab.fGetNpcCount.use_cache = true
        local npcs = {}
        for i = 1, #RaijinLab.om.object_list.npcs do
            local obj = RaijinLab.om.object_list.npcs[i]
            local distance = RaijinLab:GetDistanceBetweenObjects(obj.Object, pointer)
            if obj and distance and distance <= range then
                table.insert(npcs, obj)
            end
        end
        RaijinLab.GetNpcCountCache = npcs
        return #npcs
    end
    RaijinLab.fGetNpcCount.use_cache = false
    return #RaijinLab.om.object_list.npcs
end

function RaijinLab:GetNpcWithIndex(index)
    if RaijinLab.fGetNpcCount.use_cache then
        return RaijinLab.GetNpcCountCache[index]
    end
    return RaijinLab.om.object_list.npcs[index]
end

RaijinLab.GetPlayerCountCache = {}
RaijinLab.fGetPlayerCount = {}
RaijinLab.fGetPlayerCount.use_cache = false
function RaijinLab:GetPlayerCount(pointer, range)
    if not range then range = 40 end
    if pointer and range then
        RaijinLab.fGetPlayerCount.use_cache = true
        local players = {}
        for i = 1, #RaijinLab.om.object_list.players do
            local obj = RaijinLab.om.object_list.players[i]
            local distance = RaijinLab:GetDistanceBetweenObjects(obj.Object, pointer)
            if obj and distance and distance <= range then
                table.insert(players, obj)
            end
        end
        RaijinLab.GetPlayerCountCache = players
        return #players
    end
    RaijinLab.fGetPlayerCount.use_cache = false
    return #RaijinLab.om.object_list.players
end

function RaijinLab:GetPlayerWithIndex(index)
    if RaijinLab.fGetPlayerCount.use_cache then
        return RaijinLab.GetPlayerCountCache[index]
    end
    return RaijinLab.om.object_list.players[index]
end

RaijinLab.GetGameObjectCountCache = {}
RaijinLab.fGetGameObjectCount = {}
RaijinLab.fGetGameObjectCount.use_cache = false
function RaijinLab:GetGameObjectCount(pointer, range)
    if not range then range = 40 end
    if pointer and range then
        RaijinLab.fGetGameObjectCount.use_cache = true
        local gameobjects = {}
        for i = 1, #RaijinLab.om.object_list.gameobjects do
            local obj = RaijinLab.om.object_list.gameobjects[i]
            local distance = RaijinLab:GetDistanceBetweenObjects(obj.Object, pointer)
            if obj and distance and distance <= range then
                table.insert(gameobjects, obj)
            end
        end
        RaijinLab.GetGameObjectCountCache = gameobjects
        return #gameobjects
    end
    RaijinLab.fGetGameObjectCount.use_cache = false
    return #RaijinLab.om.object_list.gameobjects
end

function RaijinLab:GetGameObjectWithIndex(index)
    if RaijinLab.fGetGameObjectCount.use_cache then
        return RaijinLab.GetGameObjectCountCache[index]
    end
    return RaijinLab.om.object_list.gameobjects[index]
end

RaijinLab.GetDynamicObjectCountCache = {}
RaijinLab.fGetDynamicObjectCount = {}
RaijinLab.fGetDynamicObjectCount.use_cache = false
function RaijinLab:GetDynamicObjectCount(pointer, range)
    if not range then range = 40 end
    if pointer and range then
        RaijinLab.fGetDynamicObjectCount.use_cache = true
        local dynamicobjects = {}
        for i = 1, #RaijinLab.om.object_list.dynamicobjects do
            local obj = RaijinLab.om.object_list.dynamicobjects[i]
            local distance = RaijinLab:GetDistanceBetweenObjects(obj.Object, pointer)
            if obj and distance and distance <= range then
                table.insert(dynamicobjects, obj)
            end
        end
        RaijinLab.GetDynamicObjectCountCache = dynamicobjects
        return #dynamicobjects
    end
    RaijinLab.fGetDynamicObjectCount.use_cache = false
    return #RaijinLab.om.object_list.dynamicobjects
end

function RaijinLab:GetDynamicObjectWithIndex(index)
    if RaijinLab.fGetDynamicObjectCount.use_cache then
        return RaijinLab.GetDynamicObjectCountCache[index]
    end
    return RaijinLab.om.object_list.dynamicobjects[index]
end

RaijinLab.GetAreaTriggerCountCache = {}
RaijinLab.fGetAreaTriggerCount = {}
RaijinLab.fGetAreaTriggerCount.use_cache = false
function RaijinLab:GetAreaTriggerCount(pointer, range)
    if not range then range = 40 end
    if pointer and range then
        RaijinLab.fGetAreaTriggerCount.use_cache = true
        local areatriggers = {}
        for i = 1, #RaijinLab.om.object_list.areatriggers do
            local obj = RaijinLab.om.object_list.areatriggers[i]
            local distance = RaijinLab:GetDistanceBetweenObjects(obj.Object, pointer)
            if obj and distance and distance <= range then
                table.insert(areatriggers, obj)
            end
        end
        RaijinLab.GetAreaTriggerCountCache = areatriggers
        return #areatriggers
    end
    RaijinLab.fGetAreaTriggerCount.use_cache = false
    return #RaijinLab.om.object_list.areatriggers
end

function RaijinLab:GetAreaTriggerWithIndex(index)
    if RaijinLab.fGetAreaTriggerCount.use_cache then
        return RaijinLab.GetAreaTriggerCountCache[index]
    end
    return RaijinLab.om.object_list.areatriggers[index]
end

-- overwrite handsfree / ucs API
-- avoids conflicts and adds caching
function RaijinLab:OverwriteAPI()
    print("Overwriting HF API!")
    _G.GetObjectCount = function() return RaijinLab:oGetObjectCount() end
    _G.GetObjectWithIndex = function(...) return RaijinLab:oGetObjectWithIndex(...).Object end
    _G.GetPlayerCount = function(...) return RaijinLab:GetPlayerCount(...) end
    _G.GetPlayerWithIndex = function(...) return RaijinLab:GetPlayerWithIndex(...).Object end
    _G.GetNpcCount = function(...) return RaijinLab:GetNpcCount(...) end
    _G.GetNpcWithIndex = function(...) return RaijinLab:GetNpcWithIndex(...).Object end
    _G.GetGameObjectCount = function(...) return RaijinLab:GetGameObjectCount(...) end
    _G.GetGameObjectWithIndex = function(...) return RaijinLab:GetGameObjectWithIndex(...).Object end
    _G.GetDynamicObjectCount = function(...) return RaijinLab:GetDynamicObjectCount(...) end
    _G.GetDynamicObjectWithIndex = function(...) return RaijinLab:GetDynamicObjectWithIndex(...).Object end
    _G.GetAreaTriggerCount = function(...) return RaijinLab:GetAreaTriggerCount(...) end
    _G.GetAreaTriggerWithIndex = function(...) return RaijinLab:GetAreaTriggerWithIndex(...).Object end
end

local api_override = CreateFrame("FRAME")
api_override:SetScript("OnUpdate", function()
    if GetObjectCount then
    RaijinLab:OverwriteAPI()
    api_override:SetScript("OnUpdate", nil)
    api_override = nil
    return
end
end)


function RaijinLab:GetFilteredObjects()
return RaijinLab.om.object_list.filtered
end

function RaijinLab:GetInteractableObjects()
return RaijinLab.om.object_list.interactable
end

function RaijinLab:AddObjectToTrackerByIdOrName(id, list)
if not list then list = "default" end
if RaijinLabDB.objects_to_track[list] == nil then return end
RaijinLabDB.objects_to_track[list][id] = true
end

function RaijinLab:RemoveObjectFromTrackerByIdOrName(id, list)
if not list then list = "default" end
if RaijinLabDB.objects_to_track[list] == nil then return end
RaijinLabDB.objects_to_track[list][id] = nil
end

function RaijinLab:EnableObjectList(name)
RaijinLabDB.enabled_lists[name] = true
end

function RaijinLab:DisableObjectList(name)
RaijinLabDB.enabled_lists[name] = nil
end

function RaijinLab:AddObjectList(name, items)
RaijinLabDB.objects_to_track[name] = items
end

function RaijinLab:RemoveObjectList(name)
RaijinLabDB.objects_to_track[name] = nil
RaijinLabDB.enabled_lists[name] = nil
end

function RaijinLab:ObjectListEnabled(name)
return RaijinLabDB.enabled_lists[name] ~= nil
end

function RaijinLab:ObjectListExists(name)
return RaijinLabDB.objects_to_track[name] ~= nil
end

function RaijinLab:GetObjManagerFrame()
return RaijinLab.om.frames.object_manager
end

-- POPULATE THE SNAPSHOT THE ENGINE ACTUALLY READS.
--
-- `RaijinLab.om.object_list.npcs` was initialised to {} at the top of this file
-- and then NEVER WRITTEN TO ANYWHERE. Every other reference in the codebase is a
-- read: QuestOM.nearest_giver, the objective scan, Looter, the obstacle layer.
-- So the engine's view of the world was permanently empty while the runtime
-- enumerated ~94 units, and the bot was blind to every NPC - no quest givers, no
-- kill objectives ("found=none"), which is why it fell through to a
-- belief-field beeline. World.collect_from_om() does build a list, but it
-- RETURNS one and only the Gatherer calls it; it never fed this table.
--
-- Throttled because consumers call it per tick. Entries carry the fields the
-- readers use (Guid/Object/Name/Id/x/y/z); `Info` is deliberately absent and
-- every consumer already guards `s.Info and s.Info.Unit`, so its absence reads
-- as "unknown", never as a false negative.
function RaijinLab.om.refresh(force)
    local t = (GetTime and GetTime()) or 0
    if not force and RaijinLab.om._snap_t and (t - RaijinLab.om._snap_t) < 0.5 then
        return RaijinLab.om.object_list.npcs
    end
    RaijinLab.om._snap_t = t
    local L = RaijinLab.om.object_list
    -- SAFETY NET ONLY. The object manager (Manager.lua, 10Hz) is the real
    -- producer and its entries are richer - Name, Info.Unit, Info.Quest -
    -- which consumers use. Never overwrite a populated list with these
    -- leaner ones; only fill the gap when the manager has produced nothing,
    -- which is exactly the state that made the engine blind.
    if L.npcs and #L.npcs > 0 then return L.npcs end
    if not (RaijinLab.RuntimeCall and RaijinLab.HasRuntime and RaijinLab:HasRuntime()) then
        return L.npcs
    end
    local n = tonumber(RaijinLab:RuntimeCall("GetUnitCount")) or 0
    if n <= 0 then return L.npcs end
    local npcs, byguid = {}, {}
    for i = 1, (n > 256 and 256 or n) do
        local ok, g = pcall(RaijinLab.RuntimeCall, RaijinLab, "GetUnitWithIndex", i)
        if ok and g then
            local e = { Guid = g, Object = g }
            if RaijinLab.ObjectId then
                local oki, id = pcall(RaijinLab.ObjectId, RaijinLab, g)
                if oki then e.Id = id end
            end
            if RaijinLab.ObjectPosition then
                local okp, x, y, z = pcall(RaijinLab.ObjectPosition, RaijinLab, g)
                if okp and x then e.x, e.y, e.z = x, y, z end
            end
            npcs[#npcs + 1] = e
            byguid[tostring(g)] = e
        end
    end
    -- Only replace on a non-empty read: a single failed sweep must not blind
    -- every consumer for the tick, which is the failure mode being fixed here.
    if #npcs > 0 then
        L.npcs = npcs
        L.indexes = L.indexes or {}
        L.indexes.guid = byguid
    end
    return L.npcs
end
