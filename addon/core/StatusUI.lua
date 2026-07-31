-- Minimal in-game status strip for RaijinLab
local RL = RaijinLab

function RL:ShowStatusFrame()
    if self.status_frame then
        self.status_frame:Show()
        return
    end
    local f = CreateFrame("Frame", "RaijinLabStatusFrame", UIParent)
    f:SetWidth(280)
    f:SetHeight(54)
    f:SetPoint("TOP", UIParent, "TOP", 0, -12)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = {left = 3, right = 3, top = 3, bottom = 3}
        })
    end
    if f.SetBackdropColor then
        f:SetBackdropColor(0, 0, 0, 0.75)
    end
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -6)
    local ver = (RaijinLab and RaijinLab.ADDON_VERSION) or "1.6.1"
    title:SetText("|cff7ec8e3RaijinLab|r |cffaaaaaa" .. ver .. "|r")

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", 8, -22)
    body:SetPoint("BOTTOMRIGHT", -8, 6)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    f.body = body

    f:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t < 0.5 then return end
        self.t = 0
        local rt = RaijinLab:HasRuntime() and ("|cff55ff55" .. tostring(RaijinLab:RuntimeVersion() or "yes") .. "|r") or "|cffff5555offline|r"
        local build = select(1, RaijinLab:ClientBuild())
        self.body:SetText(string.format("runtime: %s\nclient: %s  ascension: %s", rt, tostring(build),
            tostring(RaijinLab:IsAscensionClient())))
    end)

    self.status_frame = f
end

function RL:HideStatusFrame()
    if self.status_frame then
        self.status_frame:Hide()
    end
end
