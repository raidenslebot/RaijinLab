from pathlib import Path

# ---- 1. Vision: every layer defaults ON ------------------------------------
v = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Vision.lua")
s = v.read_text(encoding="utf-8")
OLD = """local function cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.vision = RaijinLabDB.vision or {}
    return RaijinLabDB.vision
end"""
NEW = """local function cfg()
    RaijinLabDB = RaijinLabDB or {}
    local c = RaijinLabDB.vision
    if not c then
        c = {}
        RaijinLabDB.vision = c
    end
    -- EVERY LAYER DEFAULTS ON. Rendering is how you see what the bot believes;
    -- shipping it dark meant the one tool for diagnosing "it looks confused" was
    -- itself off by default, and nothing said so.
    --
    -- Only a nil is defaulted. An explicit false is a decision the user made in
    -- the Debug tab and must survive reload - re-defaulting it would make the
    -- off switch look broken, which is its own bug.
    for i = 1, #V.LAYERS do
        local l = V.LAYERS[i]
        if c[l] == nil then c[l] = true end
    end
    return c
end"""
assert OLD in s, "vision cfg not found"
s = s.replace(OLD, NEW, 1)
v.write_text(s, encoding="utf-8")
print("Vision: all layers default ON")

# ---- 2. Menu: rendering toggles on the Debug tab ---------------------------
m = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Menu.lua")
t = m.read_text(encoding="utf-8")

ANCH = """function Menu:BuildDebug(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.debug = p"""
NEW2 = ANCH + """

    -- WORLD RENDERING. One toggle per Vision layer, all on by default.
    -- on_change calls V.refresh() rather than only writing the flag: refresh is
    -- what creates the canvas and starts the 30Hz ticker (InitDrawing), so a
    -- flag written without it enables a layer that never draws - which is
    -- exactly how "/raijin show all" appeared to do nothing.
    local rend = UI.inset(p)
    rend:SetPoint("TOPLEFT", 0, 0)
    rend:SetPoint("TOPRIGHT", 0, 0)
    rend:SetHeight(196)
    UI.section(rend, "World rendering"):SetPoint("TOPLEFT", 12, -10)
    local LAYER_LABEL = {
        grid       = "Navigation grid (walkable / steep / blocked / water)",
        path       = "Planned path and waypoints",
        search     = "Search belief field (where it thinks the target is)",
        target     = "Current target and objective markers",
        controller = "Steering controller (heading, turn command, ground probe)",
    }
    local rspec = {}
    local VL = (RaijinLab.Vision and RaijinLab.Vision.LAYERS) or {}
    for i = 1, #VL do
        local l = VL[i]
        rspec[#rspec + 1] = {
            key = l, default = true,
            label = LAYER_LABEL[l] or l,
            on_change = function()
                local V = RaijinLab.Vision
                if V and V.refresh then pcall(V.refresh) end
            end,
        }
    end
    self:Options(rend, "vision", rspec, -34, "_visionOpts")"""
assert ANCH in t, "BuildDebug head not found"
t = t.replace(ANCH, NEW2, 1)

# the existing debug-log card must move below the new one
OLD3 = """    local head = UI.inset(p)
    head:SetPoint("TOPLEFT", 0, 0)
    head:SetPoint("TOPRIGHT", 0, 0)
    head:SetHeight(58)
    UI.section(head, "Debug log"):SetPoint("TOPLEFT", 12, -10)"""
NEW3 = """    local head = UI.inset(p)
    head:SetPoint("TOPLEFT", rend, "BOTTOMLEFT", 0, -8)
    head:SetPoint("TOPRIGHT", rend, "BOTTOMRIGHT", 0, -8)
    head:SetHeight(58)
    UI.section(head, "Debug log"):SetPoint("TOPLEFT", 12, -10)"""
assert OLD3 in t, "debug log card not found"
t = t.replace(OLD3, NEW3, 1)

# and the refresh must push saved values back into the new widgets
OLD4 = "function Menu:RefreshDebug()"
NEW4 = """function Menu:RefreshDebug()
    -- Without this the checkboxes show whatever they were built with and
    -- silently disagree with the config they edit.
    self:RefreshOptions("vision", "_visionOpts")"""
assert OLD4 in t
t = t.replace(OLD4, NEW4, 1)
m.write_text(t, encoding="utf-8")
print("Menu: rendering toggles on the Debug tab")
