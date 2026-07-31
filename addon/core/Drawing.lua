local sin, cos, atan, atan2, sqrt, rad = math.sin, math.cos, math.atan, (math.atan2 or math.atan), math.sqrt, math.rad
local onDrawTicker

local WorldToScreen_Original = RaijinLab.WorldToScreen

-- we create this table here because we use it to store these functions
RaijinLab.drawing = {}
-- WorldToScreen_Original (RaijinLab.WorldToScreen) now returns (onScreen, nx, ny)
-- with nx in [0,1] from the LEFT and ny in [0,1] from the BOTTOM. Convert to
-- canvas TOPLEFT-anchored pixel offsets (+x right, +y up), so a point below the
-- top edge gets a negative y. Uses the real WorldFrame size, not a hardcoded
-- resolution, so it's correct at any window size.
function RaijinLab.drawing:WorldToScreen(wX, wY, wZ)
    local isOnScreen, nx, ny = WorldToScreen_Original(wX, wY, wZ)
    if not nx or not ny then return nil, nil, isOnScreen end
    local W = WorldFrame:GetWidth()
    local H = WorldFrame:GetHeight()
    return nx * W, -(1 - ny) * H, isOnScreen
end

function RaijinLab.drawing:SetColor(r, g, b, a)
    private.line.r = r * 0.00390625
    private.line.g = g * 0.00390625
    private.line.b = b * 0.00390625
    if a then
        private.line.a = a * 0.01
    else
        private.line.a = 1
    end
end

function RaijinLab.drawing:SetColorRaw(r, g, b, a)
    private.line.r = r
    private.line.g = g
    private.line.b = b
    private.line.a = a
end

function RaijinLab.drawing:SetWidth(w)
    private.line.w = w
end

function RaijinLab.drawing:Line(sx, sy, sz, ex, ey, ez)
    if not sx or not ex then return end
    local sx, sy, isOnScreen = RaijinLab.drawing:WorldToScreen(sx, sy, sz)
    local ex, ey, isOnScreen2 = RaijinLab.drawing:WorldToScreen(ex, ey, ez)
    if not sx or not sy or not ex or not ey then return end
    RaijinLab.drawing:Draw2DLine(sx, sy, ex, ey)
end

local function rotateX(cx, cy, cz, px, py, pz, r)
    if r == nil then return px, py, pz end
    local s = sin(r)
    local c = cos(r)
    -- center of rotation
    px, py, pz = px - cx, py - cy, pz - cz
    local x = px + cx
    local y = ((py * c - pz * s) + cy)
    local z = ((py * s + pz * c) + cz)
    return x, y, z
end

local function rotateY(cx, cy, cz, px, py, pz, r)
    if r == nil then return px, py, pz end
    local s = sin(r)
    local c = cos(r)
    -- center of rotation
    px, py, pz = px - cx, py - cy, pz - cz
    local x = ((pz * s + px * c) + cx)
    local y = py + cy
    local z = ((pz * c - px * s) + cz)
    return x, y, z
end

local function rotateZ(cx, cy, cz, px, py, pz, r)
    if r == nil then return px, py, pz end
    local s = sin(r)
    local c = cos(r)
    -- center of rotation
    px, py, pz = px - cx, py - cy, pz - cz
    local x = ((px * c - py * s) + cx)
    local y = ((px * s + py * c) + cy)
    local z = pz + cz
    return x, y, z
end

function RaijinLab.drawing:Array(vectors, x, y, z, rotationX, rotationY, rotationZ)
    for _, vector in ipairs(vectors) do
        local sx, sy, sz = x + vector[1], y + vector[2], z + vector[3]
        local ex, ey, ez = x + vector[4], y + vector[5], z + vector[6]

        if rotationX then
            sx, sy, sz = rotateX(x, y, z, sx, sy, sz, rotationX)
            ex, ey, ez = rotateX(x, y, z, ex, ey, ez, rotationX)
        end
        if rotationY then
            sx, sy, sz = rotateY(x, y, z, sx, sy, sz, rotationY)
            ex, ey, ez = rotateY(x, y, z, ex, ey, ez, rotationY)
        end
        if rotationZ then
            sx, sy, sz = rotateZ(x, y, z, sx, sy, sz, rotationZ)
            ex, ey, ez = rotateZ(x, y, z, ex, ey, ez, rotationZ)
        end

        local sx, sy, isOnScreen = RaijinLab.drawing:WorldToScreen(sx, sy, sz)
        local ex, ey, isOnScreen2 = RaijinLab.drawing:WorldToScreen(ex, ey, ez)
        if not sx or not sy or not ex or not ey then return end
        RaijinLab.drawing:Draw2DLine(sx, sy, ex, ey)
    end
end

-- PURE quad math for a thick 2D line, extracted so it is testable headless.
--
-- Inputs are CENTER-origin, +y-up pixel coords. Returns the texture rectangle
-- (centre +/- Bwid/Bhgt) and the 8-argument SetTexCoord corners that rotate the
-- texture onto the segment. This is the wrath-era rotated-texture technique
-- (Blizzard's own TexCoord transform, as used by Routes/Cartographer) - the
-- ONLY way to draw an arbitrary line on 3.3.5, because CreateLine and friends
-- do not exist until Legion.
function RaijinLab.drawing.line_quad(ax, ay, bx, by, w)
    local dx, dy = bx - ax, by - ay
    if dx < 0 then
        ax, ay, bx, by = bx, by, ax, ay
        dx, dy = -dx, -dy
    end
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.5 then return nil end
    w = w or 1
    local cx, cy = (ax + bx) * 0.5, (ay + by) * 0.5
    local sn, cs = -dy / l, dx / l
    local sc = sn * cs
    local Bwid, Bhgt, BLx, BLy, TLx, TLy, BRx, BRy, TRx, TRy
    if dy >= 0 then
        Bwid = ((l * cs) - (w * sn)) * 0.5
        Bhgt = ((w * cs) - (l * sn)) * 0.5
        BLx, BLy, BRy = (w / l) * sc, sn * sn, (l / w) * sc
        BRx, TLx, TLy, TRx = 1 - BLy, BLy, 1 - BRy, 1 - BLx
        TRy = BRx
    else
        Bwid = ((l * cs) + (w * sn)) * 0.5
        Bhgt = ((w * cs) + (l * sn)) * 0.5
        BLx, BLy, BRx = sn * sn, -(l / w) * sc, 1 + (w / l) * sc
        BRy, TLx, TLy, TRy = BLx, 1 - BRx, 1 - BLx, 1 - BLy
        TRx = TLy
    end
    return cx, cy, Bwid, Bhgt, TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy
end

function RaijinLab.drawing:Draw2DLine(sx, sy, ex, ey)
    if not sx or not sy or not ex or not ey then
        return
    end
    -- THE ORIGINAL NEVER DREW ANYTHING, EVER. It used CreateLine/SetThickness/
    -- SetColorTexture/SetStartPoint - all Legion (7.0+) APIs that do not exist
    -- on this client. The first call threw, the callback pcall swallowed it,
    -- and the canvas stayed empty while projection, ticker and toggles were all
    -- healthy. The pool now holds plain Textures rotated via SetTexCoord.
    local T = tremove(private.lines)
    if not T then
        T = private.canvas:CreateTexture(nil, "BACKGROUND")
        -- solid 8x8 white; ships with the 3.3.5 client, tinted per line below
        T:SetTexture("Interface\\Buttons\\WHITE8X8")
    end
    T:SetVertexColor(private.line.r, private.line.g, private.line.b, private.line.a)
    tinsert(private.lines_used, T)

    -- convert Drawing's TOPLEFT/-y-down pixels to CENTER/+y-up for the quad
    local W = private.canvas:GetWidth() or 0
    local H = private.canvas:GetHeight() or 0
    local cx, cy, Bwid, Bhgt, TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy =
        RaijinLab.drawing.line_quad(sx - W * 0.5, sy + H * 0.5,
                                    ex - W * 0.5, ey + H * 0.5,
                                    private.line.w or 1)
    if not cx then
        T:Hide()
        return
    end
    T:SetTexCoord(TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy)
    T:ClearAllPoints()
    T:SetPoint("BOTTOMLEFT", private.canvas, "CENTER", cx - Bwid, cy - Bhgt)
    T:SetPoint("TOPRIGHT", private.canvas, "CENTER", cx + Bwid, cy + Bhgt)
    T:Show()
end

local flags = bit.bor(0x100)
local full_circle = rad(365)
local small_circle_step = rad(3)

function RaijinLab.drawing:Circle(x, y, z, size)
    local lx, ly, nx, ny, fx, fy = false, false, false, false, false, false
    for v = 0, full_circle, small_circle_step do
        nx, ny, isOnScreen = RaijinLab.drawing:WorldToScreen( (x + cos(v) * size), (y + sin(v) * size), z )
        if not isOnScreen then return end
        if not nx or not ny then return end
        RaijinLab.drawing:Draw2DLine(lx, ly, nx, ny)
        lx, ly = nx, ny
    end
end

function RaijinLab.drawing:GroundCircle(x, y, z, size)
    local lx, ly, nx, ny, fx, fy, fz = false, false, false, false, false, false, false
    for v = 0, full_circle, small_circle_step do
        fx, fy, fz = TraceLine( (x + cos(v) * size), (y + sin(v) * size), z + 100, (x + cos(v) * size), (y + sin(v) * size), z - 100, flags )
        if fx == nil then
            fx, fy, fz = (x + cos(v) * size), (y + sin(v) * size), z
        end
        nx, ny, isOnScreen = RaijinLab.drawing:WorldToScreen( (fx + cos(v) * size), (fy + sin(v) * size), fz )
        if not isOnScreen then return end
        if not nx or not ny then return end
        RaijinLab.drawing:Draw2DLine(lx, ly, nx, ny)
        lx, ly = nx, ny
    end
end

function RaijinLab.drawing:Arc(x, y, z, size, arc, rotation)
    local lx, ly, nx, ny, fx, fy = false, false, false, false, false, false
    local half_arc = arc * 0.5
    local ss = (arc / half_arc)
    local as, ae = -half_arc, half_arc
    for v = as, ae, ss do
        nx, ny, isOnScreen = RaijinLab.drawing:WorldToScreen( (x + cos(rotation + rad(v)) * size), (y + sin(rotation + rad(v)) * size), z )
        if not isOnScreen then return end
        if not nx or not ny then return end
        if lx and ly then
            RaijinLab.drawing:Draw2DLine(lx, ly, nx, ny)
        else
            fx, fy = nx, ny
        end
        lx, ly = nx, ny
    end
    local px, py, isOnScreen = RaijinLab.drawing:WorldToScreen(x, y, z)
    if not isOnScreen then return end
    if not px or not py then return end
    RaijinLab.drawing:Draw2DLine(px, py, lx, ly)
    RaijinLab.drawing:Draw2DLine(px, py, fx, fy)
end

function RaijinLab.drawing:Texture(config, x, y, z, alphaA)
    local function Distance(ax, ay, az, bx, by, bz)
        return math.sqrt(((bx - ax) * (bx - ax)) + ((by - ay) * (by - ay)) + ((bz - az) * (bz - az)))
    end
    local texture, width, height = config.texture, config.width, config.height
    local left, right, top, bottom, scale = config.left, config.right, config.top, config.bottom, config.scale
    local alpha = config.alpha or alphaA

    if not texture or not width or not height or not x or not y or not z then return end
    if not left or not right or not top or not bottom then
        left = 0
        right = 1
        top = 0
        bottom = 1
    end
    if not scale then
        local cx, cy, cz = RaijinLab:GetCameraPosition()
        scale = width / Distance(x, y, z, cx, cy, cz)
    end

    local sx, sy, isOnScreen = RaijinLab.drawing:WorldToScreen(x, y, z)
    if not isOnScreen then return end
    if not sx or not sy then return end
    local w = width * scale
    local h = height * scale
    sx = sx - w * 0.5
    sy = sy + h * 0.5
    local ex, ey = sx + w, sy - h

    local T = tremove(private.textures) or false
    if T == false then
        T = private.canvas:CreateTexture(nil, "BACKGROUND")
        T:SetDrawLayer(private.level)
        T:SetTexture(private.texture)
    end
    tinsert(private.textures_used, T)
    T:ClearAllPoints()
    T:SetTexCoord(left, right, top, bottom)
    T:SetTexture(texture)
    T:SetWidth(width)
    T:SetHeight(height)
    T:SetPoint("TOPLEFT", private.canvas, "TOPLEFT", sx, sy)
    T:SetPoint("BOTTOMRIGHT", private.canvas, "TOPLEFT", ex, ey)
    T:SetVertexColor(1, 1, 1, 1)
    if alpha then T:SetAlpha(alpha) else T:SetAlpha(1) end
    T:Show()
end

local i = 0
function RaijinLab.drawing:Text(text, x, y, z, refid)
    local sx, sy, isOnScreen = RaijinLab.drawing:WorldToScreen(x, y, z)
    if not isOnScreen then return end
    if not sx or not sy then return end
    local B = tremove(private.buttons)
    if not B then
        B = CreateFrame("Button", "RaijinLabDrawingButton" .. i, private.canvas, "UIPanelButtonTemplate")
        B:DisableDrawLayer("BACKGROUND")
        B:SetHighlightTexture(nil)
        B:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            local text = RaijinLab:GetTooltipForId(refid)
            if not text then return end
            GameTooltip:AddLine(text)
            GameTooltip:Show()
        end)
        B:SetScript("OnLeave", function() GameTooltip:ClearLines() GameTooltip:Hide() end)
    end
    B:SetNormalFontObject("GameFontNormalSmall")
    local font = B:GetNormalFontObject()
    font:SetTextColor(private.line.r, private.line.g, private.line.b, private.line.a)
    font:SetFont("Interface\\Addons\\" .. RaijinLab.addon_name .. "\\media\\fonts\\Ruluko.ttf", 10)
    B:SetNormalFontObject(font)
    B:SetText(text)
    B:SetPoint("TOPLEFT", private.canvas, "TOPLEFT", sx - (B:GetWidth() * 0.5), sy + (B:GetHeight() * 0.5))
    B:Show()
    tinsert(private.buttons_used, B)
    i = i + 1
end

function RaijinLab.drawing:Camera()
    local fX, fY, fZ = RaijinLab:ObjectPosition("player")
    local sX, sY, sZ = RaijinLab:GetCameraPosition()
    -- ObjectPosition returns nil when the runtime can't supply a position;
    -- bare arithmetic on nil would error, so bail out (drawing skips this frame).
    if not fX or not sX then return end
    return sX, sY, sZ, atan2(sY - fY, sX - fX), atan((sZ - fZ) / sqrt(((fX - sX) ^ 2) + ((fY - sY) ^ 2)))
end

local function clearCanvas()
    for i = #private.lines_used, 1, - 1 do
        private.lines_used[i]:Hide()
        tinsert(private.lines, tremove(private.lines_used))
    end
    for i = #private.buttons_used, 1, - 1 do
        private.buttons_used[i]:Hide()
        tinsert(private.buttons, tremove(private.buttons_used))
    end
    for i = #private.textures_used, 1, - 1 do
        private.textures_used[i]:Hide()
        tinsert(private.textures, tremove(private.textures_used))
    end
end

local function OnDrawUpdate()
    if not RaijinLab:HasRuntime() then return end
    if not private then return end
    -- No layers registered: zero work. InitDrawing used to spin 30 Hz clear
    -- loops forever with empty callbacks (idle FPS tax).
    if not next(private.callbacks) then return end
    -- IsPlayerInWorld RETURNS NIL ON THIS CLIENT (154 of 154 heartbeat samples),
    -- so `IsPlayerInWorld and IsPlayerInWorld()` was permanently false and the
    -- draw loop never ran a single callback. Layers could be enabled, the canvas
    -- created, the ticker firing - and nothing drawn, with no error anywhere.
    --
    -- Three-valued, like every other sensor here: a missing or nil-returning API
    -- means UNKNOWN, not "out of world". Only a definite false is a reason to
    -- skip the frame. The old form treated absence of evidence as evidence.
    local inworld = true
    if IsPlayerInWorld then
        local ok, v = pcall(IsPlayerInWorld)
        if ok and v == false then inworld = false end   -- only an explicit false
    end
    if not inworld then return end
    clearCanvas()
    for _, callback in pairs(private.callbacks) do
        local ok, err = pcall(callback)
        -- One bad callback must not take the whole canvas down with it.
        if not ok and RaijinLab.Telemetry then
            RaijinLab.Telemetry.every("draw:cb", 5, "draw", 2, "callback_error",
                { err = tostring(err):sub(1, 80) })
        end
    end
end

local function Enable(interval)
    return C_Timer.NewTicker(interval, OnDrawUpdate)
end

local function stopDrawing()
    if not onDrawTicker then return end
    onDrawTicker:Cancel()
end

function RaijinLab:AddDrawingCallback(key, callback)
    private.callbacks[key] = callback
end

function RaijinLab:RemoveDrawingCallback(key)
    private.callbacks[key] = nil
end

function RaijinLab:InitDrawing()
    -- Drawing needs the unlocker (WorldToScreen/TraceLine/camera are runtime-only).
    -- In load-only mode it would start a useless sub-frame ticker; don't.
    if not RaijinLab:HasRuntime() then return end
    if not private then
        private = {line = {r = 0, g = 1, b = 0, a = 1, w = 1},
            callbacks = {},
            canvas = CreateFrame("Frame", nil, WorldFrame),
            lines = {},
            lines_used = {},
            buttons = {},
            buttons_used = {},
            textures = {},
            level = "BACKGROUND",
        textures_used = {}}
        private.canvas:SetAllPoints(WorldFrame)
        -- 1/30, NOT 1/100: keep the ticker interval above per-frame time so it
        -- fires at most once per OnUpdate pass (see Compat.lua drain-loop note).
        onDrawTicker = Enable(1 / 30)
    end
end

-- Hide and drop every pooled texture before releasing `private`. The pool is
-- parented to a WorldFrame child, so leaving live textures attached while the
-- client frees its frame tree is exactly the kind of dangling reference that
-- turns a teardown into a null-pointer unlink.
function RaijinLab:DestroyDrawing()
    if private then
        for _, T in ipairs(private.lines_used or {}) do pcall(function() T:Hide() end) end
        for _, T in ipairs(private.lines or {}) do pcall(function() T:Hide() end) end
        private.lines, private.lines_used = {}, {}
        private.callbacks = {}
    end
    StopDrawing()
    clearCanvas()
    private = nil
end

function RaijinLab:GetDrawingObject()
    return private
end
