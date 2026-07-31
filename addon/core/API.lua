local cache = { pop_time = 0.020 }
cache.GetObjectCount = { last_ran = 0 }
cache.GetObjectWithIndex = {}
cache.GetNpcCount = { last_ran = 0 }
cache.GetNpcWithIndex = {}
cache.GetPlayerCount = { last_ran = 0 }
cache.GetPlayerWithIndex = {}
cache.GetGameObjectCount = { last_ran = 0 }
cache.GetGameObjectWithIndex = {}
cache.GetDynamicObjectCount = { last_ran = 0 }
cache.GetDynamicObjectWithIndex = {}
cache.GetAreaTriggerCount = { last_ran = 0 }
cache.GetAreaTriggerWithIndex = {}
cache.GetMissileCount = { last_ran = 0 }
cache.GetMissileWithIndex = {}
cache.ObjectIsQuestObjective = {}
RaijinLab.QuestRelationMap = {}
-- Stock movement globals kept only as last-resort fallbacks if runtime offline.
-- Prefer RaijinLab.Actions.* which never taints.
RaijinLab.oMoveForwardStart = MoveForwardStart
RaijinLab.oMoveBackwardStart = MoveBackwardStart
RaijinLab.oStrafeLeftStart = StrafeLeftStart
RaijinLab.oStrafeRightStart = StrafeRightStart
RaijinLab.oJumpOrAscendStart = JumpOrAscendStart
RaijinLab.oCameraOrSelectOrMoveStart = CameraOrSelectOrMoveStart
RaijinLab.quests = {}
RaijinLab.enums = {}

-- Runtime bridge. Stock IsLinuxClient is a Blizzard nil-stub - only use a
-- candidate that answers GetRuntimeVersion with our "1.x..." string.
local function is_our_bridge(fn)
    if type(fn) ~= "function" then return false end
    local ok, ver = pcall(fn, "GetRuntimeVersion")
    return ok and type(ver) == "string" and ver:match("^1%.") ~= nil
end

local function RLCall(...)
    if is_our_bridge(RaijinLab_Runtime) then
        return RaijinLab_Runtime(...)
    end
    if is_our_bridge(IsLinuxClient) then
        return IsLinuxClient(...)
    end
    return nil
end



function printf(...) print(string.format(...)) end
function pack(...)
    return {n = select("#", ...), ...}
end
function subrange(t, first, last)
    local sub = {}
    for i = first, last do
        sub[#sub + 1] = t[i]
    end
    return sub
end
function htostr(str)
    return (string.gsub(str, '..', function (cc)
        return string.char(tonumber(cc, 16))
    end))
end
function tc(t, number)
    if number then
        local c = {}
        local x = 1
        for i = #t, 1, - 1 do
            c[x] = t[i]
            x = x + 1
        end
        t = c
    end
    if number then
        return tonumber(table.concat(t, ""), 16)
    end
    return table.concat(t, "")
end
local function table_invert(t)
    local s = {}
    for k, v in pairs(t) do
        s[v] = k
    end
    return s
end
function split(str, sep)
    local result = {}
    local regex = ("([^%s]+)"):format(sep)
    for each in str:gmatch(regex) do
        table.insert(result, each)
    end
    return result
end
--   _____
--  /  __ \
--  | /  \/ ___  _ __ ___  _ __ ___   ___  _ __
--  | |    / _ \| '_ ` _ \| '_ ` _ \ / _ \| '_ \
--  | \__/\ (_) | | | | | | | | | | | (_) | | | |
--  \____/\___/|_| |_| |_|_| |_| |_|\___/|_| |_|

-- Gets the base directory path of app storage.
function RaijinLab:GetAppStorageDirectory()
    return RLCall("GetAppStorageDirectory")
end

-- Gets the app base directory path.
function RaijinLab:GetAppDirectory()
    return RLCall("GetAppDirectory")
end

-- Gets the app username.
function RaijinLab:GetAppUsername()
    return RLCall("GetAppUsername")
end

-- Gets the WoW base directory path.
function RaijinLab:GetWoWDirectory()
    return RLCall("GetWoWDirectory")
end

-- Gets the value of the system variable previously set by SetSystemVar.
function RaijinLab:GetSystemVar(name)
    return RLCall("GetSystemVar", name)
end

-- Sets a system variable.
function RaijinLab:SetSystemVar(name, value)
    return RLCall("SetSystemVar", name, value)
end

-- Passive chatter. Always lands in the Debug tab (DebugLog). Mirrored to chat
-- only when chat_verbose is on. DebugLog redefines this after it loads; this
-- stub covers any early call before DebugLog.lua runs.
function RaijinLab:Chatter(msg)
    if self.DebugLog and self.DebugLog.Log then
        return self.DebugLog.Log("chat", "%s", tostring(msg))
    end
    if self.chat_verbose then print("|cff7ec8e3RaijinLab|r " .. tostring(msg)) end
end

-- Structured log: always Debug tab; chat when verbose. Preferred over print().
function RaijinLab:Log(cat, fmt, ...)
    if self.DebugLog and self.DebugLog.Log then
        return self.DebugLog.Log(cat, fmt, ...)
    end
    if self.chat_verbose then
        local body = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, s = pcall(string.format, tostring(fmt), ...)
            if ok then body = s end
        end
        print("|cff7ec8e3RaijinLab|r [" .. tostring(cat or "log") .. "] " .. body)
    end
end

-- |  ___(_) |
-- | |_   _| | ___
-- |  _| | | |/ _ \
-- | |   | | |  __/
-- \_|   |_|_|\___|

-- Checks if a file exists.
function RaijinLab:FileExists(path)
    if not path then return end
    return RLCall("FileExists", "RaijinLabRuntime", path)
end
-- Reads all text from a file.
function RaijinLab:ReadFile(path, encoding)
    if not path then return end
    if not encoding then encoding = nil end
    return RLCall("ReadFile", path, encoding)
end
-- Writes all text to a file (overwrites).
function RaijinLab:WriteFile(path, content)
    if not path then return end
    RLCall("WriteFile", path, content)
end
-- Appends text to a file (creates if absent). Runtime 1.8.3+; returns truthy on
-- success so callers can detect an older runtime and fall back.
function RaijinLab:AppendFile(path, content)
    if not path or not content then return end
    return RLCall("AppendFile", path, content)
end
-- Checks if a directory exists.
function RaijinLab:DirectoryExists(path)
    return RLCall("DirectoryExists", "RaijinLabRuntime", path)
end
-- Creates a directory.
function RaijinLab:CreateDirectory(path)
    if not path then return end
    return RLCall("CreateDirectory", "RaijinLabRuntime", path)
end
-- Gets all file names in a specific directory. Remind the path must end
-- with wildcards. e.g C:\Windows\*.lua
function RaijinLab:GetDirectoryFiles(path)
    if not path then return end
    return RLCall("GetDirectoryFiles", "RaijinLabRuntime", path)
end
-- Gets all sub folder names in a specific directory.
function RaijinLab:GetDirectoryFolders(path)
    if not path then return end
    return RLCall("GetDirectoryFolders", "RaijinLabRuntime", path)
end

-- function RaijinLab:ReadQuestCacheAsBytes()
--     local function chunk(text)
--         local res = {}
--         for i = 1, #text, 2 do
--             table.insert(res, text:sub(i, i + 2 - 1))
--         end
--         return res
--     end
--     local results = RaijinLab:ReadFile(RaijinLab:GetWoWDirectory() .. "\\Cache\\WDB\\enUS\\questcache.wdb", 2)
--     return chunk(results)
-- end
-- function RaijinLab:ReadQuestCache()
--     local cache_bytes = RaijinLab:ReadQuestCacheAsBytes()
--     -- skip first 24 bytes
--     local quest_bytes = subrange(cache_bytes, 25, #cache_bytes + 1)
--
--     local index = 1
--     while index <= #quest_bytes do
--         -- get the first 8 bytes of the record
--         local record_info = subrange(quest_bytes, index, index + 8)
--         -- advance index past the record info
--         index = index + 8
--         -- convert record id and length to int
--         local record_id = tc(subrange(record_info, 1, 4), true)
--         local length = tc(subrange(record_info, 5, 8), true)
--
--         if length and length > 0 then
--             local record = subrange(quest_bytes, index, length)
--
--             local quest_record = {
--                 id = nil, -- bytes 0-4
--                 QuestType = nil, --bytes 4-8
--                 Quest_UNK_27075 = nil, --bytes 8-12 -- Unknown, but seems to frequently mirror SuggestedGroupNum. Theory: Maximum party size number for LFG Tool to create a group
--                 QuestPackageID = nil, -- 12-16               -- FK to QuestPackageItem.db2
--                 QuestSortID = nil, -- 16-20                   -- When QuestSortID is greater than 0, FK to AreaTable.db2 = nil,otherwise, FK to QuestSort.db2
--                 QuestInfoID = nil, -- 20-24                  -- FK to QuestInfo.db2
--                 SuggestedGroupNum = nil, --24-28
--                 RewardNextQuest = nil, --28-32               -- Next id in the chain = nil,sometimes blank when it shouldn't be because chains are often not linear and require multiple quests to continue at certain points
--                 RewardXPDifficulty = nil, --32-36             -- The column of QuestXp to use
--                 RewardXPMultiplier = nil, --36-40 float         -- Multiplier applied to the value retrieved from the field above
--                 RewardMoney = nil, --40-44                   -- Precomputed final money value based on player level at the time of caching = nil,not very useful unless you can ensure consistent player levels
--                 RewardMoneyDifficulty = nil, --44-48         -- The column of QuestMoneyReward to use
--                 RewardMoneyMultiplier = nil, --48-52      -- Multiplier applied to the value retrieved from the field above
--                 RewardBonusMoney = nil, --52-56             -- Bonus money rewarded if completed at max level
--                 RewardDisplaySpell = nil, --56-68
--                 RewardSpell = nil, --68-72
--                 RewardHonor = nil, --72-76                  -- Amount of honor rewarded by the quest
--                 RewardHonorKill = nil, --76-80         -- Multiplier applied to honor rewarded by the quest (or to kills during it? unknown exactly)
--                 RewardArtifactXPDifficulty = nil, --80-84    -- The column of ArtifactQuestXp to use
--                 RewardArtifactXPMultiplier = nil, --8488  -- Multiplier applied to the value retrieved from the field above
--                 RewardArtifactCategoryID = nil, --88-92
--                 ProvidedItem = nil, --92-96   -- Item linked to the quest, usually destroying it will force the quest to abandon
--                 Flags = nil, --96-100
--                 Flags2 = nil, -- 100-104
--                 Flags3 = nil, -- 104-108
--                 RewardFixedItems = nil, --108-140
--                 ItemDrop = nil -- 140-172
--                 RewardChoiceItems, -- 172 - 244
--                 POIContinent = nil, -- 244-248
--                 POIx = nil, --248-252
--                 POIy = nil, --252-260
--                 POIPriority = nil, --260-264
--                 RewardTitle = nil, --264-268
--                 RewardArenaPoints = nil, --268-272
--                 RewardSkillLineID = nil, --272-276
--                 RewardNumSkillUps = nil, --276-280
--                 PortraitGiverDisplayID = nil, --280-284
--                 BFA_UnkDisplayID = nil, --284-288
--                 PotraitTurnInDisplayID = nil, -- 288-292
--                 RewardFaction = nil, --292-348
--                 RewardFactionFlags = nil, --348-352
--                 RewardCurrency = nil, --352-386
--                 int AcceptedSoundKitID = nil, --386-390
--                 int AcceptedSoundKitID = nil, --390-394
--                 int CompleteSoundKitID = nil, --394-398
--                 int AreaGroupID = nil, --398-402
--                 int TimeAllowed = nil, --402-406
--                 int NumObjectives = nil, --406-410
--                 uint64 RaceFlags = nil, --406-418
--                 uint QuestRewardID = nil, --418-422
--                 uint ExpansionID = nil, --422-426
--                 uint B30993_Int_1; --418-422                 -- Unknown - only set on Warfront-related quests; has values of 12, 113, 114, and 115
--                 uint B31984_Int_1; --422-426
--                 BitFields = nil, --444-453
--
--             }
--
--             quest_record.id = tc(subrange(record, 1, 4), true)
--             quest_record.QuestType = tc(subrange(record, 5, 8), true)
--             quest_record.QuestSortID = tc(subrange(record, 17, 20), true)
--             quest_record.QuestInfoID = tc(subrange(record, 21, 24), true)
--             quest_record.RewardNextQuest = tc(subrange(record, 29, 32), true)
--             quest_record.ProvidedItem = tc(subrange(record, 85, 88), true)
--
--             return quest_record
--         end
--
--         -- print("Found record: [" .. record_id .. "] Len: [" .. length .. "]")
--         -- set index past the record to the next record_info
--         index = index + length
--     end
-- end

-- ___  ___      _   _
-- |  \/  |     | | | |
-- | .  . | __ _| |_| |__
-- | |\/| |/ _` | __| '_ \
-- | |  | | (_| | |_| | | |
-- \_|  |_/\__,_|\__|_| |_|

-- Gets all spanning circles of a specific radius over certain weighted points.
function RaijinLab:GetAllSpanningCircles(radius, minWeight, points)
    return RLCall("GetAllSpanningCircles", radius, minWeight, points)
end

-- Gets the distance between two positions in 3D.
function RaijinLab:GetDistanceBetweenPositions(x1, y1, z1, x2, y2, z2)
    return RLCall("GetDistanceBetweenPositions", x1, y1, z1, x2, y2, z2)
end

-- Gets the distance between two objects in 3D (center-to-center yards).
-- Prefer Lua-side Distance() - the runtime export is a stub (always 0) on
-- current builds. Kept for API compatibility.
function RaijinLab:GetDistanceBetweenObjects(object1, object2)
    if not object1 or not object2 then return nil end
    local d = RaijinLab:Distance(object1, object2)
    if d then return d end
    local raw = RLCall("GetDistanceBetweenObjects", object1, object2)
    raw = tonumber(raw)
    if raw and raw > 0 then return raw end
    return nil
end

-- Gets the position from object 1 to object 2.
function RaijinLab:GetPositionBetweenObjects(object1, object2, dist)
    if not object1 or not object2 then return 0 end
    return RLCall("GetPositionBetweenObjects", object1, object2, dist)
end

-- Gets the position from position 1 to position 2.
function RaijinLab:GetPositionBetweenPositions(x1, y1, z1, x2, y2, z2, distance)
    return RLCall("GetPositionBetweenPositions", x1, y1, z1, x2, y2, z2, distance)
end

-- Gets the position relative to a specific position.
function RaijinLab:GetPositionFromPosition(x1, y1, z1, distance, facing, pitch)
    return RLCall("GetPositionFromPosition", x1, y1, z1, distance, facing, pitch)
end

-- Gets the angles (facing & pitch) between two objects.
function RaijinLab:GetAnglesBetweenObjects(object1, object2)
    if not object1 or not object2 then return 0 end
    return RLCall("GetAnglesBetweenObjects", object1, object2)
end

-- ___  ___
-- |  \/  |
-- | .  . | ___ _ __ ___   ___  _ __ _   _
-- | |\/| |/ _ \ '_ ` _ \ / _ \| '__| | | |
-- | |  | |  __/ | | | | | (_) | |  | |_| |
-- \_|  |_/\___|_| |_| |_|\___/|_|   \__, |
--                                    __/ |
--                                   |___/

-- Reads a value at a specific memory offset/rva in a specific memory module.
-- module (string): The name of the memory module. nil for "Wow.exe" aka the main module.
-- offset (number): The offset/rva in the memory module to read.
-- type (number): The type of the value. Check GetValueTypesTable().
-- value (number): The result value. nil if the memory address is not found.
function RaijinLab:ReadMemory(module, offset, type)
    return RLCall("ReadMemory", module, offset, type)
end

-- Gets the offset of a memory address in a specific module.
-- module (string): The name of the memory module. nil for "Wow.exe" aka the main module.
-- address (number): The absolute memory address.
-- offset (number): The result offset. nil if the memory address is not found.
function RaijinLab:GetMemoryOffset(module, address)
    return RLCall("GetMemoryOffset", module, address)
end

-- ___  ____
-- |  \/  (_)
-- | .  . |_ ___  ___
-- | |\/| | / __|/ __|
-- | |  | | \__ \ (__
-- \_|  |_/_|___/\___|

-- Gets the pressed state of a specific key.
function RaijinLab:GetKeyState(key)
    return RLCall("GetKeyState", key)
end

-- Plays a specific sound WAV/MP3 file once.
function RaijinLab:PlaySoundFile(path)
    return RLCall("PlaySoundFile", path)
end

-- Loads a Lua script with a name by engine into a function.
function RaijinLab:LoadScript(name, script)
    return RLCall("LoadScript", name, script)
end

-- Runs a Lua script with a name by engine.
function RaijinLab:RunScript(name, script)
    return RLCall("RunScript", name, script)
end

-- Adds a custom script (indexed by name) that gets loaded side by side
-- with the engine modules (Primary and Secondary). Loaded in GLUE
function RaijinLab:SetCustomScript(name, script)
    return RLCall("SetCustomScript", name, script)
end


--  _   _      _                      _
-- | \ | |    | |                    | |
-- |  \| | ___| |___      _____  _ __| | __
-- | . ` |/ _ \ __\ \ /\ / / _ \| '__| |/ /
-- | |\  |  __/ |_ \ V  V / (_) | |  |   <
-- \_| \_/\___|\__| \_/\_/ \___/|_|  |_|\_\

-- -- The request info.
-- info = {
--   -- string: The request URL.
--   Url = "https:--www.microsoft.com/",
--   -- [OPTIONAL] string: The request method, can be "GET", "POST", "PUT" or "DELETE".
--   Method = "POST",
--   -- [OPTIONAL] string: The additional request headers.
--   Headers = "Content-Type: application/json\r\nX-Custom: test",
--   -- [OPTIONAL] string: The request body, only used Method is "POST" or "PUT".
--   Body = "{\"test\": 123}",
--   -- [OPTIONAL] string: The pinned HTTPs server certificate as a protection for packet sniffing. If provided, the server certificate must match it or the HTTP request would fail with status "INVALID_CERTIFICATE".
--   Certificate = "PINNED CERTIFICATE",
--   -- [OPTIONAL] function: The callback function RaijinLab:when the status of the request is updated.
--   Callback = function(request, status) ... end,
-- }
-- -- The HTTP request ID if sent successfully, for querying HTTP response later.
-- request = "abc123"
function RaijinLab:SendHttpRequest(info)
    return RLCall("SendHttpRequest", info)
end

-- -- The HTTP request ID previously sent.
-- request = "abc123"
-- -- The current status of the HTTP request, can be:
-- -- "REQUESTING": The request is still on the way.
-- -- "REQUEST_FAILED": The request is terminated due to failures.
-- -- "INVALID_CERTIFICATE": The request is terminated due to invalid HTTPs certificate.
-- -- "RESPONDING": Downloading response after the request is sent.
-- -- "RESPONSE_HEADERS_FAILED": The response download is terminated while fetching response headers.
-- -- "RESPONSE_BODY_FAILED": The response download is terminated while fetching response body.
-- -- "SUCCESS": The response is received and everything about the HTTP request is done.
-- status = "CONNECTING"
-- -- The response data, available if status is "SUCCESS"
-- response = {
--   -- number: The HTTP response status code.
--   Code = 200,
--   -- string: The HTTP response headers.
--   Headers = "HTTP/1.1 200 OK...",
--   -- string: The HTTP response body.
--   Body = "...",
--   -- string: The actual server certificate if the request is HTTPs, which can be used for pinning.
--   Certificate = "SERVER CERTIFICATE",
-- }
function RaijinLab:ReceiveHttpRequest(request)
    return RLCall("ReceiveHttpRequest", request)
end

-- -- The websocket info.
-- info = {
--   -- string: The websocket URL. (Use http(s) instead of ws(s))
--   Url = "https:--echo.websocket.org",
--   -- [OPTIONAL] string: The additional request headers.
--   Headers = "Content-Type: application/json\r\nX-Custom: test",
--   -- [OPTIONAL] string: The pinned HTTPs server certificate as a protection for packet sniffing. If provided, the server certificate must match it or the websocket connection would fail with status "INVALID_CERTIFICATE".
--   Certificate = "PINNED CERTIFICATE",
--   -- [OPTIONAL] function: The callback function RaijinLab:when the status of the connection is updated, which can be any one of "CONNECTING", "CONNECTION_FAILED", "INVALID_CERTIFICATE", "CONNECTED", "CLOSING", "CLOSED".
--   ConnectCallback = function(connection, status) ... end,
--   -- [OPTIONAL] function: The callback function RaijinLab:when a piece of data is sent over the connection. (Only string data is supported)
--   SendCallback = function(connection, data) ... end,
--   -- [OPTIONAL] function: The callback function RaijinLab:when a piece of data is received over the connection. (Only string data is supported)
--   ReceiveCallback = function(connection, data) ... end
-- }
-- -- The websocket connection ID if sent successfully.
-- connection = "abc123"
function RaijinLab:ConnectWebsocket(info)
    return RLCall("ConnectWebsocket", info)
end

-- Closes an existing websocket connection.
function RaijinLab:CloseWebSocket(info)
    return RLCall("CloseWebSocket", info)
end

-- Sends a piece of string data over an existing websocket connection.
function RaijinLab:SendWebsocketData(connection, data)
    return RLCall("SendWebsocketData", connection, data)
end

--   ___       _   _
--  / _ \     | | (_)
-- / /_\ \ ___| |_ _  ___  _ __
-- |  _  |/ __| __| |/ _ \| '_ \
-- | | | | (__| |_| | (_) | | | |
-- \_| |_/\___|\__|_|\___/|_| |_|

-- Clicks a world position.
function RaijinLab:ClickPosition(x, y, z)
    RLCall("ClickPosition", x, y, z)
end

-- Faces a horizontal direction, in radian.
function RaijinLab:FaceDirection(angle, update)
    RLCall("FaceDirection", angle, update)
end

-- Sets the player vertical pitch, in radian.
function RaijinLab:SetPitch(angle)
    if not angle then return end
    return RLCall("SetPitch", angle)
end

-- Moves the player via keyboard Navigator (CTM / runtime MoveTo forbidden).
function RaijinLab:MoveTo(x, y, z, instantTurn)
    if self.Actions and self.Actions.MoveTo then
        return self.Actions.MoveTo(x, y, z)
    end
    return false
end

-- Interacts with an object - runtime only (never FrameScript InteractUnit).
function RaijinLab:ObjectInteract(object)
    if not object then return end
    if RaijinLab.Actions then return RaijinLab.Actions.Interact(object) end
    return RLCall("Interact", object)
end

--   ___
--  / _ \
-- / /_\ \_   _ _ __ __ _
-- |  _  | | | | '__/ _` |
-- | | | | |_| | | | (_| |
-- \_| |_/\__,_|_|  \__,_|

-- Gets the count of auras on a specific unit, optionally filtered by spell ID.
function RaijinLab:GetAuraCount(unit, spellId)
    if not unit then return end
    if spellId then
        return RLCall("GetAuraCount", spellId)
    end
    return RLCall("GetAuraCount", unit)
end

-- Gets the info of a specific aura, saved by the most recent call to GetAuraCount().
function RaijinLab:GetAuraWithIndex(index, detailed)
    if detailed then
        return RLCall("GetAuraWithIndex", index, detailed)
    end
    return RLCall("GetAuraWithIndex", index)
end

-- ______ _            _         _____         _
-- | ___ \ |          | |       |_   _|       | |
-- | |_/ / | __ _  ___| | ________| | ___  ___| |__
-- | ___ \ |/ _` |/ __| |/ /______| |/ _ \/ __| '_ \
-- | |_/ / | (_| | (__|   <       | |  __/ (__| | | |
-- \____/|_|\__,_|\___|_|\_\      \_/\___|\___|_| |_|

-- Sets the current camera distance maximum. If nil, restore original setting.
function RaijinLab:SetCameraDistanceMax(distance)
    return RLCall("SetCameraDistanceMax", distance)
end

-- Sets the engine allowed climb angle, in radian. If nil, restore original setting.
function RaijinLab:SetClimbAngle(angle)
    return RLCall("SetClimbAngle", angle)
end

-- Sets a CVar without system limitation.
function RaijinLab:SetCVarEx(name, value)
    return RLCall("SetCVarEx", name, value)
end

-- Sets the current nameplate visible distance maximum. If nil, restore original setting.
function RaijinLab:SetNameplateDistanceMax(distance)
    return RLCall("SetNameplateDistanceMax", distance)
end

-- Stops the current falling of the character right now.
function RaijinLab:StopFalling()
    return RLCall('StopFalling')
end

function RaijinLab:IsFlyingModeEnabled()
    return RLCall('IsFlyingModeEnabled')
end

function RaijinLab:EnableFlyingMode(toggle)
    if toggle then
        RaijinLab:StopFalling()
    else
        if not RaijinLab:IsFlyingModeEnabled() then return end
    end
    return RLCall('EnableFlyingMode', toggle)
end

-- Gets the current no-clip mode flags, which is a sum of:
-- 0: none 1: building 2: static object 4: dynamic object
function RaijinLab:GetNoClipModes()
    return RLCall("GetNoClipModes")
end

-- Sets the current no-clip mode flags. Check the enum above.
function RaijinLab:SetNoClipModes(modes)
    return RLCall("SetNoClipModes", modes)
end

function RaijinLab:UnlockMovement()
    if RaijinLab.movement_locked then
        MoveForwardStart = RaijinLab.oMoveForwardStart
        MoveBackwardStart = RaijinLab.oMoveBackwardStart
        StrafeLeftStart = RaijinLab.oStrafeLeftStart
        StrafeRightStart = RaijinLab.oStrafeRightStart
        CameraOrSelectOrMoveStart = RaijinLab.oCameraOrSelectOrMoveStop
        JumpOrAscendStart = RaijinLab.oJumpOrAscendStart
        RaijinLab.movement_locked = false
    end
end

function RaijinLab:LockMovement()
    MoveForwardStart = function() end
    MoveBackwardStart = function() end
    StrafeLeftStart = function() end
    StrafeRightStart = function() end
    JumpOrAscendStart = function() end
    CameraOrSelectOrMoveStart = function() end
    RaijinLab.movement_locked = true
end


function RaijinLab:StopMoving(lock)
    if RaijinLab.Actions and RaijinLab.Actions.available and RaijinLab.Actions.available() then
        RaijinLab.Actions.StopMoving()
    else
        -- Runtime offline: refuse to call bare protected *Stop APIs (would taint the client - #132).
        print("|cff7ec8e3RaijinLab|r StopMoving: runtime offline (inject first)")
        return
    end
    if lock then
        RaijinLab:UnlockMovement()
    else
        RaijinLab:UnlockMovement()
    end
end

-- ___  ____         _ _
-- |  \/  (_)       (_) |
-- | .  . |_ ___ ___ _| | ___  ___
-- | |\/| | / __/ __| | |/ _ \/ __|
-- | |  | | \__ \__ \ | |  __/\__ \
-- \_|  |_/_|___/___/_|_|\___||___/

-- Gets the count of the flying missiles.
function RaijinLab:GetMissileCount()
    if GetTime() - cache.GetMissileCount.last_ran > cache.pop_time then
        cache.GetMissileCount.results = pack(RLCall("GetMissileCount"))
        cache.GetMissileCount.last_ran = GetTime()
    end
    return unpack(cache.GetMissileCount.results)
end

-- Gets the info of a specific missile.
-- spellId, spellVisualId, x, y, z, sourceObject, sourceX, sourceY, sourceZ,
-- targetObject, targetX, targetY, targetZ
function RaijinLab:GetMissileWithIndex(index)
    if not cache.GetMissileWithIndex[index] then
        cache.GetMissileWithIndex[index] = { last_ran = 0 }
    end
    if GetTime() - cache.GetMissileWithIndex[index].last_ran > cache.pop_time then
        cache.GetMissileWithIndex[index].results = pack(RLCall("GetMissileWithIndex", index))
        cache.GetMissileWithIndex[index].last_ran = GetTime()
    end
    return unpack(cache.GetMissileWithIndex[index].results)
end

-- in-world navigation
-- Gets the map information about the current location.
function RaijinLab:GetCurrentMapInfo()
    return RLCall("GetCurrentMapInfo")
end
-- Checks whether the navigation files for a specific map exists.
function RaijinLab:MapExists(id)
    if not id then return end
    return RLCall("MapExists", id)
end
-- Loads a navigation map. Map files must be placed correctly before loading.
function RaijinLab:LoadMap(id)
    if not id then return end
    return RLCall("LoadMap", id)
end
-- Unloads a navigation map.
function RaijinLab:UnloadMap(id)
    if not id then return end
    return RLCall("UnloadMap", id)
end
-- Checks if a navigation map is loaded.
function RaijinLab:IsMapLoaded(id)
    if not id then return end
    return RLCall("IsMapLoaded", id)
end
-- Calculates a path to navigate from one position to another.
-- Notice that the map_id must be loaded beforehand.
function RaijinLab:FindPath(id, x1, y1, z1, x2, y2, z2)
    return RLCall("FindPath", "RaijinLabRuntime", id, x1, y1, z1, x2, y2, z2)
end

function RaijinLab:GetClosestPositionOnMesh(id, x, y, z, ignoreWater)
    if not ignoreWater then ignoreWater = true end
    return RLCall("GetClosestPositionOnMesh", id, x, y, z, ignoreWater)
end

function RaijinLab:GetClosestMeshPolygon(id, x, y, z, dX, dY, dZ)
    return RLCall("GetClosestMeshPolygon", id, x, y, z, dX, dY, dZ)
end

function RaijinLab:GetMeshPolygons(id, startPoly, x, y, z, radius)
    return RLCall("GetMeshPolygons", id, startPoly, x, y, z, radius)
end

function RaijinLab:GetMeshPolygonFlags(id, polygon)
    return RLCall("GetMeshPolygonFlags", id, polygon)
end

function RaijinLab:SetMeshPolygonFlags(id, polygon, flags)
    return RLCall("SetMeshPolygonFlags", id, polygon, flags)
end

function RaijinLab:GetMeshPolygonVertices(id, polygon)
    return RLCall("GetMeshPolygonVertices", id, polygon)
end

-- Gets the mesh tile coords of a certain position, same as shown on WoW Tools.
--
-- Hint: The map must be loaded before calling the API.
--
-- Hint: The *.mmtile file name follows the format "MMMMYYXX.mmtile". e.g. The tile at (31,41) of map 1 should correspond to the map file "00014131.mmtile".
function RaijinLab:GetMeshTile(id, x, y, z)
    return RLCall("GetMeshTile", id, x, y, z)
end

--  _____ _     _           _
-- |  _  | |   (_)         | |
-- | | | | |__  _  ___  ___| |_
-- | | | | '_ \| |/ _ \/ __| __|
-- \ \_/ / |_) | |  __/ (__| |_
--  \___/|_.__/| |\___|\___|\__|
--            _/ |
--           |__/


-- enums and an inverted version of each table (value to name, name to value)

RaijinLab.enums.UnitFlags = {
    UNIT_FLAG_SERVER_CONTROLLED = 0x00000001, -- set only when unit movement is controlled by server - by SPLINE/MONSTER_MOVE packets, together with UNIT_FLAG_STUNNED; only set to units controlled by client; client function CGUnit_C::IsClientControlled returns false when set for owner
    UNIT_FLAG_NON_ATTACKABLE = 0x00000002, -- not attackable
    UNIT_FLAG_REMOVE_CLIENT_CONTROL = 0x00000004, -- This is a legacy flag used to disable movement player's movement while controlling other units, SMSG_CLIENT_CONTROL replaces this functionality clientside now. CONFUSED and FLEEING flags have the same effect on client movement asDISABLE_MOVE_CONTROL in addition to preventing spell casts/autoattack (they all allow climbing steeper hills and emotes while moving)
    UNIT_FLAG_PVP_ATTACKABLE = 0x00000008, -- allow apply pvp rules to attackable state in addition to faction dependent state
    UNIT_FLAG_RENAME = 0x00000010,
    UNIT_FLAG_PREPARATION = 0x00000020, -- don't take reagents for spells with SPELL_ATTR5_NO_REAGENT_WHILE_PREP
    UNIT_FLAG_UNK_6 = 0x00000040,
    UNIT_FLAG_NOT_ATTACKABLE_1 = 0x00000080, -- ?? (UNIT_FLAG_PVP_ATTACKABLE | UNIT_FLAG_NOT_ATTACKABLE_1) is NON_PVP_ATTACKABLE
    UNIT_FLAG_IMMUNE_TO_PC = 0x00000100, -- disables combat/assistance with PlayerCharacters (PC) - see Unit::_IsValidAttackTarget, Unit::_IsValidAssistTarget
    UNIT_FLAG_IMMUNE_TO_NPC = 0x00000200, -- disables combat/assistance with NonPlayerCharacters (NPC) - see Unit::_IsValidAttackTarget, Unit::_IsValidAssistTarget
    UNIT_FLAG_LOOTING = 0x00000400, -- loot animation
    UNIT_FLAG_PET_IN_COMBAT = 0x00000800, -- on player pets: whether the pet is chasing a target to attack || on other units: whether any of the unit's minions is in combat
    UNIT_FLAG_PVP = 0x00001000, -- changed in 3.0.3
    UNIT_FLAG_SILENCED = 0x00002000, -- silenced, 2.1.1
    UNIT_FLAG_CANNOT_SWIM = 0x00004000, -- 2.0.8
    UNIT_FLAG_UNK_15 = 0x00008000,
    UNIT_FLAG_UNK_16 = 0x00010000,
    UNIT_FLAG_PACIFIED = 0x00020000, -- 3.0.3 ok
    UNIT_FLAG_STUNNED = 0x00040000, -- 3.0.3 ok
    UNIT_FLAG_IN_COMBAT = 0x00080000,
    UNIT_FLAG_TAXI_FLIGHT = 0x00100000, -- disable casting at client side spell not allowed by taxi flight (mounted?), probably used with 0x4 flag
    UNIT_FLAG_DISARMED = 0x00200000, -- 3.0.3, disable melee spells casting..., "Required melee weapon" added to melee spells tooltip.
    UNIT_FLAG_CONFUSED = 0x00400000,
    UNIT_FLAG_FLEEING = 0x00800000,
    UNIT_FLAG_PLAYER_CONTROLLED = 0x01000000, -- used in spell Eyes of the Beast for pet... let attack by controlled creature
    UNIT_FLAG_NOT_SELECTABLE = 0x02000000,
    UNIT_FLAG_SKINNABLE = 0x04000000,
    UNIT_FLAG_MOUNT = 0x08000000,
    UNIT_FLAG_UNK_28 = 0x10000000,
    UNIT_FLAG_UNK_29 = 0x20000000, -- used in Feing Death spell
    UNIT_FLAG_SHEATHE = 0x40000000,
    UNIT_FLAG_UNK_31 = 0x80000000,
}

RaijinLab.enums.UnitFlagsInverted = table_invert(RaijinLab.enums.UnitFlags)

RaijinLab.enums.UnitDynamicFlags = {
    UNIT_DYNFLAG_NONE = 0x0000,
    UNIT_DYNFLAG_HIDE_MODEL = 0x0002, -- Object model is not shown with this flag
    UNIT_DYNFLAG_LOOTABLE = 0x0004,
    UNIT_DYNFLAG_TRACK_UNIT = 0x0008,
    UNIT_DYNFLAG_TAPPED = 0x0010, -- Lua_UnitIsTapped
    UNIT_DYNFLAG_SPECIALINFO = 0x0020,
    UNIT_DYNFLAG_DEAD = 0x0040,
    UNIT_DYNFLAG_REFER_A_FRIEND = 0x0080
}

RaijinLab.enums.UnitDynamicFlagsInverted = table_invert(RaijinLab.enums.UnitDynamicFlags)


RaijinLab.enums.GameObjectFlags = {
    GO_FLAG_IN_USE = 0x00000001, -- disables interaction while animated
    GO_FLAG_LOCKED = 0x00000002, -- require key, spell, event, etc to be opened. Makes "Locked" appear in tooltip
    GO_FLAG_INTERACT_COND = 0x00000004, -- cannot interact (condition to interact - requires GO_DYNFLAG_LO_ACTIVATE to enable interaction clientside)
    GO_FLAG_TRANSPORT = 0x00000008, -- any kind of transport? Object can transport (elevator, boat, car)
    GO_FLAG_NOT_SELECTABLE = 0x00000010, -- not selectable even in GM mode
    GO_FLAG_NODESPAWN = 0x00000020, -- never despawn, typically for doors, they just change state
    GO_FLAG_AI_OBSTACLE = 0x00000040, -- makes the client register the object in something called AIObstacleMgr, unknown what it does
    GO_FLAG_FREEZE_ANIMATION = 0x00000080,
    -- for object types GAMEOBJECT_TYPE_GARRISON_BUILDING, GAMEOBJECT_TYPE_GARRISON_PLOT and GAMEOBJECT_TYPE_PHASEABLE_MO flag bits 8 to 12 are used as WMOAreaTable::NameSetID
    GO_FLAG_DAMAGED = 0x00000200,
    GO_FLAG_DESTROYED = 0x00000400,
    GO_FLAG_INTERACT_DISTANCE_USES_TEMPLATE_MODEL = 0x00080000, -- client checks interaction distance from model sent in SMSG_QUERY_GAMEOBJECT_RESPONSE instead of GAMEOBJECT_DISPLAYID
    GO_FLAG_MAP_OBJECT = 0x00100000 -- pre-7.0 model loading used to be controlled by file extension (wmo vs m2)
}

RaijinLab.enums.GameObjectFlagsInverted = table_invert(RaijinLab.enums.GameObjectFlags)


RaijinLab.enums.GameObjectDynamicLowFlags = {
    GO_DYNFLAG_LO_HIDE_MODEL = 0x02, -- Object model is not shown with this flag
    GO_DYNFLAG_LO_ACTIVATE = 0x04, -- enables interaction with GO
    GO_DYNFLAG_LO_ANIMATE = 0x08, -- possibly more distinct animation of GO
    GO_DYNFLAG_LO_NO_INTERACT = 0x10, -- appears to disable interaction (not fully verified)
    GO_DYNFLAG_LO_SPARKLE = 0x20, -- makes GO sparkle
    GO_DYNFLAG_LO_STOPPED = 0x40 -- Transport is stopped
}

RaijinLab.enums.GameObjectDynamicLowFlagsInverted = table_invert(RaijinLab.enums.GameObjectDynamicLowFlags)

-- GAMEOBJECT TYPES, 0-BASED AS THE WIRE DEFINES THEM.
--
-- This table was copied from a MODERN TrinityCore - it still carries Warlords
-- entries like GARRISON_BUILDING - and every value was shifted +1 in the
-- process, so DOOR read 1 where the protocol says 0. The ordering was never
-- wrong, only the base, and DOOR=0 is stable across every core and expansion.
--
-- It was not cosmetic: ObjectIsQuestObjectType compares these against the type
-- byte the client actually sends, so CHEST and GOOBER - the lootable and
-- quest-object classes - could never match. Every gameobject fell through to
-- the tooltip scan.
RaijinLab.enums.GameObjectTypes = {
    GAMEOBJECT_TYPE_DOOR = 0,
    GAMEOBJECT_TYPE_BUTTON = 1,
    GAMEOBJECT_TYPE_QUESTGIVER = 2,
    GAMEOBJECT_TYPE_CHEST = 3,
    GAMEOBJECT_TYPE_BINDER = 4,
    GAMEOBJECT_TYPE_GENERIC = 5,
    GAMEOBJECT_TYPE_TRAP = 6,
    GAMEOBJECT_TYPE_CHAIR = 7,
    GAMEOBJECT_TYPE_SPELL_FOCUS = 8,
    GAMEOBJECT_TYPE_TEXT = 9,
    GAMEOBJECT_TYPE_GOOBER = 10,
    GAMEOBJECT_TYPE_TRANSPORT = 11,
    GAMEOBJECT_TYPE_AREADAMAGE = 12,
    GAMEOBJECT_TYPE_CAMERA = 13,
    GAMEOBJECT_TYPE_MAP_OBJECT = 14,
    GAMEOBJECT_TYPE_MAP_OBJ_TRANSPORT = 15,
    GAMEOBJECT_TYPE_DUEL_ARBITER = 16,
    GAMEOBJECT_TYPE_FISHINGNODE = 17,
    GAMEOBJECT_TYPE_RITUAL = 18,
    GAMEOBJECT_TYPE_MAILBOX = 19,
    GAMEOBJECT_TYPE_DO_NOT_USE = 20,
    GAMEOBJECT_TYPE_GUARDPOST = 21,
    GAMEOBJECT_TYPE_SPELLCASTER = 22,
    GAMEOBJECT_TYPE_MEETINGSTONE = 23,
    GAMEOBJECT_TYPE_FLAGSTAND = 24,
    GAMEOBJECT_TYPE_FISHINGHOLE = 25,
    GAMEOBJECT_TYPE_FLAGDROP = 26,
    GAMEOBJECT_TYPE_MINI_GAME = 27,
    GAMEOBJECT_TYPE_DO_NOT_USE_2 = 28,
    GAMEOBJECT_TYPE_CONTROL_ZONE = 29,
    GAMEOBJECT_TYPE_AURA_GENERATOR = 30,
    GAMEOBJECT_TYPE_DUNGEON_DIFFICULTY = 31,
    GAMEOBJECT_TYPE_BARBER_CHAIR = 32,
    GAMEOBJECT_TYPE_DESTRUCTIBLE_BUILDING = 33,
    GAMEOBJECT_TYPE_GUILD_BANK = 34,
    GAMEOBJECT_TYPE_TRAPDOOR = 35,
    GAMEOBJECT_TYPE_NEW_FLAG = 36,
    GAMEOBJECT_TYPE_NEW_FLAG_DROP = 37,
    GAMEOBJECT_TYPE_GARRISON_BUILDING = 38,
    GAMEOBJECT_TYPE_GARRISON_PLOT = 39,
    GAMEOBJECT_TYPE_CLIENT_CREATURE = 40,
    GAMEOBJECT_TYPE_CLIENT_ITEM = 41,
    GAMEOBJECT_TYPE_CAPTURE_POINT = 42,
    GAMEOBJECT_TYPE_PHASEABLE_MO = 43,
    GAMEOBJECT_TYPE_GARRISON_MONUMENT = 44,
    GAMEOBJECT_TYPE_GARRISON_SHIPMENT = 45,
    GAMEOBJECT_TYPE_GARRISON_MONUMENT_PLAQUE = 46,
    GAMEOBJECT_TYPE_ITEM_FORGE = 47,
    GAMEOBJECT_TYPE_UI_LINK = 48,
    GAMEOBJECT_TYPE_KEYSTONE_RECEPTACLE = 49,
    GAMEOBJECT_TYPE_GATHERING_NODE = 50,
    GAMEOBJECT_TYPE_CHALLENGE_MODE_REWARD = 51,
    GAMEOBJECT_TYPE_MULTI = 52,
    GAMEOBJECT_TYPE_SIEGEABLE_MULTI = 53,
    GAMEOBJECT_TYPE_SIEGEABLE_MO = 54,
    GAMEOBJECT_TYPE_PVP_REWARD = 55,
    GAMEOBJECT_TYPE_PLAYER_CHOICE_CHEST = 56,
    GAMEOBJECT_TYPE_LEGENDARY_FORGE = 57,
    GAMEOBJECT_TYPE_GARR_TALENT_TREE = 58,
    GAMEOBJECT_TYPE_WEEKLY_REWARD_CHEST = 59,
    GAMEOBJECT_TYPE_CLIENT_MODEL = 60
}

RaijinLab.enums.GameObjectTypesInverted = table_invert(RaijinLab.enums.GameObjectTypes)

RaijinLab.enums.ObjectTypeFlags = {
    Corpse = 1024,
    Conversation = 8192,
    SceneObject = 4098,
    AzeriteEmpoweredItem = 8,
    GameObject = 256,
    Unit = 32,
    Item = 2,
    Player = 64,
    Object = 1,
    DynamicObject = 512,
    AzeriteItem = 16,
    ActivePlayer = 128,
    AreaTrigger = 2048,
    Container = 4
}

RaijinLab.enums.ObjectTypeFlagsInverted = table_invert(RaijinLab.enums.ObjectTypeFlags)

function RaijinLab:GameObjectIsType(object, type)
    if not object then return end
    if type == 0 then return end
    if not RaijinLab:ObjectIsGameObject(object) then return end
    local id, _ = RaijinLab:GameObjectType(object)
    return type == id
end

-- flags = {
--   Object = 1,
--   Item = 2,
--   Container = 4,
--   AzeriteEmpoweredItem = 8,
--   AzeriteItem = 16,
--   ...
-- }
function RaijinLab:GetObjectTypeFlagsTable()
    return RLCall("GetObjectTypeFlagsTable")
end

-- fields = {
--   ["AnimationState"] = 123,
--   ...
-- }
function RaijinLab:GetObjectFieldsTable()
    return RLCall("GetObjectFieldsTable")
end

-- descriptors = {
--   ["CGObjectData__m_guid"] = 0,
--   ["CGObjectData__m_entryID"] = 8,
--   ...
-- }
-- Fallback 3.3.5-class descriptor indices when runtime does not expose tables.
-- Values are field *byte* offsets used by classic unlockers; runtime may ignore
-- ObjectDescriptor until field reader is implemented - ObjectGUID still works via
-- GetObjectWithIndex returning GUID strings.
local FALLBACK_OBJECT_DESCRIPTORS = {
    CGObjectData__m_guid = 0,
    CGObjectData__m_entryID = 0x0C,
    CGObjectData__m_dynamicFlags = 0x13C,
    CGObjectData__m_scale = 0x10,
    CGUnitData__mountDisplayID = 0x114,
    CGPlayerData__currentSpecID = 0, -- retail-only; unused on Ascension
    CGGameObjectData__m_createdBy = 0x18,
}

local FALLBACK_VALUE_TYPES = {
    Nil = 0,
    Char = 1,
    Byte = 2,
    Short = 3,
    UShort = 4,
    Int = 5,
    UInt = 6,
    Long = 7,
    ULong = 8,
    Float = 9,
    Double = 10,
    String = 11,
    GUID = 12,
}

function RaijinLab:GetObjectDescriptorsTable()
    local t = RLCall("GetObjectDescriptorsTable")
    if type(t) == "table" then return t end
    return FALLBACK_OBJECT_DESCRIPTORS
end

function RaijinLab:GetValueTypesTable()
    local t = RLCall("GetValueTypesTable")
    if type(t) == "table" then return t end
    return FALLBACK_VALUE_TYPES
end

-- Gets a descriptor value of an object.
function RaijinLab:ObjectDescriptor(object, offset, type)
    if not object or offset == nil then return end
    return RLCall("ObjectDescriptor", object, offset, type)
end

-- Gets player spec by player descriptor.
function RaijinLab:GetPlayerSpecByDescriptor(player)
    local d = RaijinLab:GetObjectDescriptorsTable()
    local v = RaijinLab:GetValueTypesTable()
    if not d or not v or not d.CGPlayerData__currentSpecID then return end
    return RaijinLab:ObjectDescriptor(player, d.CGPlayerData__currentSpecID, v.UInt)
end


-- Gets the scale of an object.
function RaijinLab:ObjectScale(object)
    if not object then return end
    return RLCall("ObjectScale", object)
end

-- Gets the dynamic flags of an object.
function RaijinLab:ObjectDynamicFlags(object)
    if not object then return end
    return RLCall("ObjectDynamicFlags", object)
end

-- Gets a field value of an object.
function RaijinLab:ObjectField(object, offset, type)
    if not object then return end
    return RLCall("ObjectField", object, offset, type)
end

-- Gets the type info of a game object.
function RaijinLab:GameObjectType(object)
    if not object then return end
    return RLCall("GameObjectType", object)
end

function RaijinLab:GetObject(object)
    if not object then return end
    return RLCall("GetObject", object)
end

-- Gets the object by its GUID.
function RaijinLab:GetObjectWithGUID(GUID)
    return RLCall("GetObjectWithGUID", GUID)
end

-- Gets the type flags of an object.
function RaijinLab:ObjectTypeFlags(object)
    if not object then return end
    local f = RLCall("ObjectTypeFlags", object)
    -- Runtime may return CGObject type enum (0..7) instead of bit flags
    if type(f) == "number" and f >= 0 and f <= 7 then
        local enumToFlags = {
            [0] = 1,    -- Object
            [1] = 2,    -- Item
            [2] = 4,    -- Container
            [3] = 32,   -- Unit
            [4] = 64,   -- Player
            [5] = 256,  -- GameObject
            [6] = 512,  -- DynamicObject
            [7] = 1024, -- Corpse
        }
        return enumToFlags[f] or 0
    end
    return f or 0
end


-- Checks if an object is of specific type.
function RaijinLab:ObjectIsType(object, type)
    if not object then return end
    return RLCall("ObjectIsType", object, type)
end

-- Checks whether an object exists in memory.
function RaijinLab:ObjectExists(object)
    if not object then return end
    return RLCall("ObjectExists", object)
end

-- Gets the ID of an object.
function RaijinLab:ObjectId(object)
    if not object then return end
    return RLCall("ObjectId", object)
end

function RaijinLab:ObjectGUID(object)
    if not object then return end
    -- Ascension runtime: GetObjectWithIndex already returns a GUID string/number.
    if type(object) == "string" or type(object) == "number" then
        local d = RaijinLab:GetObjectDescriptorsTable()
        local v = RaijinLab:GetValueTypesTable()
        if d and v and d.CGObjectData__m_guid and v.GUID then
            local via = RaijinLab:ObjectDescriptor(object, d.CGObjectData__m_guid, v.GUID)
            if via then return via end
        end
        -- A UNIT TOKEN IS NOT A GUID.
        --
        -- When the descriptor read is unavailable this fell through to
        -- `return object`, handing the caller back the literal string it passed
        -- in - so ObjectGUID("target") answered "target" and every consumer
        -- treated that as a GUID. The runtime's GuidArg special-cases only
        -- "player", so "target" parsed as 0 and ObjectIsFacing correctly refused
        -- to answer. Live selftest: facing_wired FAIL "nil - not wired", while
        -- interact passed only by ACCIDENT - its parser maps tokens to 0, which
        -- routes to InteractTarget() and happens to do the right thing.
        --
        -- UnitGUID is the authoritative resolver for a token and is plain 3.3.5.
        -- Anything that already looks like a GUID is returned untouched.
        local Act = RaijinLab.Actions
        local looks_guid = Act and Act.looks_like_guid and Act.looks_like_guid(object)
        if type(object) == "string" and not looks_guid then
            if UnitGUID then
                local ok, g = pcall(UnitGUID, object)
                if ok and g then return g end
            end
            return nil      -- an unresolvable token is NOT an answer
        end
        return object
    end
    local d = RaijinLab:GetObjectDescriptorsTable()
    local v = RaijinLab:GetValueTypesTable()
    if not d or not v or d.CGObjectData__m_guid == nil or v.GUID == nil then
        return nil
    end
    return RaijinLab:ObjectDescriptor(object, d.CGObjectData__m_guid, v.GUID)
end


-- Gets the world position of an object.
-- Runtime 1.4.2+ returns a single packed "x|y|z" string (FrameScript multi-return was
-- unreliable on this client). Unpack here so the rest of the addon still gets x,y,z.
-- Unit tokens ("target", "focus", ...) that must be resolved to a numeric GUID
-- before hitting the runtime. The runtime's GuidArg only parses numeric/hex GUID
-- strings; an unresolved token silently falls back to the LOCAL PLAYER (or an
-- empty 0,0,0), so ObjectPosition("target") returned the player's own position.
-- That made every target-distance calc wrong (0 when it collapsed to the player,
-- or a huge value against a 0,0,0 target) and broke distance conditions.
-- "player" is intentionally left as a token - the runtime special-cases a
-- local/absent GUID to the player position and reads it even with the OM off.
-- Unit tokens that must become GUIDs before the runtime GuidArg parser.
-- "player" stays a token (runtime special-cases local player without GUID).
-- nameplateN / bossN / partyN / raidN MUST resolve - raw strings fail GuidArg
-- and made ObjectPosition return nil for every nameplate (broken AoE ranging).
local function is_unit_token_needing_guid(s)
    if type(s) ~= "string" then return false end
    local lower = s:lower()
    if lower == "player" then return false end
    if lower == "target" or lower == "focus" or lower == "mouseover" or lower == "pet"
        or lower == "targettarget" or lower == "focustarget" or lower == "pettarget" then
        return true
    end
    if lower:match("^party%d") or lower:match("^raid%d") or lower:match("^arena%d") then
        return true
    end
    if lower:match("^nameplate%d") or lower:match("^boss%d") then
        return true
    end
    return false
end

-- Normalize a UnitGUID / raw GUID for the runtime GuidArg parser.
-- Accepts number, "0xABC...", plain hex, rejects empty / unusable.
local function normalize_guid(g)
    if g == nil then return nil end
    if type(g) == "number" then
        if g == 0 then return nil end
        return string.format("0x%X", g)
    end
    local s = tostring(g)
    if s == "" or s == "0" or s == "0x0" or s == "0X0" then return nil end
    if s:match("^0[xX]%x+$") then return s end
    if s:match("^%x+$") and #s >= 8 then return "0x" .. s end
    -- Pass through other non-empty forms (runtime may still parse).
    return s
end

local function resolve_object_arg(object)
    if object == nil then return nil end
    if type(object) == "number" then return normalize_guid(object) end
    if type(object) ~= "string" then return object end
    if is_unit_token_needing_guid(object) then
        if UnitExists and not UnitExists(object) then return nil end
        local guid = UnitGUID and UnitGUID(object)
        return normalize_guid(guid)
    end
    if object == "player" then return "player" end
    return normalize_guid(object) or object
end

-- IS THIS ACTUALLY WHERE THE CHARACTER IS?
--
-- Observed live: the runtime returned a good position for a while and then
-- collapsed to (0.0, 118.8, 0.0) while the CAMERA sat at (1723.7, 1623.3, 129.3).
-- The (0,0,0) sentinel check missed it because y was non-zero, so the bot
-- believed it was standing two thousand yards from where it was. Everything
-- downstream then behaved exactly as it should for a character in an empty void:
-- TraceGround found no floor, the grounded gate refused to drive - "it stopped,
-- left the ground and is not moving" - and the search measured a 10698-yard leg
-- from a place the character had never been.
--
-- The camera is an INDEPENDENT WITNESS and it is read every frame anyway. A
-- follow camera sits within a few tens of yards of the character; a position two
-- thousand yards away is not a position, whatever the field says. This cannot be
-- fixed by reading the field more carefully - only something outside it can
-- disagree with it.
--
-- Returns false + reason when the reading should be refused. Silent (returns
-- true) when there is no camera to compare against: absence of a witness is not
-- evidence against the reading.
RaijinLab.MAX_CAM_DIST = 200.0     -- yd; a follow camera is far closer than this

function RaijinLab.PlausiblePlayerPos(x, y, z)
    -- Half-null island: (0, 88, 87) was accepted by the runtime and rejected
    -- here forever -> need_position while camera sat in Deathknell. Refuse any
    -- axis that has no continental magnitude before asking the camera.
    if not x or not y then return false, "nil" end
    -- HALF-NULL ISLAND, JUDGED RELATIVE TO THE WITNESS - NOT ABSOLUTELY.
    --
    -- The real symptom: the runtime returned (0, 88, 87) while the camera sat in
    -- Deathknell at (1845, 1637). One axis collapsed to zero, which no continental
    -- coordinate does, so the reading is garbage.
    --
    -- But "an axis under 30 is impossible" is only true because Azeroth's zones
    -- happen to be far from the origin. As an ABSOLUTE rule it refuses a
    -- legitimate position near (0,0) - which is exactly where the simulator
    -- spawns, so every travel scenario reported need_position and 0yd travelled.
    -- A guard that cannot tell "garbage" from "near the origin" is asserting a
    -- fact about the world it has no way to know.
    --
    -- The camera is the witness that actually settles it: if the camera is far
    -- from the origin and we are not, one of us is wrong and it is not the camera.
    -- With no camera we have no grounds to refuse, so we do not.
    local cam = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
    -- CONTINENTAL, not merely non-zero. A follow camera sits a few yards from the
    -- player, so near the origin it reads ~30 - enough to trip a "> 30" test and
    -- re-refuse the very position it was meant to vouch for. Only a camera
    -- hundreds of yards out proves we are somewhere a zero axis is impossible.
    local cam_far = cam and type(cam.px) == "number" and type(cam.py) == "number"
        and (math.abs(cam.px) > 500 or math.abs(cam.py) > 500)
    if cam_far and (math.abs(x) < 30 or math.abs(y) < 30) then
        return false, "half_null"
    end
    local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
    -- 0 IS TRUTHY IN LUA. `c.px and c.py` accepts an all-zero camera read, which
    -- is exactly what a FAILED read looks like - so the witness this guard
    -- depends on could itself be garbage and still be believed. A camera at the
    -- literal world origin would then "disagree" with every real position and
    -- reject all of them, or agree with a garbage (0,y,0) position and pass it.
    -- Same trap as the quest-giver stub returning 0: an in-range value that
    -- means "no answer".
    if not (c and type(c.px) == "number" and type(c.py) == "number") then
        return true
    end
    -- TWO DIFFERENT REASONS, SAID OUT LOUD.
    --
    -- Both of these used to `return true` with no reason, which made the first
    -- guard invisible: deleting it changed nothing observable, because an
    -- all-zero camera also satisfies `abs(px) < 30`. The mutation harness
    -- reported it as an undefended fix when it was really an EQUIVALENT
    -- mutation - nothing to detect. Naming the reasons makes the distinction
    -- real, testable, and useful in a log: "the camera read failed entirely" is
    -- a different diagnosis from "the camera is somewhere unusable".
    if c.px == 0 and c.py == 0 and (c.pz == nil or c.pz == 0) then
        return true, "no_cam_witness"    -- all-zero camera = no witness, not a verdict
    end
    if math.abs(c.px) < 30 or math.abs(c.py) < 30 then
        return true, "cam_unusable"      -- camera itself unusable as witness
    end
    local dx, dy = x - c.px, y - c.py
    local d = math.sqrt(dx * dx + dy * dy)
    if d > RaijinLab.MAX_CAM_DIST then
        return false, "cam_" .. math.floor(d)
    end
    return true
end

function RaijinLab:ObjectPosition(object)
    local raw
    local want_player = (object == nil or object == "player")
    -- Player: prefer no-arg runtime path (always ResolveLocalPos, even when
    -- LocalGuid is briefly 0). Token "player" is also accepted by the runtime.
    if want_player then
        raw = RLCall("ObjectPosition")
        if type(raw) ~= "string" then
            raw = RLCall("ObjectPosition", "player")
        end
    else
        local resolved = resolve_object_arg(object)
        if resolved == nil then return nil end
        raw = RLCall("ObjectPosition", resolved)
        -- Retry raw token if GUID resolve path failed (some builds need the token).
        if (type(raw) ~= "string" or raw == "0.000|0.000|0.000")
            and type(object) == "string" and is_unit_token_needing_guid(object) then
            local g2 = UnitGUID and UnitGUID(object)
            if g2 then raw = RLCall("ObjectPosition", tostring(g2)) end
        end
        -- Hostiles pack snapshot (NearbyHostiles) — same frame positions for
        -- multi-dot GUIDs when ObjectPtr is cold. Measurement, not a guess.
        if (type(raw) ~= "string" or raw == "0.000|0.000|0.000") then
            local W = RaijinLab.World
            local c = W and W._hostiles_cache
            local key = tostring(resolved or object or "")
            if c and c.by_guid and key ~= "" then
                local row = c.by_guid[key] or c.by_guid[key:lower()]
                if not row and type(object) == "string" then
                    row = c.by_guid[tostring(object)]
                end
                if row and row.x and row.y and not (row.x == 0 and row.y == 0) then
                    return row.x, row.y, row.z or 0
                end
            end
        end
    end
    if type(raw) == "string" then
        local x, y, z = raw:match("([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not x or not y then return nil end
        -- (0,0,0) is the runtime's failure sentinel.
        if x == 0 and y == 0 and (not z or z == 0) then return nil end
        if want_player then
            local ok, why = RaijinLab.PlausiblePlayerPos(x, y, z)
            if not ok then
                RaijinLab._badpos = (RaijinLab._badpos or 0) + 1
                RaijinLab._badpos_streak = (RaijinLab._badpos_streak or 0) + 1
                local Tel = RaijinLab.Telemetry
                if Tel and Tel.every then
                    Tel.every("api:badpos", 2, "api", 1, "bad_player_pos",
                        { x = x, y = y, z = z, why = why, n = RaijinLab._badpos,
                          streak = RaijinLab._badpos_streak })
                end
                -- CAMERA FALLBACK. Freezing the suite on need_position while the
                -- camera is sitting on the character is worse than navigating
                -- from the camera. Follow cam is within tens of yards.
                local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
                if c and type(c.px) == "number" and type(c.py) == "number"
                    and math.abs(c.px) >= 30 and math.abs(c.py) >= 30 then
                    return c.px, c.py, c.pz or z or 0
                end
                return nil
            end
            -- Good reading clears the streak so the contract can recover without
            -- /reload once the runtime layout re-pins correctly.
            RaijinLab._badpos_streak = 0
        end
        return x, y, z or 0
    end
    if type(raw) == "number" then
        if raw == 0 then return nil end
        return raw, 0, 0
    end
    return nil
end

-- Combat reach (UNIT_FIELD_COMBATREACH, yards). Used for melee / unit spells.
-- Runtime applies Trinity default 1.5 when the descriptor field is 0.
function RaijinLab:ObjectCombatReach(object)
    if object ~= nil then
        local resolved = resolve_object_arg(object)
        if resolved == nil then return nil end
        object = resolved
    end
    local v
    if object then v = RLCall("ObjectCombatReach", object) else v = RLCall("ObjectCombatReach") end
    v = tonumber(v)
    if not v or v < 0 then return nil end
    if v ~= v or v > 100 then return nil end
    return v
end

-- Bounding radius (UNIT_FIELD_BOUNDINGRADIUS, yards). Used for self-AoE body size.
-- Runtime applies default 0.5 when the descriptor field is 0.
function RaijinLab:ObjectBoundingRadius(object)
    if object ~= nil then
        local resolved = resolve_object_arg(object)
        if resolved == nil then return nil end
        object = resolved
    end
    local v
    if object then v = RLCall("ObjectBoundingRadius", object) else v = RLCall("ObjectBoundingRadius") end
    v = tonumber(v)
    if not v or v < 0 then return nil end
    if v ~= v or v > 80 then return nil end
    return v
end

-- Horizontal (2D) center-to-center distance in yards.
-- WoW melee / ground-AoE (Whirlwind) use XY, not full 3D - a bad Z read was
-- either inflating range (never cast) or was unreliable vs the client.
function RaijinLab:Distance2D(a, b)
    if not a or not b then return nil end
    local x1, y1 = RaijinLab:ObjectPosition(a)
    local x2, y2 = RaijinLab:ObjectPosition(b)
    if not x1 or not x2 then return nil end
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- 3D center distance (LoS / pathing). Prefer Distance2D for spell range.
function RaijinLab:Distance3D(a, b)
    if not a or not b then return nil end
    local x1, y1, z1 = RaijinLab:ObjectPosition(a)
    local x2, y2, z2 = RaijinLab:ObjectPosition(b)
    if not x1 or not x2 then return nil end
    local dx, dy, dz = x1 - x2, y1 - y2, (z1 or 0) - (z2 or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Default Distance = 2D (spell/melee/AoE range).
function RaijinLab:Distance(a, b)
    return RaijinLab:Distance2D(a, b)
end

-- ============================================================================
-- RANGE MODEL (fail-closed, hitbox-aware)
-- ============================================================================
-- Center = 2D pivot-to-pivot (ObjectPosition).
--
-- MELEE / unit-targeted:
--   edge = max(0, center - pCombatReach - tCombatReach)  <=  maxRange (~5)
--   UNIT_FIELD_COMBATREACH (Trinity default 1.5 when 0). Large bosses work.
--
-- SELF-AoE (Whirlwind R=8, Thunder Clap, ...):
--   Live testing on Ascension: subtracting humanoid combat/bounding (~1.5) from
--   center produced FALSE IN at 9.2-9.5 yd (spell cast, no hit). The damage
--   disk is pivot-based for normal models.
--   gap = center                          for normal models (bound <= BOSS_BOUND)
--   gap = max(0, center - tBound)        only when tBound > BOSS_BOUND (giant models)
--   In range when gap <= R. Never subtract combat reach for self-AoE.
-- ============================================================================

local function _sanitize_reach(v, cap)
    v = tonumber(v)
    if not v or v ~= v or v < 0 then return nil end
    if cap and v > cap then return nil end
    return v
end

-- Bounding larger than this is treated as a giant model (extends self-AoE).
-- Humanoid/default bounding is typically <= 1.5 and must NOT pad the WW disk.
local AOE_BOSS_BOUND = 2.0

-- Targeted combat distance. Returns edge, center, pCombatReach, tCombatReach.
function RaijinLab:CombatDistance(a, b)
    local center = RaijinLab:Distance2D(a, b)
    if not center then return nil end
    local ra = _sanitize_reach(RaijinLab:ObjectCombatReach(a), 100)
    local rb = _sanitize_reach(RaijinLab:ObjectCombatReach(b), 100)
    ra = ra or 1.5
    rb = rb or 1.5
    local edge = center - ra - rb
    if edge < 0 then edge = 0 end
    return edge, center, ra, rb
end

-- Self-AoE distance. Returns aoe_gap, center, extend_used.
-- In range when aoe_gap <= spell_radius (8 for Whirlwind).
function RaijinLab:AoEDistance(a, b)
    local center = RaijinLab:Distance2D(a, b)
    if not center then return nil end
    local tb = nil
    if RaijinLab.ObjectBoundingRadius then
        tb = _sanitize_reach(RaijinLab:ObjectBoundingRadius(b), 80)
    end
    tb = tb or 0
    -- Only giant models extend the disk. Humanoid ~0.3-1.5 must not.
    local extend = 0
    if tb > AOE_BOSS_BOUND then extend = tb end
    local gap = center - extend
    if gap < 0 then gap = 0 end
    return gap, center, extend
end

-- Gets the horizontal rotation of an object, in radian.
-- A facing is an angle in radians, so anything outside roughly [0, 2pi) is not a
-- facing at all - it is a bad read. This has been observed live: the heartbeat
-- logged facing=4.5e20, and every consumer (steering, cast direction, range
-- checks) silently used it. Validate at the boundary so garbage becomes nil,
-- which callers already handle, instead of a plausible-looking number.
local TWO_PI = math.pi * 2
function RaijinLab.ValidFacing(f)
    if type(f) ~= "number" then return nil end
    if f ~= f then return nil end                      -- NaN
    if f < -TWO_PI or f > 2 * TWO_PI then return nil end
    return f
end

function RaijinLab:ObjectFacing(object)
    if not object then return end
    -- LOCAL PLAYER: prefer the live movement-state facing. ObjectFacing reads the
    -- object's orientation field (0x7A4), which for the local player is not the
    -- value the client actually steers by - the live one is CMovement+0x24
    -- (0x7AC), which is what PlayerFacing reads and what the turn loop needs.
    if object == "player" then
        local A = RaijinLab.Actions
        if A and A.PlayerFacing then
            local live = RaijinLab.ValidFacing(A.PlayerFacing())
            if live then return live end
        end
    end
    return RaijinLab.ValidFacing(RLCall("ObjectFacing", object))
end

-- Checks if an object is facing another object.
--
-- COMPUTED IN LUA, deliberately. The runtime's IsFacing normalises the angle with
-- `while (diff < -PI) diff += 2PI;` - which never terminates when the facing is
-- garbage, because at a magnitude like 4.5e20 a float's ULP is ~5e13 and adding
-- 6.28 changes nothing. The local player's facing IS garbage on this client
-- (0x7A4 is not the live value; 1185/1185 logged samples were 4.5e20), so calling
-- through would risk hanging the client on a cast-facing check. Doing the maths
-- here uses the VALIDATED facing and a loop-free normalisation.
local function norm_pi(d)
    local two = math.pi * 2
    d = d % two                       -- always terminates, unlike a subtract loop
    if d > math.pi then d = d - two end
    return d
end
RaijinLab._norm_pi = norm_pi

function RaijinLab:ObjectIsFacing(object1, object2, delta)
    if not object1 or not object2 then return end
    -- delta = HALF-angle (default π/2). Matches WotLK HasInArc(M_PI) full width.
    local f = RaijinLab.ValidFacing(RaijinLab:ObjectFacing(object1))
    local ax, ay = RaijinLab:ObjectPosition(object1)
    local bx, by = RaijinLab:ObjectPosition(object2)
    if f and ax and ay and bx and by then
        local atan2 = math.atan2 or math.atan
        local ang = atan2(by - ay, bx - ax)
        local half = tonumber(delta)
        if not half then
            half = (RaijinLab.World and RaijinLab.World.CAST_FACE_HALF_ARC) or (math.pi / 2)
        end
        return math.abs(norm_pi(ang - f)) <= half
    end
    -- Could not compute it safely. Report UNKNOWN rather than calling a runtime
    -- path that can spin forever on a bad facing - a nil here is handled by
    -- callers, a frozen client is not.
    return nil
end

-- Checks if an object is behind another object.
--
-- Computed in Lua for the same reason ObjectIsFacing is: the runtime's
-- subtract-loop normalisation used to spin forever on a bad facing value, and
-- although the DLL now uses fmod, keeping the arithmetic here means a future
-- source edit that forgets to rebuild the DLL cannot re-introduce the hang.
-- Returns nil rather than a runtime call when the inputs can't be trusted.
function RaijinLab:ObjectIsBehind(object1, object2)
    if not object1 or not object2 then return end
    local f = RaijinLab.ValidFacing(RaijinLab:ObjectFacing(object2))       -- target's facing
    local ax, ay = RaijinLab:ObjectPosition(object2)                        -- target
    local bx, by = RaijinLab:ObjectPosition(object1)                        -- attacker
    if not (f and ax and ay and bx and by) then return nil end
    local atan2 = math.atan2 or math.atan
    -- Angle FROM the target TO the attacker, compared to where the target faces.
    -- If they differ by more than 90 degrees, the attacker is on the target's back.
    local ang = atan2(by - ay, bx - ax)
    return math.abs(norm_pi(ang - f)) > (math.pi / 2)
end

-- Checks if object is type unit.
function RaijinLab:ObjectIsUnit(object)
    if not object then return end
    local t = RLCall("GetObjectTypeFlagsTable")
    if type(t) == "table" and t.Unit then
        return RaijinLab:ObjectIsType(object, t.Unit)
    end
    return bit.band(RaijinLab:ObjectTypeFlags(object) or 0, RaijinLab.enums.ObjectTypeFlags.Unit) > 0

end

function RaijinLab:ObjectIsGameObject(object)
    if not object then return end
    local t = RLCall("GetObjectTypeFlagsTable")
    if type(t) == "table" and t.GameObject then
        return RaijinLab:ObjectIsType(object, t.GameObject)
    end
    return bit.band(RaijinLab:ObjectTypeFlags(object) or 0, RaijinLab.enums.ObjectTypeFlags.GameObject) > 0

end

function RaijinLab:GameObjectFlags(object)
    if not object then return end
    -- The runtime knows the object's TYPE and so reads GAMEOBJECT_FLAGS rather
    -- than UNIT_FIELD_FLAGS. The descriptor-name path below only works when the
    -- client exposes that table; it returned nil otherwise, which meant every
    -- gameobject's flag list was silently empty.
    local v = RLCall("ObjectFlags", object)
    if type(v) == "number" then return v end
    local d = RaijinLab:GetObjectDescriptorsTable()
    local vt = RaijinLab:GetValueTypesTable()
    if not d or not vt or not d.CGGameObjectData__m_createdBy then return end
    return RaijinLab:ObjectDescriptor(object, d.CGGameObjectData__m_createdBy + 32, vt.UInt)
end

-- The GO_DYNFLAG_LO_* flags are the LOW WORD of GAMEOBJECT_DYNAMIC (the high
-- word is path progress / despawn timer) - hence "LO". This used to shift right
-- by 8, which is neither the low word nor the high one: it slid the flag bits
-- off by a byte, so SPARKLE (0x20) could never be read correctly. The runtime
-- already masks, so this is now just a guard for any other caller.
function RaijinLab:GameObjectDynamicLowFlags(object)
    if not object then return end
    local dyn = RaijinLab:ObjectDynamicFlags(object)
    if type(dyn) ~= "number" then return end
    return dyn % 65536
end

--  _   _       _ _
-- | | | |     (_) |
-- | | | |_ __  _| |_
-- | | | | '_ \| | __|
-- | |_| | | | | | |_
--  \___/|_| |_|_|\__|

-- descriptors = {
--   Forward = 1,
--   Backward = 2,
--   StrafeLeft = 4,
--   StrafeRight = 8,
--   TurnLeft = 16,
--   ...
-- }
function RaijinLab:GetUnitMovementFlagsTable()
    return RLCall("GetUnitMovementFlagsTable")
end

-- Gets the creator object of an object.
function RaijinLab:UnitCreator(unit)
    if not unit then return end
    return RLCall("UnitCreator", unit)
end

-- Gets the bounding radius of an unit.
function RaijinLab:UnitBoundingRadius(unit)
    if not unit then return end
    return RLCall("UnitBoundingRadius", unit)
end

-- Gets the combat reach of an unit.
function RaijinLab:UnitCombatReach(unit)
    if not unit then return end
    return RLCall("UnitCombatReach", unit)
end

-- Gets the target object of an unit.
function RaijinLab:UnitTarget(unit)
    if not unit then return end
    return RLCall("UnitTarget", unit)
end

-- Gets the flags of an unit.
function RaijinLab:UnitFlags(unit)
    if not unit then return end
    return RLCall("UnitFlags", unit)
end

-- Gets the casting info of a unit, an enhanced version for the BLZ API UnitCastingInfo.
function RaijinLab:UnitCasting(unit)
    if not unit then return end
    return RLCall("UnitCasting", unit)
end

-- Gets the channel info of a unit, an enhanced version for the BLZ API
function RaijinLab:UnitChannel(unit)
    if not unit then return end
    return RLCall("UnitChannel", unit)
end

-- Gets the casting target object of a unit.
function RaijinLab:UnitCastingTarget(unit)
    if not unit then return end
    return RLCall("UnitCastingTarget", unit)
end

-- Gets the transport object of a unit.
function RaijinLab:UnitTransport(unit)
    if not unit then return end
    return RLCall("UnitTransport", unit)
end

-- Gets the vertical pitch of a unit, in radian.
function RaijinLab:UnitPitch(unit)
    if not unit then return end
    return RLCall("UnitPitch", unit)
end

-- Gets the movement flags of a unit, indicating its moving status.
function RaijinLab:UnitMovementFlags(unit)
    if not unit then return end
    return RLCall("UnitMovementFlags", unit)
end

-- Gets the ID of a unit's creature type.
function RaijinLab:UnitCreatureTypeId(unit)
    if not unit then return end
    return RLCall("UnitCreatureTypeId", unit)
end

-- Gets the ID of a unit's creature family. nil if the unit does not have one.
function RaijinLab:UnitCreatureFamilyId(unit)
    if not unit then return end
    return RLCall("UnitCreatureFamilyId", unit)
end

-- Gets the field value of a unit's creature cache struct.
function RaijinLab:UnitCreatureField(unit, offset, type)
    if not unit then return end
    return RLCall("UnitCreatureField", unit, offset, type)
end

-- Gets whether unit can be looted.
function RaijinLab:UnitCanBeLooted(unit)
    if not unit then return end
    return RLCall("UnitIsLootable", unit)
end

-- Gets whether unit can be skinned.
function RaijinLab:UnitIsSkinnable(unit)
    if not unit then return end
    return RLCall("UnitIsSkinnable", unit)
end

-- Gets whether unit is mounted.
function RaijinLab:UnitIsMounted(unit)
    if not unit then return end
    return RLCall("UnitIsMounted", unit)
end

-- Gets the mount display id of the unit.
function RaijinLab:UnitMountID(unit)
    if not unit then return end
    local d = RaijinLab:GetObjectDescriptorsTable()
    local v = RaijinLab:GetValueTypesTable()
    if not d or not v or not d.CGUnitData__mountDisplayID then return end
    return RaijinLab:ObjectDescriptor(unit, d.CGUnitData__mountDisplayID, v.UInt)
end

function RaijinLab:UnitIsRare(unit)
    if not unit then return end
    local classification_types = {
        rareelite = true,
        rare = true
    }
    return classification_types[UnitClassification(unit)]
end

function RaijinLab:GetUnitDynamicFlags(unit)
    if not unit then return end
    local d = RaijinLab:GetObjectDescriptorsTable()
    local v = RaijinLab:GetValueTypesTable()
    if not d or not v or not d.CGObjectData__m_dynamicFlags then return end
    return RaijinLab:ObjectDescriptor(unit, d.CGObjectData__m_dynamicFlags, v.UInt)
end

function RaijinLab:UnitIsHidden(unit, flags)
    if not unit then return end
    if not flags then
        flags = RaijinLab:ObjectDynamicFlags(unit)
    end
    if not flags then return end
    return bit.band(flags, RaijinLab.enums.UnitDynamicFlags.UNIT_DYNFLAG_HIDE_MODEL) > 0
end

function RaijinLab:ObjectIsInteractable(object, flags)
    if not object then return end
    if not flags then
        flags = RaijinLab:ObjectDynamicFlags(object)
    end
    if not flags then return end
    return not (bit.band(flags, RaijinLab.enums.GameObjectDynamicLowFlags.GO_DYNFLAG_LO_NO_INTERACT) > 0)
end
--  _____ _     _           _    ___  ___
-- |  _  | |   (_)         | |   |  \/  |
-- | | | | |__  _  ___  ___| |_  | .  . | __ _ _ __
-- | | | | '_ \| |/ _ \/ __| __| | |\/| |/ _` | '_ \
-- \ \_/ / |_) | |  __/ (__| |_  | |  | | (_| | | | |_
--  \___/|_.__/| |\___|\___|\__| \_|  |_/\__,_|_| |_(_)
--            _/ |
--           |__/

-- Gets the count of all world objects, also updates all objects.
-- Classic unlocker returns: count, isUpdated, added, removed
-- RaijinLab runtime may return only count - normalize to 4-tuple.
function RaijinLab:GetObjectCount()
    if GetTime() - cache.GetObjectCount.last_ran > cache.pop_time then
        local r = pack(RLCall("GetObjectCount"))
        local count = tonumber(r[1]) or 0
        local isUpdated = r[2]
        if r.n <= 1 or isUpdated == nil then
            -- single-value runtime: always treat as updated so OM progresses
            isUpdated = count >= 0
        end
        cache.GetObjectCount.results = { n = 4, count, isUpdated, r[3], r[4] }
        cache.GetObjectCount.last_ran = GetTime()
    end
    if not cache.GetObjectCount.results then
        return 0, false, nil, nil
    end
    return unpack(cache.GetObjectCount.results, 1, 4)
end

-- Gets a specific world object by its index.
function RaijinLab:GetObjectWithIndex(index)
    if not index then return end
    if not cache.GetObjectWithIndex[index] then
        cache.GetObjectWithIndex[index] = { last_ran = 0 }
    end
    if GetTime() - cache.GetObjectWithIndex[index].last_ran > cache.pop_time then
        local r = pack(RLCall("GetObjectWithIndex", index))
        cache.GetObjectWithIndex[index].results = r
        cache.GetObjectWithIndex[index].last_ran = GetTime()
    end
    local r = cache.GetObjectWithIndex[index].results
    if not r or r.n == 0 then return nil end
    return unpack(r, 1, r.n)
end


-- Unit-only OM count / index (runtime GetNpcCount / GetNpcWithIndex).
-- Used by quest giver scan so we do not depend solely on the filtered om.npcs
-- list, which has been empty/stale while lit !/? stood in range.
function RaijinLab:GetNpcCount()
    local n = RLCall("GetNpcCount")
    return tonumber(n) or 0
end

function RaijinLab:GetNpcWithIndex(index)
    if not index then return end
    return RLCall("GetNpcWithIndex", index)
end

-- Gets the count of all npcs, also updates npcs.
-- function RaijinLab:GetNpcCount(pointer, range)
--     if not pointer then return end
--     if not cache.GetNpcCount[pointer] then
--         cache.GetNpcCount[pointer] = { last_ran = 0 }
--     end
--     if range and not cache.GetNpcCount[pointer][range] then
--         cache.GetNpcCount[pointer][range] = { last_ran = 0 }
--     end
--     if range and GetTime() - cache.GetNpcCount[pointer][range].last_ran > cache.pop_time then
--         cache.GetNpcCount[pointer][range].results = pack(RLCall("GetNpcCount", pointer, range))
--         cache.GetNpcCount[pointer][range].last_ran = GetTime()
--     elseif not range and GetTime() - cache.GetNpcCount[pointer].last_ran > cache.pop_time then
--         cache.GetNpcCount[pointer].results = pack(RLCall("GetNpcCount", pointer))
--         cache.GetNpcCount[pointer].last_ran = GetTime()
--     end
--     if range then
--         return unpack(cache.GetNpcCount[pointer][range].results)
--     end
--     return unpack(cache.GetNpcCount[pointer].results)
-- end

-- Gets a specific npc by its index.
-- function RaijinLab:GetNpcWithIndex(index)
--     if not index then return end
--     if not cache.GetNpcWithIndex[index] then
--         cache.GetNpcWithIndex[index] = { last_ran = 0 }
--     end
--     if GetTime() - cache.GetNpcWithIndex[index].last_ran > cache.pop_time then
--         cache.GetNpcWithIndex[index].results = pack(RLCall("GetNpcWithIndex", index))
--         cache.GetNpcWithIndex[index].last_ran = GetTime()
--     end
--     return unpack(cache.GetNpcWithIndex[index].results)
-- end
--
-- -- Gets the count of specific players.
-- function RaijinLab:GetPlayerCount(pointer, range)
--     if not pointer then return end
--     if not cache.GetPlayerCount[pointer] then
--         cache.GetPlayerCount[pointer] = { last_ran = 0 }
--     end
--     if range and not cache.GetPlayerCount[pointer][range] then
--         cache.GetPlayerCount[pointer][range] = { last_ran = 0 }
--     end
--     if range and GetTime() - cache.GetPlayerCount[pointer][range].last_ran > cache.pop_time then
--         cache.GetPlayerCount[pointer][range].results = pack(RLCall("GetPlayerCount", pointer, range))
--         cache.GetPlayerCount[pointer][range].last_ran = GetTime()
--     elseif not range and GetTime() - cache.GetPlayerCount[pointer].last_ran > cache.pop_time then
--         cache.GetPlayerCount[pointer].results = pack(RLCall("GetPlayerCount", pointer))
--         cache.GetPlayerCount[pointer].last_ran = GetTime()
--     end
--     if range then
--         return unpack(cache.GetPlayerCount[pointer][range].results)
--     end
--     return unpack(cache.GetPlayerCount[pointer].results)
-- end
--
-- -- Gets the specific player by index.
-- function RaijinLab:GetPlayerWithIndex(index)
--     if not index then return end
--     if not cache.GetPlayerWithIndex[index] then
--         cache.GetPlayerWithIndex[index] = { last_ran = 0 }
--     end
--     if GetTime() - cache.GetPlayerWithIndex[index].last_ran > cache.pop_time then
--         cache.GetPlayerWithIndex[index].results = pack(RLCall("GetPlayerWithIndex", index))
--         cache.GetPlayerWithIndex[index].last_ran = GetTime()
--     end
--     return unpack(cache.GetPlayerWithIndex[index].results)
-- end
--
-- -- Gets the count of specific game objects, also updates game objects.
-- function RaijinLab:GetGameObjectCount(pointer, range)
--     if not pointer then return end
--     if not cache.GetGameObjectCount[pointer] then
--         cache.GetGameObjectCount[pointer] = { last_ran = 0 }
--     end
--     if range and not cache.GetGameObjectCount[pointer][range] then
--         cache.GetGameObjectCount[pointer][range] = { last_ran = 0 }
--     end
--     if range and GetTime() - cache.GetGameObjectCount[pointer][range].last_ran > cache.pop_time then
--         cache.GetGameObjectCount[pointer][range].results = pack(RLCall("GetGameObjectCount", pointer, range))
--         cache.GetGameObjectCount[pointer][range].last_ran = GetTime()
--     elseif not range and GetTime() - cache.GetDynamicObjectCount[pointer].last_ran > cache.pop_time then
--         cache.GetGameObjectCount[pointer].results = pack(RLCall("GetGameObjectCount", pointer))
--         cache.GetGameObjectCount[pointer].last_ran = GetTime()
--     end
--     if range then
--         return unpack(cache.GetGameObjectCount[pointer][range].results)
--     end
--     return unpack(cache.GetGameObjectCount[pointer].results)
-- end
--
-- -- Gets the specific game object by index.
-- function RaijinLab:GetGameObjectWithIndex(index)
--     if not index then return end
--     if not cache.GetGameObjectWithIndex[index] then
--         cache.GetGameObjectWithIndex[index] = { last_ran = 0 }
--     end
--     if GetTime() - cache.GetGameObjectWithIndex[index].last_ran > cache.pop_time then
--         cache.GetGameObjectWithIndex[index].results = pack(RLCall("GetGameObjectWithIndex", index))
--         cache.GetGameObjectWithIndex[index].last_ran = GetTime()
--     end
--     return unpack(cache.GetGameObjectWithIndex[index].results)
-- end

-- Gets the count of specific dynamic objects, also updates dynamic objects.
-- function RaijinLab:GetDynamicObjectCount(pointer, range)
--     if not pointer then return end
--     if not cache.GetDynamicObjectCount[pointer] then
--         cache.GetDynamicObjectCount[pointer] = { last_ran = 0 }
--     end
--     if range and not cache.GetDynamicObjectCount[pointer][range] then
--         cache.GetDynamicObjectCount[pointer][range] = { last_ran = 0 }
--     end
--     if range and GetTime() - cache.GetDynamicObjectCount[pointer][range].last_ran > cache.pop_time then
--         cache.GetDynamicObjectCount[pointer][range].results = pack(RLCall("GetDynamicObjectCount", pointer, range))
--         cache.GetDynamicObjectCount[pointer][range].last_ran = GetTime()
--     elseif not range and GetTime() - cache.GetDynamicObjectCount[pointer].last_ran > cache.pop_time then
--         cache.GetDynamicObjectCount[pointer].results = pack(RLCall("GetDynamicObjectCount", pointer))
--         cache.GetDynamicObjectCount[pointer].last_ran = GetTime()
--     end
--     if range then
--         return unpack(cache.GetDynamicObjectCount[pointer][range].results)
--     end
--     return unpack(cache.GetDynamicObjectCount[pointer].results)
-- end
--
-- -- Gets a specific dynamic object by index.
-- function RaijinLab:GetDynamicObjectWithIndex(index)
--     if not index then return end
--     if not cache.GetDynamicObjectWithIndex[index] then
--         cache.GetDynamicObjectWithIndex[index] = { last_ran = 0 }
--     end
--     if GetTime() - cache.GetDynamicObjectWithIndex[index].last_ran > cache.pop_time then
--         cache.GetDynamicObjectWithIndex[index].results = pack(RLCall("GetDynamicObjectWithIndex", index))
--         cache.GetDynamicObjectWithIndex[index].last_ran = GetTime()
--     end
--     return unpack(cache.GetDynamicObjectWithIndex[index].results)
-- end

-- Gets the count of specific area triggers
-- function RaijinLab:GetAreaTriggerCount(pointer, range)
--     if not pointer then return end
--     if not cache.GetAreaTriggerCount[pointer] then
--         cache.GetAreaTriggerCount[pointer] = { last_ran = 0 }
--     end
--     if range and not cache.GetAreaTriggerCount[pointer][range] then
--         cache.GetAreaTriggerCount[pointer][range] = { last_ran = 0 }
--     end
--     if range and GetTime() - cache.GetAreaTriggerCount[pointer][range].last_ran > cache.pop_time then
--         cache.GetAreaTriggerCount[pointer][range].results = pack(RLCall("GetAreaTriggerCount", pointer, range))
--         cache.GetAreaTriggerCount[pointer][range].last_ran = GetTime()
--     elseif not range and GetTime() - cache.GetAreaTriggerCount[pointer].last_ran > cache.pop_time then
--         cache.GetAreaTriggerCount[pointer].results = pack(RLCall("GetAreaTriggerCount", pointer))
--         cache.GetAreaTriggerCount[pointer].last_ran = GetTime()
--     end
--     if range then
--         return unpack(cache.GetAreaTriggerCount[pointer][range].results)
--     end
--     return unpack(cache.GetAreaTriggerCount[pointer].results)
-- end
--
-- -- Gets a specific AreaTrigger by index
-- function RaijinLab:GetAreaTriggerWithIndex(index)
--     if not index then return end
--     if not cache.GetAreaTriggerWithIndex[index] then
--         cache.GetAreaTriggerWithIndex[index] = { last_ran = 0 }
--     end
--     if GetTime() - cache.GetAreaTriggerWithIndex[index].last_ran > cache.pop_time then
--         cache.GetAreaTriggerWithIndex[index].results = pack(RLCall("GetAreaTriggerWithIndex", index))
--         cache.GetAreaTriggerWithIndex[index].last_ran = GetTime()
--     end
--     return unpack(cache.GetAreaTriggerWithIndex[index].results)
-- end

--  _____            _ _
-- /  ___|          | | |
-- \ `--. _ __   ___| | |
--  `--. \ '_ \ / _ \ | |
-- /\__/ / |_) |  __/ | |
-- \____/| .__/ \___|_|_|
--       | |
--       |_|

-- Checks if there is a pending spell on the cursor.
-- false (boolean): There is no cursor spell pending.
-- spellId (number): The ID of the spell pending on cursor.
function RaijinLab:IsAoEPending()
    return RLCall("IsAoEPending")
end

-- Cancels the pending spell on the cursor.
function RaijinLab:CancelPendingSpell()
    return RLCall("CancelPendingSpell")
end

--  _____ _        _
-- /  ___| |      | |
-- \ `--.| |_ __ _| |_ ___
--  `--. \ __/ _` | __/ _ \
-- /\__/ / || (_| | ||  __/
-- \____/ \__\__,_|\__\___|

-- Resets the timer for AFK
function RaijinLab:ResetAfk()
    return RLCall("ResetAfk")
end

-- Gets the name of the current WoW account. (same as the WTF subfolder)
function RaijinLab:GetCurrentAccount()
    return RLCall("GetCurrentAccount")
end

--  _   _ _     _
-- | | | (_)   (_)
-- | | | |_ ___ _  ___  _ __
-- | | | | / __| |/ _ \| '_ \
-- \ \_/ / \__ \ | (_) | | | |
--  \___/|_|___/_|\___/|_| |_|

-- World collision raycast. Returns (blocked, hitX, hitY, hitZ):
--   blocked = true when solid geometry (terrain/WMO/M2 per `flags`, default
--   0x100111) lies between the two points; hitX/Y/Z is the impact point (the end
--   point when clear). The runtime packs the result as "blocked|hx|hy|hz" because
--   multi-return is unreliable on this client (see ObjectPosition). Older/stub
--   runtimes return a bare boolean/nil -> we degrade to "not blocked".
-- Short-TTL TraceLine cache: pathfinder + navigator re-ask the same corridor
-- many times per plan. MORE rays answered per second; ~one native call per
-- quantized segment per TTL. Geometry is static within a frame cluster.
RaijinLab._tl_cache = RaijinLab._tl_cache or {}
RaijinLab._tl_n = RaijinLab._tl_n or 0
RaijinLab._tl_hits = RaijinLab._tl_hits or 0
RaijinLab._tl_miss = RaijinLab._tl_miss or 0
local TL_TTL = 0.35
local TL_CAP = 4096
local function tl_key(x1, y1, z1, x2, y2, z2, flags)
    -- 0.25yd / 0.25yd height quantize: enough for walk/wall decisions.
    local q = 4
    local function qi(v) return math.floor((v or 0) * q + 0.5) end
    return qi(x1) .. ":" .. qi(y1) .. ":" .. qi(z1) .. ":"
        .. qi(x2) .. ":" .. qi(y2) .. ":" .. qi(z2) .. ":" .. tostring(flags or 0)
end

function RaijinLab:TraceLine(x1, y1, z1, x2, y2, z2, flags)
    flags = flags or 0x100111
    local t = (GetTime and GetTime()) or 0
    local key = tl_key(x1, y1, z1, x2, y2, z2, flags)
    local c = RaijinLab._tl_cache[key]
    if c and (t - c.t) < TL_TTL then
        RaijinLab._tl_hits = RaijinLab._tl_hits + 1
        return c.b, c.hx, c.hy, c.hz, c.st
    end
    RaijinLab._tl_miss = RaijinLab._tl_miss + 1
    local r = RLCall("TraceLine", x1, y1, z1, x2, y2, z2, flags)
    local blocked, hx, hy, hz, state
    if type(r) ~= "string" then
        blocked = (r == true)
        state = blocked and "blocked" or "clear"
    else
        local b, sx, sy, sz = r:match("(%-?%d+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)")
        if not b then
            blocked = false
            state = "clear"
        elseif b == "-1" then
            -- Unknown: do not cache as a wall; inventing geometry is worse.
            return false, nil, nil, nil, "unknown"
        else
            blocked = (b == "1")
            hx, hy, hz = tonumber(sx), tonumber(sy), tonumber(sz)
            state = blocked and "blocked" or "clear"
        end
    end
    if RaijinLab._tl_n > TL_CAP then
        RaijinLab._tl_cache = {}
        RaijinLab._tl_n = 0
    end
    if not RaijinLab._tl_cache[key] then RaijinLab._tl_n = RaijinLab._tl_n + 1 end
    RaijinLab._tl_cache[key] = { t = t, b = blocked, hx = hx, hy = hy, hz = hz, st = state }
    return blocked, hx, hy, hz, state
end

-- Downward probe: the ground/floor Z directly under (x,y) starting from
-- z+up, searching down to z-down. Returns the surface Z, or nil when nothing
-- solid is within that span (a ledge / gap / deep water). Used by the navigator
-- to refuse to walk off cliffs.
function RaijinLab:TraceGround(x, y, z, up, down)
    up = up or 3.0; down = down or 30.0
    local blocked, _, _, hz, state = RaijinLab:TraceLine(x, y, z + up, x, y, z - down, 0x100111)
    -- An unknown trace is not "no floor" and not a floor either: return nil so
    -- the caller's own three-valued handling decides, rather than manufacturing
    -- a cliff out of a failed raycast.
    if state == "unknown" then return nil end
    if blocked and hz then return hz end
    return nil
end
function RaijinLab:InLineOfSight(obj1, obj2)
    if not obj1 or not obj2 then return end
    local x1, y1, z1 = RaijinLab:ObjectPosition(obj1)
    local x2, y2, z2 = RaijinLab:ObjectPosition(obj2)
    if x1 and x2 and y1 and y2 and z1 and z2 then
        return not RaijinLab:TraceLine(x1, y1, z1 + 2, x2, y2, z2 + 2, 0x100111)
    end
end
-- Gets the position of the camera.
function RaijinLab:GetCameraPosition()
    return RLCall("GetCameraPosition")
end

-- Raw camera fields (position, 3x3 view matrix rows, FOV) for a Lua-side
-- world->screen projection. Runtime packs "px|py|pz|fx|fy|fz|rx|ry|rz|ux|uy|uz|fov".
-- Cached for one frame so a whole draw pass shares one read.
function RaijinLab:GetCameraData()
    local r = RaijinLab.RuntimeCall and RaijinLab:RuntimeCall("GetCameraData")
    if type(r) ~= "string" then return nil end
    local p = {}
    for tok in r:gmatch("([%-%d%.eE]+)") do p[#p + 1] = tonumber(tok) end
    if #p < 13 then return nil end
    return {
        px = p[1], py = p[2], pz = p[3],
        fx = p[4], fy = p[5], fz = p[6],       -- view-matrix row 0 (forward)
        rx = p[7], ry = p[8], rz = p[9],       -- row 1 (right)
        ux = p[10], uy = p[11], uz = p[12],    -- row 2 (up)
        fov = p[13],
    }
end

-- Calibration knobs for the projection (adjusted live once /raijin cam confirms
-- the camera layout on this build). sign_x/sign_y flip axes; fov_scale tunes the
-- FOV interpretation; fwd/right/up select which matrix row is which.
RaijinLab.w2s = RaijinLab.w2s or { sign_x = 1, sign_y = 1, fov_scale = 1.0 }

-- Projects a world position to NORMALIZED screen coords: returns
-- (onScreen, nx, ny) with nx in [0,1] from LEFT and ny in [0,1] from BOTTOM
-- (matches the drawing layer's expectation), or false when behind the camera.
function RaijinLab.WorldToScreen(x, y, z)
    local c = RaijinLab:GetCameraData()
    if not c then return false end
    local dx, dy, dz = x - c.px, y - c.py, z - c.pz
    local camF = dx * c.fx + dy * c.fy + dz * c.fz     -- depth along view dir
    if camF <= 0.05 then return false end              -- behind / at camera
    local camR = dx * c.rx + dy * c.ry + dz * c.rz     -- right axis
    local camU = dx * c.ux + dy * c.uy + dz * c.uz     -- up axis
    local W = (WorldFrame and WorldFrame:GetWidth()) or (GetScreenWidth and GetScreenWidth()) or 1024
    local H = (WorldFrame and WorldFrame:GetHeight()) or (GetScreenHeight and GetScreenHeight()) or 768
    local k = RaijinLab.w2s
    local fov = (c.fov and c.fov > 0.1 and c.fov or 1.0) * (k.fov_scale or 1.0)
    local tanHalf = math.tan(fov * 0.5)
    if tanHalf <= 0 then return false end
    -- perspective divide; horizontal scaled by aspect
    local ndc_x = (camR / camF) / (tanHalf * (W / H)) * (k.sign_x or 1)
    local ndc_y = (camU / camF) / tanHalf * (k.sign_y or 1)
    local nx = 0.5 + 0.5 * ndc_x        -- from left
    local ny = 0.5 + 0.5 * ndc_y        -- from bottom (up is +)
    local on = nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1
    return on, nx, ny
end

function RaijinLab:CallMount()
    for i = 1, GetNumCompanions("MOUNT") do
        if C_MountJournal.GetIsFavorite(i) then
            C_Timer.After(math.random(), function() if not UnitCastingInfo("player") then C_MountJournal.SummonByID(0) end end)
            return true
        end
    end
end

----------------- MISC
function RaijinLab:DrawText(x, y, text)
    print(x .. " " .. y)
    if x == 0 or y == 0 then return end
    local screen_physical_width, screen_physical_height = GetPhysicalScreenSize();
    local scale_x = 768 / GetScreenHeight() * GetScreenWidth() / (screen_physical_width * UIParent:GetEffectiveScale());
    local scale_y = 768 / (screen_physical_height * UIParent:GetEffectiveScale());
    label = CreateFrame("Frame", nil, UIParent);
    label_font_string = label:CreateFontString(nil, "BORDER");
    label_font_string:SetPoint("TOPLEFT");
    label_font_string:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE, MONOCHROME")
    label_font_string:SetJustifyH("CENTER");
    label_font_string:SetText(text);
    label:SetWidth(label_font_string:GetStringWidth());
    label:SetHeight(label_font_string:GetStringHeight());
    print("converted " .. x * screen_physical_width * scale_x .. " " .. y * screen_physical_height * scale_y)
    label:SetPoint("BOTTOMLEFT", x * screen_physical_width * scale_x, y * screen_physical_height * scale_y);
    label:Show()
end

function RaijinLab:TraceLogObjects()
    local dCount = RaijinLab:GetDynamicObjectCount("player", 40) or 0
    local mCount = RaijinLab:GetMissileCount() or 0
    -- print("Dynamic Object Count: " .. dCount)
    -- print("Missile Count: " .. mCount)
    if dCount > 0 then
        for i = 1, dCount do
            local object = RaijinLab:GetDynamicObjectWithIndex(i)
            local typeId, typeName = RaijinLab:GameObjectType(object)
            print("Dynamic Object [" .. typeId .. "] " .. typeName)
        end
    end
    if mCount > 0 then
        for i = 1, mCount do
            local spellId, spellVisualId, x, y, z, sourceObject, sourceX, sourceY, sourceZ, targetObject, targetX, targetY, targetZ = RaijinLab:GetMissileWithIndex(i)
            local spellName = select(1, GetSpellInfo(spellId))
            if spellName == "Shadow Crash" then
                print("Missile Info: \n" .. spellName .. "\n" .. "Location: " .. x .. " " .. y .. " " .. z .. "\n" .. "Source Location: " .. sourceX .. " " .. sourceY .. " " .. sourceZ .. "\n")
                print("Target Location: " .. targetX .. " " .. targetY .. " " .. targetZ)
                local isOnScreen, sX, sY = RaijinLab:WorldToScreen(targetX, targetY, targetZ)
                print("Target screen: " .. tostring(isOnScreen) .. " " .. sX .. " " .. sY)
                RaijinLab:DrawText(sX, sY, spellName .. " TARGET")
                isOnScreen, sX, sY = RaijinLab:WorldToScreen(sourceX, sourceY, sourceZ)
                print("source screen: " .. tostring(isOnScreen) .. " " .. sX .. " " .. sY)
                RaijinLab:DrawText(sX, sY, spellName .. " SOURCE")
                isOnScreen, sX, sY = RaijinLab:WorldToScreen(x, y, z)
                print("default screen: " .. tostring(isOnScreen) .. " " .. sX .. " " .. sY)
                RaijinLab:DrawText(sX, sY, spellName .. " DEFAULT")
            end
        end
    end
end

-- movement

function RaijinLab:Face(pointer, update)
    local pointer = pointer or "target"
    RaijinLab:FaceDirection(RaijinLab:GetAnglesBetweenObjects("player", pointer), update)
end


-- security
-- Mark a hardware event so the next protected call is accepted.
--
-- This called RaijinLab:CallC("IncrementAppleCount"). There is no CallC method
-- anywhere in the addon and no IncrementAppleCount command in the bridge, so
-- every invocation would have thrown "attempt to call a nil value" - it only
-- looked harmless because nothing calls SpoofKeyPress yet. A dead landmine is
-- still a landmine, and this one sits in the security path.
--
-- ArmUnlock is the real mechanism: the runtime sets the hardware-event flag
-- itself. Returns whether the runtime accepted it, rather than pretending.
function RaijinLab:SpoofKeyPress()
    if not RaijinLab.HasRuntime or not RaijinLab:HasRuntime() then return false end
    return RaijinLab:RuntimeCall("ArmUnlock") and true or false
end

function RaijinLab:ObjectIsQuestObjectType(object)
    if not object then return end
    if not RaijinLab:ObjectIsGameObject(object) then return end
    local id, _ = RaijinLab:GameObjectType(object)
    if id == RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_GOOBER then
        return RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_GOOBER
    elseif id == RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_CHEST then
        return RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_CHEST
    elseif id == RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_GENERIC then
        return RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_GENERIC
    end
end
-- quests
function RaijinLab:GameObjectIsQuestObjective(object, type)
    if not object then return end
    local flags = RaijinLab:ObjectDynamicFlags(object)
    if type ~= "number" and tonumber(flags) == nil then return nil end
    local G = RaijinLab.GOFlags
    if not G then return nil end
    G.observe(flags)
    local sp = G.sparkle()
    if not sp then return nil end          -- mapping unproven: say "cannot tell"
    local lo = math.floor(tonumber(flags) or 0) % 65536
    local function has(f) return math.floor(lo / f) % 2 == 1 end
    -- A GENERIC object only counts when it actually sparkles; anything else may
    -- also qualify by being interactable.
    if type == RaijinLab.enums.GameObjectTypes.GAMEOBJECT_TYPE_GENERIC then
        return has(sp)
    end
    local interesting = G.is_interesting(lo)
    if interesting == nil then return nil end
    return interesting
end

function RaijinLab:GetObjectQuestGiverStatusesTable()
    return RLCall('GetObjectQuestGiverStatusesTable')
end

-- Pass GUIDs through for status / instance reads. Unit tokens resolve; hex
-- strings ("0xF13...") pass as-is.
-- LIVE BUG (1.8.24): suite scans passed OM *structs* (Lua tables). C++ GuidArg
-- saw s='table: 74xxxxxx' / '0x0' -> every ObjectQuestGiverStatus returned 0 while
-- giverprobe(UnitGUID) still worked. Always unwrap tables to .Guid first.
local function status_guid_arg(object)
    if object == nil then return nil end
    -- OM struct / accidental table: pull the string GUID field.
    if type(object) == "table" then
        object = object.Guid or object.Object or object.guid or object.GUID
        if object == nil then return nil end
        if type(object) == "table" then return nil end  -- still nested: refuse
    end
    if type(object) == "string" then
        local s = object:match("^%s*(.-)%s*$") or object
        if s == "" or s == "nil" or s == "0" or s == "0x0" or s == "0X0" then
            return nil
        end
        if s:match("^table:") then return nil end
        if s == "player" or s == "target" or s == "focus" or s == "mouseover"
            or s == "pet" or s:match("^party%d") or s:match("^raid%d")
            or s:match("^nameplate%d") then
            return resolve_object_arg(s)
        end
        if not s:match("^0[xX]") and s:match("^%x+$") and #s >= 8 then
            s = "0x" .. s
        end
        return s
    end
    if type(object) == "number" then
        if object == 0 then return nil end
        return resolve_object_arg(object)
    end
    return nil
end

function RaijinLab:ObjectQuestGiverStatus(object)
    if not object then return end
    local g = status_guid_arg(object)
    if not g then return 0 end
    return RLCall('ObjectQuestGiverStatus', g)
end

-- UNIT_NPC_FLAGS (descriptor). QUESTGIVER capability bit = 0x2. Separate from
-- DialogStatus (!/?); use for candidate filtering when status is empty.
function RaijinLab:ObjectNpcFlags(object)
    if not object then return end
    local g = status_guid_arg(object)
    if not g then return end
    return RLCall('ObjectNpcFlags', g)
end

-- CGObject instance field (NOT descriptor). DialogStatus = ObjectInstanceField(g, 0x90).
function RaijinLab:ObjectInstanceField(object, offset)
    if not object then return end
    local g = status_guid_arg(object)
    if not g then return end
    return RLCall('ObjectInstanceField', g, offset or 0)
end

function RaijinLab:ObjectQuestGiverDiag(object)
    if not object then return end
    local g = status_guid_arg(object)
    if not g then return end
    return RLCall('ObjectQuestGiverDiag', g)
end

function RaijinLab:GetPacketOpcodes()
    return RLCall('GetPacketOpcodes')
end

function RaijinLab:EnablePacketLogger(isSendEnabled, isReceiveEnabled, filePath, filteredOpcodes)
    return RLCall('EnablePacketLogger', isSendEnabled, isReceiveEnabled, filePath, filteredOpcodes)
end

function RaijinLab:IsPacketLoggerEnabled()
    return RLCall('IsPacketLoggerEnabled')
end

local tool_tip = CreateFrame("GameTooltip", "QuestPlateTooltipScanQuest", nil, "GameTooltipTemplate")
function RaijinLab:ScanToolTipForQuestInfo(guid, id)
    tool_tip:SetOwner(_G.WorldFrame, 'ANCHOR_NONE')
    tool_tip:SetUnit(guid)
    local tooltip_text = {}
    local count = tool_tip:NumLines()
    for i = 1, count do
        tooltip_text[i] = _G["QuestPlateTooltipScanQuestTextLeft" .. i]
    end
    local quest_name = nil
    local objective = nil
    if count >= 4 then
        quest_name = tooltip_text[3]:GetText()
        objective = tooltip_text[4]:GetText()

    elseif count == 3 then
        quest_name = tooltip_text[2]:GetText()
        objective = tooltip_text[3]:GetText()
    end
    if quest_name and objective then
        local p1, p2 = objective:match("(%d+)/(%d+)")
        if not p1 then
            p1 = objective:match("(%d+)%%")
        end
        if (p1 and p2 and p1 ~= p2) or (p1 and not p2 and p1 ~= 100) then
            RaijinLab.QuestRelationMap[id] = { p1 = p1, p2 = p2}
        else
            RaijinLab.QuestRelationMap[id] = nil
        end
    end
    return RaijinLab.QuestRelationMap[id] ~= nil
end

function RaijinLab:ObjectIsQuestObjective(object, id, guid, unknown)
    if not object then return end
    if RaijinLab.quests.wipe_quest_object_cache then
        cache.ObjectIsQuestObjective = {}
        RaijinLab.quests.wipe_quest_object_cache = false
    end
    if not cache.ObjectIsQuestObjective[id] then
        cache.ObjectIsQuestObjective[id] = { last_ran = 0 }
    end
    if GetTime() - cache.ObjectIsQuestObjective[id].last_ran > 2 then
        -- THE BRIDGE ANSWERS 0 FOR "I DO NOT KNOW", AND 0 IS TRUTHY IN LUA.
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
        if res == nil then res = false end   -- no source could tell: not an objective
        cache.ObjectIsQuestObjective[id].results = pack(res)
        cache.ObjectIsQuestObjective[id].last_ran = GetTime()
    end
    return unpack(cache.ObjectIsQuestObjective[id].results)
end

function RaijinLab:GetQuestObjectiveMap()
    local QuestIdObjectiveMap = {}
    local ObjectiveNameQuestIdMap = {}
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local quest_id = C_QuestLog.GetQuestIDForLogIndex(i)
        local quest_obj_table = {}
        for j = 1, GetNumQuestLeaderBoards(i) do
            local description, type, completed = GetQuestLogLeaderBoard(j, i)
            local current, required, text = description:match("([%d]+)/([%d]+)%s-(.*)")
            local struct = {
                current = current,
                required = required,
                name = nil,
                type = type,
                description = description
            }
            if not completed then
                if type == "item" then
                    local name = text
                    struct.name = name
                elseif type == "monster" then
                    local words = split(text, " ")
                    -- pop last element, slain/kill/etc
                    table.remove(words)
                    struct.name = table.concat(words, " ")
                elseif type == "object" then
                    struct.name = text
                end
            end
            table.insert(quest_obj_table, struct)
            ObjectiveNameQuestIdMap[struct.name] = quest_id
        end
        QuestIdObjectiveMap[quest_id] = quest_obj_table
    end
end
-- function RaijinLab:IsQuestObject(object)
--     if not object then return end
--     local id = RaijinLab:ObjectId(object)
--     if RaijinLab.quests.wipe_quest_object_cache then
--         cache.IsQuestObject = {}
--         RaijinLab.quests.wipe_quest_object_cache = false
--     end
--     if not cache.IsQuestObject[id] then
--         cache.IsQuestObject[id] = { last_ran = 0 }
--     end
--
--     if GetTime() - cache.IsQuestObject[id].last_ran > 2 then
--         RaijinLab.quests.force_quest_object = false
--         -- if RaijinLab:UnitIsTracked(object) then cache.IsQuestObject[object].results = true cache.IsQuestObject[object].last_ran = GetTime() end
--         RaijinLab.quests.frames.quest_tooltip:SetOwner(_G.WorldFrame, 'ANCHOR_NONE')
--         RaijinLab.quests.frames.quest_tooltip:SetHyperlink('unit:' .. RaijinLab:ObjectGUID(object))
--         if UnitName(object) == "Forgotten Memorandum" then
--             MEMOR_TOOLTIP = RaijinLab:ObjectGUID(object)
--             MEMOR_ID = id
--             local flags = RaijinLab:ObjectDynamicFlags(object)
--             print("0x4: " .. bit.band(flags, 0x4))
--             print("0x20: " .. bit.band(flags, 0x20))
--         end
--         for i = 1, RaijinLab.quests.frames.quest_tooltip:NumLines() do
--             RaijinLab.quests.ScannedQuestTextCache[i] = _G["QuestPlateTooltipScanQuestTextLeft" .. i]
--         end
--
--         local is_quest_unit = false
--         local one_quest_unfinished = false
--
--         for i = 1, #RaijinLab.quests.ScannedQuestTextCache do
--             local text = RaijinLab.quests.ScannedQuestTextCache[i]:GetText()
--             if RaijinLab.quests.QuestCache[text] then
--                 is_quest_unit = true
--                 local j = i
--                 while(RaijinLab.quests.ScannedQuestTextCache[j + 1]) do
--                     local next_line_text = RaijinLab.quests.ScannedQuestTextCache[j + 1]:GetText()
--                     if next_line_text then
--                         if not next_line_text:match(THREAT_TOOLTIP) then
--                             local p1, p2 = next_line_text:match("(%d+)/(%d+)")
--                             if not p1 then
--                                 p1 = next_line_text:match ("(%d+%%)")
--                                 if p1 then
--                                     p1 = string.gsub(p1, "%%", '')
--                                 end
--                             end
--                             if (p1 and p2 and p1 ~= p2) or (p1 and not p2 and p1 ~= 100) then
--                                 one_quest_unfinished = true
--                             end
--                         else
--                             j = 99
--                         end
--                     end
--                     j = j + 1
--                 end
--             end
--         end
--         if UnitName(object) == "Forgotten Memorandum" then
--             print("is_quest " .. tostring(is_quest_unit))
--             print("one_quest_unf" .. tostring(one_quest_unfinished))
--         end
--         cache.IsQuestObject[id].results = pack((is_quest_unit and one_quest_unfinished and (not UnitIsDeadOrGhost(object) or UnitIsFriend("player", object))))
--         cache.IsQuestObject[id].last_ran = GetTime()
--     end
--     return unpack(cache.IsQuestObject[id].results)
-- end
--
-- function RaijinLab:InitTooltipScanner()
--
--
-- end
--
-- function RaijinLab:DestroyQuestScanner()
--
--
-- end
--
-- function RaijinLab:InitQuestScanner()
--     local function UpdateQuestCache()
--         wipe(RaijinLab.quests.QuestCache)
--
--         if IsInInstance() then return end
--
--         --update the quest cache
--         local n_entries, n_quests = C_QuestLog.GetNumQuestLogEntries()
--         for i = 1, n_entries do
--             -- local title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, id, startEvent, displayid, isOnMap, hasLocalPOI, isTask, isStory = GetQuestLogTitle (id)
--             local title, _, id = C_QuestLog.GetInfo(i)
--             if type (id) == "number" and id > 0 then -- and not isComplete
--                 RaijinLab.quests.QuestCache[title] = true
--             end
--         end
--
--         local map_id = C_Map.GetBestMapForUnit ("player")
--         if (map_id) then
--             local map_info = C_Map.GetMapInfo(map_id)
--             if map_info.mapType == Enum.UIMapType.Micro then map_id = map_info.parentmap_id end
--             local world_quests = C_TaskQuest.GetQuestsForPlayerBymap_id (map_id)
--             if (type (world_quests) == "table") then
--                 for _, questTable in ipairs (world_quests) do
--                     local x, y, floor, numObjectives, id, inProgress = questTable.x, questTable.y, questTable.floor, questTable.numObjectives, questTable.id, questTable.inProgress
--                     if (type (id) == "number" and id > 0 and ignoreQuest[id] == nil) then
--                         local name = C_TaskQuest.GetQuestInfoByid (id)
--                         if (name) then
--                             RaijinLab.quests.QuestCache[name] = true
--                         end
--                     end
--                 end
--             end
--         end
--     end
--     local function QuestCacheOnUpdate(self, event, ...)
--         if not self.last_time then
--             self.last_time = 0
--         end
--         if GetTime() - self.last_time > 1 then
--             UpdateQuestCache()
--             self.last_time = GetTime()
--         end
--     end
--     RaijinLab.quests.wipe_quest_object_cache = false
--     RaijinLab.quests.active = true
--     RaijinLab.quests.frames = {}
--     RaijinLab.quests.QuestCache = {}
--     RaijinLab.quests.frames.quest_scanner = CreateFrame("Frame", "QuestFrame", UIParent)
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_ACCEPTED")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_REMOVED")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_ACCEPT_CONFIRM")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_COMPLETE")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_POI_UPDATE")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_DETAIL")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_FINISHED")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_GREETING")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("QUEST_LOG_UPDATE")
--     RaijinLab.quests.frames.quest_scanner:RegisterEvent ("UNIT_QUEST_LOG_CHANGED")
--     RaijinLab.quests.frames.quest_scanner:SetScript("OnEvent", QuestCacheOnUpdate)
-- end
--
-- function RaijinLab:DestroyQuestScanner()
--     RaijinLab.quests.frames.quest_scanner:SetScript("OnEvent", nil)
--     RaijinLab.quests.frames.quest_scanner = nil
--     RaijinLab.quests.QuestCache = {}
--     RaijinLab.quests.ScannedQuestTextCache = {}
--     RaijinLab.quests.active = false
-- end

function RaijinLab:EnableQuestTracker()
    -- if RaijinLab.quests.active then
    --     RaijinLab:DestroyQuestScanner()
    -- end
    -- RaijinLab:InitQuestScanner()
    -- RaijinLab:InitTooltipScanner()
    RaijinLabDB.objects_to_track.quest = {}
    RaijinLabDB.enabled_lists.quest = true
end

function RaijinLab:GetTooltipForId(id)
    if not id then return end
    return RaijinLab.tooltips[id]
end

function RaijinLab:GPS()
    local mapId, zoneId = RaijinLab:GetCurrentMapInfo()
    if not RaijinLab:IsMapLoaded(mapId) then
        RaijinLab:LoadMap(mapId)
    end
    local x, y, z = RaijinLab:ObjectPosition("player")
    local tile_x, tile_y = RaijinLab:GetMeshTile(mapId, x, y, z)
    print(mapId .. " " .. zoneId .. " " .. tile_x .. " " .. tile_y .. " " .. x .. " " .. y .. " " .. z)
end
