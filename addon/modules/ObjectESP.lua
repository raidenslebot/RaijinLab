-- ObjectESP - draw every object's identity ON the object, in the world.
--
-- WHY THIS EXISTS. Ascension's custom objects are not in any database, so the
-- addon can only ever print a GUID for them - and a chat listing of forty GUIDs
-- cannot tell you WHICH of them is the sparkling bag two yards away. Every
-- question of the form "what is that thing" has cost a round trip: dump a list,
-- describe the object in words, guess which line matches.
--
-- Putting the id on the object removes the matching step entirely. You look at
-- the bag, you read its entry id, and the answer is unambiguous because it is
-- attached to the thing itself.
--
-- Deliberately shows the RAW facts: entry id, gameobject type, and the dynamic
-- flag low word. Those are the three values every open question about object
-- identification has turned on, and a label that showed a friendly name would
-- hide exactly the objects that have none.

local ESP = {}
RaijinLab.ObjectESP = ESP

ESP.enabled = false
ESP.mode = "objects"      -- "objects" (gameobjects) | "all" (adds npcs/players)
ESP.range = 150           -- yards; beyond this the label is unreadable anyway
ESP.max_labels = 70       -- hard cap: this runs at 30Hz on a 32-bit client

local DRAW_KEY = "object_esp"

-- Name a gameobject type from the enum. The enum is 0-based and source-guarded
-- (it shipped +1 for a long time, which is why CHEST never matched), so naming
-- from it is safe now; an unknown value is shown as a number rather than guessed.
local function type_name(t)
    if type(t) ~= "number" then return nil end
    local inv = RaijinLab.enums and RaijinLab.enums.GameObjectTypesInverted
    local n = inv and inv[t]
    if not n then return "t" .. tostring(t) end
    return (string.gsub(n, "GAMEOBJECT_TYPE_", ""))
end

-- The label for one object. PURE - takes values, returns a string - so the tests
-- can check it without a client, a camera, or a frame.
function ESP.label(entry, gotype, lowflags, name)
    local parts = {}
    parts[#parts + 1] = tostring(entry or "?")
    local tn = type_name(gotype)
    if tn then parts[#parts + 1] = tn end
    if type(lowflags) == "number" and lowflags > 0 then
        parts[#parts + 1] = string.format("0x%02X", lowflags)
    end
    -- A real name is worth showing when we have one, but it must never REPLACE
    -- the id: the objects that matter most here are the ones with no name, and a
    -- GUID string is not a name.
    if type(name) == "string" and name ~= "" and string.sub(name, 1, 1) ~= "<" then
        parts[#parts + 1] = string.sub(name, 1, 24)
    end
    return table.concat(parts, " ")
end

-- Which objects to label, nearest first, capped. Pure given the list + position.
function ESP.pick(list, px, py, pz, range, cap)
    local out = {}
    if not (list and px) then return out end
    for i = 1, #list do
        local o = list[i]
        local x, y, z = o and o.X, o and o.Y, o and o.Z
        if not x and o and o.Guid and RaijinLab.ObjectPosition then
            x, y, z = RaijinLab:ObjectPosition(o.Guid)
        end
        if x and y then
            local dx, dy, dz = x - px, y - py, (z or pz or 0) - (pz or 0)
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d <= (range or 150) then
                out[#out + 1] = { o = o, x = x, y = y, z = z or pz, d = d }
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    -- Truncate AFTER sorting: the nearest objects are the ones being asked about,
    -- and an arbitrary 70 of 200 would usually miss them.
    while #out > (cap or 70) do table.remove(out) end
    return out
end

-- PUBLIC so the tests can run a whole draw pass against a stub canvas. This was
-- a local, which is precisely why a bug that drew every label at alpha 0.01
-- shipped: nothing outside the client could execute this code path at all.
function ESP.draw()
    if not ESP.enabled then return end
    local D = RaijinLab.drawing
    local L = RaijinLab.om and RaijinLab.om.object_list
    if not (D and D.Text and L and RaijinLab.ObjectPosition) then return end
    local px, py, pz = RaijinLab:ObjectPosition("player")
    if not px then return end

    local lists = { L.gameobjects }
    if ESP.mode == "all" then
        lists[#lists + 1] = L.npcs
        lists[#lists + 1] = L.players
    end

    local drawn = 0
    for li = 1, #lists do
        local picks = ESP.pick(lists[li], px, py, pz, ESP.range,
                               ESP.max_labels - drawn)
        for i = 1, #picks do
            local p = picks[i]
            local o = p.o
            local dyn = o.DynamicFlags and o.DynamicFlags.value
            local lo = (type(dyn) == "number") and (dyn % 65536) or nil
            local gotype = nil
            if o.Guid and RaijinLab.RuntimeCall then
                local b1 = tonumber(RaijinLab:RuntimeCall("GameObjectBytes1", o.Guid))
                if b1 and b1 > 0 then gotype = math.floor(b1 / 256) % 256 end
            end
            -- A flagged object is the interesting one, so colour it apart. Colour
            -- is set per-label because the pool shares one font object.
            -- SetColorRaw, NOT SetColor. SetColor scales: RGB by 1/256 and
            -- alpha by 1/100, so it wants 0-255 and 0-100. Passing 0-1 values to
            -- it yields alpha 0.01 and a near-black colour - labels drawn every
            -- frame, perfectly invisible, with no error anywhere. SetColorRaw
            -- takes the values as given.
            if D.SetColorRaw then
                if lo and lo > 0 then D:SetColorRaw(1, 0.85, 0.1, 1)
                else D:SetColorRaw(0.55, 0.85, 1, 1) end
            end
            D:Text(ESP.label(o.Id, gotype, lo, o.Name), p.x, p.y, (p.z or 0) + 1.2,
                   o.Id)
            drawn = drawn + 1
        end
        if drawn >= ESP.max_labels then break end
    end
end

function ESP.start()
    if not (RaijinLab.AddDrawingCallback and RaijinLab.GetDrawingObject) then
        return false, "drawing subsystem unavailable (runtime required)"
    end
    if not RaijinLab:GetDrawingObject() then
        if RaijinLab.InitDrawing then RaijinLab:InitDrawing() end
    end
    if not RaijinLab:GetDrawingObject() then
        return false, "drawing needs the injected runtime (WorldToScreen)"
    end
    ESP.enabled = true
    RaijinLab:AddDrawingCallback(DRAW_KEY, ESP.draw)
    return true
end

function ESP.stop()
    ESP.enabled = false
    if RaijinLab.RemoveDrawingCallback then
        RaijinLab:RemoveDrawingCallback(DRAW_KEY)
    end
    return true
end

function ESP.toggle()
    if ESP.enabled then
        ESP.stop()
        return false
    end
    return ESP.start()
end

return ESP
