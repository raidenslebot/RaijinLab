-- ============================================================
-- RaijinLab - minimap button
-- ============================================================
-- A small draggable circular icon anchored around the Minimap's edge.
-- Left-click toggles the main menu. Drag repositions the icon; its polar
-- angle persists in RaijinLabDB.minimap.angle so it stays where you put it.
--
-- We deliberately avoid LibDBIcon: this addon has no external lib folder,
-- and 3.3.5's Minimap frame is stable enough that ~40 lines of geometry
-- cover the same ground without a dependency.
-- ============================================================

local RL = RaijinLab
if not RL then return end

local MinimapIcon = {}
RL.MinimapIcon = MinimapIcon

local BUTTON_NAME = "RaijinLabMinimapButton"
local DEFAULT_ANGLE = 210   -- degrees; lower-left of minimap (out of the way)
local MINIMAP_RADIUS = 80   -- Blizzard 3.3.5 default Minimap is 140x140; edge = ~70

-- Read/write angle through the SavedVariables. RaijinLabDB is guaranteed to
-- exist by the time we're wired up (PLAYER_ENTERING_WORLD runs after
-- VARIABLES_LOADED), but we double-guard so a stale hook can't crash the UI.
local function get_saved()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.minimap = RaijinLabDB.minimap or {}
    if type(RaijinLabDB.minimap.angle) ~= "number" then
        RaijinLabDB.minimap.angle = DEFAULT_ANGLE
    end
    if type(RaijinLabDB.minimap.hidden) ~= "boolean" then
        RaijinLabDB.minimap.hidden = false
    end
    return RaijinLabDB.minimap
end

-- Convert polar angle (degrees, 0 = east, 90 = north) around Minimap center
-- into an SetPoint("CENTER", Minimap, "CENTER", x, y) offset. The icon rides
-- the minimap edge at radius MINIMAP_RADIUS.
local function place_button(btn, angle)
    if not btn or not Minimap then return end
    local rad = math.rad(angle or DEFAULT_ANGLE)
    local x = math.cos(rad) * MINIMAP_RADIUS
    local y = math.sin(rad) * MINIMAP_RADIUS
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Compute the angle (deg) implied by the current cursor position relative
-- to the minimap center. Used during drag so the icon tracks the pointer.
local function angle_from_cursor()
    if not Minimap then return DEFAULT_ANGLE end
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    if not mx or not scale or scale == 0 then return DEFAULT_ANGLE end
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local a = math.deg((math.atan2 or math.atan)(cy - my, cx - mx))
    if a < 0 then a = a + 360 end
    return a
end

function MinimapIcon:Create()
    if self.button then return self.button end
    if not Minimap then return nil end

    local btn = CreateFrame("Button", BUTTON_NAME, Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(Minimap:GetFrameLevel() + 10)
    btn:SetSize(31, 31)
    btn:SetMovable(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Circular icon: a solid-color ring backdrop with the RaijinLab "R" glyph
    -- on top. Blizzard's built-in ring texture would need extra artwork; a
    -- clean solid disc + text is unambiguous and matches the addon's palette.
    local ring = btn:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints(btn)
    ring:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    ring:SetVertexColor(0.1, 0.15, 0.22, 0.85)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1)

    local label = btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("CENTER", btn, "CENTER", 0, 1)
    label:SetText("R")
    label:SetTextColor(0.494, 0.784, 0.890)   -- Raijin blue #7ec8e3

    btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            if RL.Menu and RL.Menu.Toggle then
                RL.Menu:Toggle()
            end
        elseif button == "RightButton" then
            -- Right-click also toggles for now. Reserved for a context menu
            -- (start/stop rotation, config switch) in a later pass.
            if RL.Menu and RL.Menu.Toggle then
                RL.Menu:Toggle()
            end
        end
    end)

    btn:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:SetScript("OnUpdate", function(s)
            local a = angle_from_cursor()
            place_button(s, a)
            get_saved().angle = a
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)
        -- Save one last time in case OnUpdate missed the final frame.
        get_saved().angle = angle_from_cursor()
    end)

    btn:SetScript("OnEnter", function(self)
        if GameTooltip and not self.isDragging then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("|cff7ec8e3RaijinLab|r")
            GameTooltip:AddLine("Click to open menu.", 1, 1, 1)
            GameTooltip:AddLine("Drag to move around the minimap.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    place_button(btn, get_saved().angle)
    self.button = btn
    return btn
end

function MinimapIcon:Show()
    local db = get_saved()
    db.hidden = false
    if not self.button then self:Create() end
    if self.button then self.button:Show() end
end

function MinimapIcon:Hide()
    local db = get_saved()
    db.hidden = true
    if self.button then self.button:Hide() end
end

function MinimapIcon:Toggle()
    if get_saved().hidden then self:Show() else self:Hide() end
end

-- Initialize once the DB is loaded. Called from Events.lua on
-- VARIABLES_LOADED (via the RaijinLab:Init chain) - we hook off the same
-- signal so the addon's own init ordering stays authoritative.
function MinimapIcon:Init()
    if self._initialized then return end
    self._initialized = true
    self:Create()
    if get_saved().hidden and self.button then
        self.button:Hide()
    end
end
