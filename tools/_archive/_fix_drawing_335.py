"""Make the renderer actually exist on this client.

THE USER HAS NEVER SEEN A SINGLE RENDERED LINE, and this is why: Draw2DLine was
built on CreateLine / SetThickness / SetColorTexture / SetStartPoint - ALL of
them Legion-era (7.0+) APIs. On 3.3.5 the first call throws, the callback pcall
swallows it, and the canvas stays empty forever while every upstream layer
(projection, ticker, toggles, defaults) is perfectly healthy. Months of "vision"
work rendered onto a pen that does not exist.

The 3.3.5 way to draw an arbitrary line is the rotated-texture technique every
wrath-era addon used (Routes, Cartographer): a plain white texture whose quad is
rotated via the 8-argument SetTexCoord transform. The quad math is extracted as
a PURE function so it can be unit-tested - the whole lesson of this session is
that untestable rendering code stays broken invisibly.
"""
from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Drawing.lua")
s = p.read_text(encoding="utf-8")

OLD = """function RaijinLab.drawing:Draw2DLine(sx, sy, ex, ey)
    if not sx or not sy or not ex or not ey then
        return
    end
    local L = tremove(private.lines)
    if not L then
        L = CreateFrame("Frame", private.canvas)
        L.line = L:CreateLine()
        L.line:SetDrawLayer("BACKGROUND")
    end
    L.line:SetThickness(private.line.w)
    L.line:SetColorTexture(private.line.r, private.line.g, private.line.b, private.line.a)
    tinsert(private.lines_used, L)
    L:ClearAllPoints()
    if (sx > ex and sy > ey) or (sx < ex and sy < ey) then
        L:SetPoint("TOPRIGHT", private.canvas, "TOPLEFT", sx, sy)
        L:SetPoint("BOTTOMLEFT", private.canvas, "TOPLEFT", ex, ey)
        L.line:SetStartPoint('TOPRIGHT')
        L.line:SetEndPoint('BOTTOMLEFT')
    elseif sx < ex and sy > ey then
        L:SetPoint("TOPLEFT", private.canvas, "TOPLEFT", sx, sy)
        L:SetPoint("BOTTOMRIGHT", private.canvas, "TOPLEFT", ex, ey)
        L.line:SetStartPoint('TOPLEFT')
        L.line:SetEndPoint('BOTTOMRIGHT')
    elseif sx > ex and sy < ey then
        L:SetPoint("TOPRIGHT", private.canvas, "TOPLEFT", sx, sy)
        L:SetPoint("BOTTOMLEFT", private.canvas, "TOPLEFT", ex, ey)
        L.line:SetStartPoint('TOPLEFT')
        L.line:SetEndPoint('BOTTOMRIGHT')
    else
        L:SetPoint("TOPLEFT", private.canvas, "TOPLEFT", sx, sy)
        L:SetPoint("BOTTOMLEFT", private.canvas, "TOPLEFT", sx, ey)
        L.line:SetStartPoint('TOPLEFT')
        L.line:SetEndPoint('BOTTOMLEFT')
    end
    L:Show()
end"""

NEW = """-- PURE quad math for a thick 2D line, extracted so it is testable headless.
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
        T:SetTexture("Interface\\\\Buttons\\\\WHITE8X8")
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
end"""

assert OLD in s, "Draw2DLine not found as expected"
s = s.replace(OLD, NEW, 1)
p.write_text(s, encoding="utf-8")
print("Drawing.lua: 3.3.5-native line renderer (rotated-texture), quad math pure")
