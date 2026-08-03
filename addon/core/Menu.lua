-- RaijinLab control panel - default WoW 3.3.5 aesthetic.
--
-- Uses stock templates: UI-DialogBox backdrop, UIPanelCloseButton,
-- CharacterFrameTabButtonTemplate (bottom tabs), UIPanelButtonTemplate,
-- UICheckButtonTemplate, OptionsSliderTemplate, UIPanelScrollFrameTemplate.
--
-- Each tab is a fully-developed page - no more one-line blurb + Toggle.

local Menu = {}

local function UIx()
    return RaijinLab and RaijinLab.UI
end

-- ============================================================
-- DB
-- ============================================================

function Menu:EnsureDB()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.modules = RaijinLabDB.modules or {
        rotation = false, nav = true, gather = false,
        combat = false, quest = false, grind = false,
    }
    RaijinLabDB.grind = RaijinLabDB.grind or { radius = 40, route = {}, enabled = false }
    RaijinLabDB.gather = RaijinLabDB.gather or {
        professions = {
            herbalism = true, mining = true, fishing = true, woodcutting = true,
        },
        radius = 60, enabled = false,
    }
    RaijinLabDB.combat = RaijinLabDB.combat or {
        engage = true, disengage_hp = 25, pvp_mode = "auto",
        engage_range = 30, enabled = false,
    }
    RaijinLabDB.quest = RaijinLabDB.quest or {
        enabled = false, auto_accept = true, auto_turnin = true,
    }
    RaijinLabDB.nav = RaijinLabDB.nav or { enabled = true }
end

-- ============================================================
-- Module lifecycle (start/stop from Home + each tab's toggle)
-- ============================================================

function Menu:ApplyModuleState(key)
    self:EnsureDB()
    local on = RaijinLabDB.modules[key]
    -- While the suite is off, a module flag is a SELECTION, not a run order.
    -- Starting it here would defeat the master switch and make the module tick
    -- again behind the user's back.
    if on and RaijinLab.Master and RaijinLab.Master.suppressed() then return end
    if key == "rotation" and RaijinLab.RotationExecutor then
        if on then RaijinLab.RotationExecutor.start() else RaijinLab.RotationExecutor.stop() end
    elseif key == "gather" and RaijinLab.Gatherer then
        if on and RaijinLab.Gatherer.start then RaijinLab.Gatherer.start()
        elseif RaijinLab.Gatherer.stop then RaijinLab.Gatherer.stop() end
    elseif key == "combat" and RaijinLab.CombatBrain then
        if on and RaijinLab.CombatBrain.start then RaijinLab.CombatBrain.start()
        elseif RaijinLab.CombatBrain.stop then RaijinLab.CombatBrain.stop() end
    elseif key == "quest" and RaijinLab.QuestSuite then
        if on and RaijinLab.QuestSuite.start then RaijinLab.QuestSuite.start()
        elseif RaijinLab.QuestSuite.stop then RaijinLab.QuestSuite.stop() end
    elseif key == "grind" and RaijinLab.Grinder then
        if on and RaijinLab.Grinder.start then RaijinLab.Grinder.start()
        elseif RaijinLab.Grinder.stop then RaijinLab.Grinder.stop() end
    end
end

-- ============================================================
-- Small stock helpers used by tabs
-- ============================================================

local uniq = 0
local function nextName(prefix)
    uniq = uniq + 1
    return (prefix or "RaijinLabW") .. tostring(uniq)
end

local function stockButton(parent, text, w, h, onClick)
    -- Every button gets a unique name so UIPanelButtonTemplate's internal
    -- region names ($parentLeft/$parentMiddle/$parentRight on templates that
    -- have them) don't collide across our anonymous buttons.
    local b = CreateFrame("Button", nextName("RLBtn"), parent, "UIPanelButtonTemplate")
    b:SetWidth(w or 120); b:SetHeight(h or 22)
    b:SetText(text or "")
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function fs(parent, text, font, r, g, b)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    t:SetText(text or "")
    if r then t:SetTextColor(r, g, b) end
    return t
end

-- ============================================================
-- Frame + tabs
-- ============================================================

local TABS = {
    { id = "home",     label = "Home"       },
    { id = "rotation", label = "Rotation"   },
    { id = "combat",   label = "Combat"     },
    { id = "nav",      label = "Navigation" },
    { id = "gather",   label = "Gathering"  },
    { id = "quest",    label = "Questing"   },
    { id = "grind",    label = "Grinding"   },
    { id = "debug",    label = "Debug"      },
}

function Menu:Show()
    if type(RaijinLab_SetUiOpenHint) == "function" then
        pcall(RaijinLab_SetUiOpenHint, true)
    elseif RaijinLab then
        RaijinLab._ui_open_hint = true
    end
    local UI = UIx()
    self:EnsureDB()
    if self.frame and self._built then
        self.frame:Show()
        self:SelectTab(self.activeTab or "home")
        return
    end

    local f = _G["RaijinLabMainMenu"] or CreateFrame("Frame", "RaijinLabMainMenu", UIParent)
    -- CRITICAL: store the ref so the Show/Hide guards and the _built shortcut
    -- actually work. Missing this assignment made every open rebuild the tab
    -- strip + 7 pages, stacking named tab buttons over prior instances; leftover
    -- Disable() state on stale tabs was the "grey stuck" glitch.
    self.frame = f
    -- Restore user's saved size (falls back to a roomy default). Persisted at Hide.
    local savedW = (RaijinLabDB and RaijinLabDB.menu_width)  or 860
    local savedH = (RaijinLabDB and RaijinLabDB.menu_height) or 600
    f:SetWidth(savedW); f:SetHeight(savedH)
    f:ClearAllPoints(); f:SetPoint("CENTER")
    -- User-resizable via the bottom-right corner grip. Min large enough for the
    -- 7 tabs (7x92 + 6x4 + 36 margin = 700) and the header. Max = screen size.
    f:SetResizable(true)
    if f.SetMinResize then f:SetMinResize(760, 520) end
    if f.SetMaxResize then f:SetMaxResize(1600, 1200) end
    -- The suite window must sit ABOVE ordinary UI. It used to be HIGH, which is a
    -- LOWER strata than DIALOG, so it rendered underneath Blizzard panels and even
    -- underneath the editor it opens. Registering it puts it in the shared window
    -- strata and brings it to the front whenever it is shown or clicked.
    f:EnableMouse(true)
    local UIreg = UIx()
    if UIreg and UIreg.RegisterWindow then
        UIreg.RegisterWindow(f)
    else
        f:SetFrameStrata("DIALOG"); f:SetFrameLevel(100); f:SetToplevel(true)
    end

    -- ESC dismisses the menu (WoW standard for closable panels). Append rather
    -- than overwrite so we don't clobber game/other-addon entries.
    if not tContains(UISpecialFrames or {}, "RaijinLabMainMenu") then
        table.insert(UISpecialFrames, "RaijinLabMainMenu")
    end

    -- Default WoW parchment + gold border + header banner
    UI.dialogFrame(f, "RaijinLab  Control Center")

    -- Draggable via header banner region (top ~40 px)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Close X
    UI.closeButton(f)

    -- Bottom-right corner resize grip. Uses Blizzard's ChatFrame-style up/down
    -- arrow textures - universally present in 3.3.5 clients. On drag the frame
    -- resizes live; on release we persist the new size to SavedVariables.
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(16); grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        if RaijinLabDB then
            RaijinLabDB.menu_width  = math.floor(f:GetWidth() + 0.5)
            RaijinLabDB.menu_height = math.floor(f:GetHeight() + 0.5)
        end
    end)

    -- (Version footer removed - was overlapping the right-side tabs. Runtime
    -- status is shown prominently on the Home tab under the Session card.)
    self._verFs = nil

    -- Content region: below header, above tab strip (44 px reserved at bottom
    -- for the tab row + a version footer).
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", 16, -48)
    content:SetPoint("BOTTOMRIGHT", -16, 44)
    self.content = content

    -- Tab strip anchored INSIDE the frame's bottom margin. 7 tabs x 92 px
    -- + 6 x 4 px gaps = 668 px, fits inside 720 px frame width with margin.
    self.tabButtons = {}
    self.pages = {}
    for i, t in ipairs(TABS) do
        local tab = UI.panelTab(f, i, t.label, function(idx)
            self:SelectTab(TABS[idx].id)
        end)
        if i == 1 then
            tab:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 14)
        else
            tab:SetPoint("LEFT", self.tabButtons[TABS[i-1].id], "RIGHT", 4, 0)
        end
        self.tabButtons[t.id] = tab
    end

    -- Build all pages (hidden until selected)
    self:BuildHome(content)
    self:BuildRotation(content)
    self:BuildCombat(content)
    self:BuildNav(content)
    self:BuildGather(content)
    self:BuildQuest(content)
    self:BuildGrind(content)
    self:BuildDebug(content)

    self._built = true
    self:SelectTab("home")
    f:Show()
    self:RefreshHome()

    RaijinLab:Chatter("|cffffd200RaijinLab|r menu opened.")
end

function Menu:Hide()
    if type(RaijinLab_SetUiOpenHint) == "function" then
        pcall(RaijinLab_SetUiOpenHint, false)
    elseif RaijinLab then
        RaijinLab._ui_open_hint = false
    end
    if self.frame then self.frame:Hide() end
    -- Just Hide() the Editor modals - do NOT SetParent(nil). Orphaning a frame
    -- that still has anchor relationships (its own children, or an ancestor
    -- caching an anchor point) can leave a stale pointer that WoW dereferences
    -- during the next anchor-recompute pass - the exact failure mode of the
    -- 0x007A0FD2 crash (write to [null+8] via FrameScript render path). The
    -- Lua-heap savings from orphaning aren't worth the memory-safety risk.
    if RaijinLab.RotationEditor then
        local ed = RaijinLab.RotationEditor
        if ed.addFrame and ed.addFrame.Hide then ed.addFrame:Hide() end
        if ed.editFrame and ed.editFrame.Hide then ed.editFrame:Hide() end
    end
    -- (REMOVED) collectgarbage("collect") here. Same risk as the periodic
    -- GC ticker: firing a full sweep at an arbitrary render moment can trip
    -- a userdata __gc that invalidates a native pointer still held by AC /
    -- runtime callbacks (traced to random ACCESS_VIOLATIONs). Lua's
    -- incremental collector will catch up on its own.
end
function Menu:Toggle()
    if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end
end

function Menu:SelectTab(id)
    self.activeTab = id
    -- Editor modals are parented to UIParent, not to the rotation page, so
    -- they DON'T auto-hide on page switch. Close them explicitly when the
    -- user navigates away from the Rotation tab.
    if id ~= "rotation" and RaijinLab.RotationEditor then
        local ed = RaijinLab.RotationEditor
        if ed.addFrame and ed.addFrame.Hide then ed.addFrame:Hide() end
        if ed.editFrame and ed.editFrame.Hide then ed.editFrame:Hide() end
    end
    -- Ordered iteration over TABS (not pairs - pairs order is undefined and
    -- can miss/misassign pages when the table has holes or is rehashed).
    -- Force-hide EVERY known page first, THEN show only the target, so we
    -- can't leave stale pages visible on top of the new one.
    for _, spec in ipairs(TABS) do
        local p = self.pages[spec.id]
        if p then p:Hide() end
    end
    local target = self.pages[id]
    if target then
        -- Belt-and-suspenders: re-pin to content and raise above any lingering
        -- widget that may have SetShown itself out-of-band (Editor modals etc).
        target:ClearAllPoints()
        target:SetAllPoints(self.content)
        if target.SetFrameLevel and self.content and self.content.GetFrameLevel then
            target:SetFrameLevel(self.content:GetFrameLevel() + 5)
        end
        target:Show()
    end
    -- Active-tab visual: LockHighlight on the current, unlock the rest.
    for tid, b in pairs(self.tabButtons or {}) do
        if b.SetActive then b:SetActive(tid == id) end
    end
    if RaijinLabDB and RaijinLabDB.menu_debug then
        local shown = {}
        for _, spec in ipairs(TABS) do
            local p = self.pages[spec.id]
            if p and p:IsShown() then shown[#shown+1] = spec.id end
        end
        print("|cffffd200RaijinLab menu|r SelectTab(" .. tostring(id)
            .. ")  visible=[" .. table.concat(shown, ", ") .. "]")
    end
    if id == "home" then self:RefreshHome() end
    if id == "rotation" and RaijinLab.RotationEditor then
        RaijinLab.RotationEditor:Refresh()
    end
    if id == "grind" then self:RefreshGrind() end
    if id == "debug" then self:RefreshDebug() end
    if id == "combat" then self:RefreshCombat() end
    if id == "gather" then self:RefreshGather() end
    if id == "quest" then self:RefreshQuest() end
    if id == "gather" then self:RefreshGather() end
end

-- ============================================================
-- HOME TAB
-- ============================================================

function Menu:BuildHome(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.home = p

    self._home = { rows = {} }

    -- MASTER SWITCH - the one control that owns the whole suite. Sits at the very
    -- top because the moment you want it is the moment something is going wrong,
    -- and hunting for it among five module toggles is exactly the wrong
    -- experience. One click stops every module AND releases the movement keys.
    local master = UI.inset(p)
    master:SetPoint("TOPLEFT", 0, 0)
    master:SetPoint("TOPRIGHT", 0, 0)
    master:SetHeight(58)
    local mLabel = fs(master, "Suite", "GameFontNormalLarge")
    mLabel:SetPoint("TOPLEFT", 14, -12)
    local mState = fs(master, "", "GameFontHighlight")
    mState:SetPoint("TOPLEFT", mLabel, "BOTTOMLEFT", 0, -4)
    mState:SetJustifyH("LEFT")
    local mBtn = stockButton(master, "Turn OFF", 110, 30, function()
        self:EnsureDB()
        if RaijinLab.Master then RaijinLab.Master.toggle("menu") end
        self:RefreshHome()
    end)
    -- Mouse only: Space/Enter must not toggle the suite while Jump/steer runs.
    -- Live log: master OFF reason=menu ~150ms after WALL(chest) while walking.
    if mBtn.RegisterForClicks then mBtn:RegisterForClicks("LeftButtonUp") end
    if mBtn.EnableKeyboard then mBtn:EnableKeyboard(false) end
    mBtn:SetPoint("RIGHT", master, "RIGHT", -14, 0)
    self._home.master = { state = mState, btn = mBtn, label = mLabel }

    -- Session summary section
    local session = UI.inset(p)
    session:SetPoint("TOPLEFT", 0, -66)
    session:SetPoint("TOPRIGHT", 0, -66)
    session:SetHeight(120)
    UI.section(session, "Session"):SetPoint("TOPLEFT", 12, -10)
    local function row(label, y)
        local L = fs(session, label, "GameFontNormalSmall", UI.C.dim[1], UI.C.dim[2], UI.C.dim[3])
        L:SetPoint("TOPLEFT", 14, y)
        L:SetWidth(120); L:SetJustifyH("LEFT")
        local V = fs(session, "-", "GameFontHighlightSmall")
        V:SetPoint("TOPLEFT", L, "TOPRIGHT", 8, 0)
        V:SetPoint("RIGHT", session, "RIGHT", -14, 0)
        V:SetJustifyH("LEFT")
        return V
    end
    self._home.rows.runtime = row("Runtime",       -38)
    self._home.rows.build   = row("Client build",  -56)
    self._home.rows.player  = row("Player",        -74)
    self._home.rows.target  = row("Target",        -92)

    -- Modules quick-toggle grid
    local mods = UI.inset(p)
    mods:SetPoint("TOPLEFT", 0, -198)
    mods:SetPoint("BOTTOMRIGHT", 0, 0)
    UI.section(mods, "Modules"):SetPoint("TOPLEFT", 12, -10)

    local keys = {
        { "rotation", "Rotation engine",
          "Priority list - conditions - school-aware protection" },
        { "combat",   "Combat brain",
          "Engage - disengage - reposition - PvE/PvP posture" },
        { "gather",   "Gathering",
          "Herbalism - mining - fishing - woodcutting - gather nodes" },
        { "quest",    "Questing",
          "Accept - turn-in - kill - collect - use-object loop" },
        { "grind",    "Grinding",
          "Route waypoints + radius auto-fight" },
        -- NOT toggleable, and it never was: nothing outside this menu reads
        -- RaijinLabDB.modules.nav. The row offered a Disable button that did
        -- nothing while its own blurb said "always on" - a control that lies
        -- about being a control. It is a shared service, so it is shown as
        -- status only. This is also the honest answer to "why doesn't
        -- navigation turn on with questing": it is already on.
        { "nav",      "Navigation",
          "Shared pathing service (obstacle-aware). Always available - not a toggle.",
          true },
    }
    self._home.mods = {}
    for i, spec in ipairs(keys) do
        local key, label, blurb, always = spec[1], spec[2], spec[3], spec[4]
        local rowY = -34 - (i - 1) * 46
        local L = fs(mods, label, "GameFontNormal")
        L:SetPoint("TOPLEFT", 14, rowY)
        local S = fs(mods, blurb, "GameFontDisableSmall")
        S:SetPoint("TOPLEFT", L, "BOTTOMLEFT", 0, -2)
        S:SetPoint("RIGHT", mods, "RIGHT", -160, 0)
        S:SetJustifyH("LEFT")
        local state = fs(mods, "OFF", "GameFontHighlightSmall")
        -- TOPRIGHT anchor: Y offset now measures from mods.top (matches rowY,
        -- which is the label's TOPLEFT Y offset from mods.top). Previously
        -- "RIGHT" anchored from mods CENTER-Y, so later rows drifted below
        -- the mods card entirely and rendered outside the frame.
        state:SetPoint("TOPRIGHT", mods, "TOPRIGHT", -102, rowY - 2)
        state:SetJustifyH("RIGHT")
        if always then
            -- status only: no button, because there is nothing to switch
            state:SetText("|cff10ff10ALWAYS|r")
            self._home.mods[key] = { state = state, always = true }
        else
        local toggle = stockButton(mods, "Toggle", 78, 22, function()
            self:EnsureDB()
            -- Selection only. Enabling a module while the suite is off ARMS it;
            -- it does not start the suite. The master button is the only
            -- run/stop control.
            local turning_on = not RaijinLabDB.modules[key]
            RaijinLabDB.modules[key] = turning_on
            -- Bring up what it DEPENDS on. Enabling questing and then watching it
            -- stand there because the rotation was off is not a choice the user
            -- made, it is a trap. Said out loud, because a switch that silently
            -- flips other switches is its own kind of surprise.
            if turning_on and RaijinLab.Master and RaijinLab.Master.missing_deps then
                local need = RaijinLab.Master.missing_deps(key)
                for _, dep in ipairs(need) do
                    RaijinLabDB.modules[dep] = true
                    self:ApplyModuleState(dep)
                end
                if #need > 0 and print then
                    print("|cff7ec8e3RaijinLab|r " .. key .. " also needs " ..
                          table.concat(need, ", ") .. " - enabled")
                end
            end
            self:ApplyModuleState(key)
            self:RefreshHome()
        end)
        toggle:SetPoint("TOPRIGHT", mods, "TOPRIGHT", -14, rowY - 4)
        self._home.mods[key] = { state = state, toggle = toggle }
        end
    end

    -- Rotation keybind hint (Esc → Key Bindings → RaijinLab).
    local kb = fs(mods, "Rotation keybind: Esc → Key Bindings → RaijinLab → Toggle rotation module  |  /rjrot",
        "GameFontDisableSmall")
    kb:SetPoint("BOTTOMLEFT", mods, "BOTTOMLEFT", 14, 10)
    kb:SetPoint("BOTTOMRIGHT", mods, "BOTTOMRIGHT", -14, 10)
    kb:SetJustifyH("LEFT")
    self._home.rot_keybind_hint = kb
end

function Menu:RefreshHome()
    if not self._home then return end
    self:EnsureDB()
    local UI = UIx()

    -- Session card
    if RaijinLab.HasRuntime and RaijinLab:HasRuntime() then
        local ver = RaijinLab.RuntimeVersion and RaijinLab:RuntimeVersion() or "yes"
        self._home.rows.runtime:SetText("|cff10ff10ONLINE|r  " .. tostring(ver))
    else
        self._home.rows.runtime:SetText("|cffff5555offline|r  - inject in-world (tools\\inject.bat), /reload")
    end
    if GetBuildInfo then
        local v, b, _, toc = GetBuildInfo()
        self._home.rows.build:SetText(string.format("%s (build %s)  -  TOC %s",
            tostring(v), tostring(b or "?"), tostring(toc or "?")))
    end
    if UnitName then
        local name = UnitName("player") or "?"
        local lvl = UnitLevel and UnitLevel("player") or "?"
        local cls = UnitClass and UnitClass("player") or ""
        self._home.rows.player:SetText(string.format("%s  -  level %s  %s",
            tostring(name), tostring(lvl), tostring(cls)))
    end
    if UnitExists and UnitExists("target") then
        local tn = UnitName("target") or "?"
        local th = UnitHealth and UnitHealth("target") or 0
        local tm = UnitHealthMax and UnitHealthMax("target") or 1
        local pct = math.floor(100 * th / math.max(1, tm) + 0.5)
        local hostile = UnitCanAttack and UnitCanAttack("player", "target") and "|cffff8080hostile|r" or "|cff80ff80friendly|r"
        self._home.rows.target:SetText(string.format("%s  -  %d%%  %s", tn, pct, hostile))
    else
        self._home.rows.target:SetText("|cff666666no target|r")
    end

    -- Master switch
    local master_on = true
    if self._home.master then
        local M = RaijinLab.Master
        local on, n = true, 0
        if M then on, n = M.summary() end
        master_on = on
        if on then
            self._home.master.state:SetText(
                n > 0 and string.format("|cff10ff10RUNNING|r  -  %d module(s) active", n)
                      or  "|cff10ff10ON|r  -  idle, no modules enabled")
            self._home.master.btn:SetText("Turn OFF")
        else
            self._home.master.state:SetText(
                n > 0 and string.format("|cffff5555STOPPED|r  -  ON will run %d selected module(s)", n)
                      or  "|cffff5555STOPPED|r  -  nothing selected")
            self._home.master.btn:SetText("Turn ON")
        end
    end

    -- Modules grid. While the master is off these are shown as suppressed rather
    -- than merely OFF - the distinction matters, because the module list is not
    -- what is stopping them.
    local m = RaijinLabDB.modules
    for key, w in pairs(self._home.mods) do
        local on = m[key]
        if w.always then
            w.state:SetText(master_on and "|cff10ff10ALWAYS|r" or "|cff777777suite off|r")
        elseif not master_on then
            -- Selected modules still read as selected; they are simply halted
            -- because the suite is off, which is a different thing from OFF.
            w.state:SetText(on and "|cffcccc55selected|r" or "|cff777777off|r")
            w.toggle:SetText(on and "Deselect" or "Select")
        elseif on then
            w.state:SetText("|cff10ff10ON|r")
            w.toggle:SetText("Disable")
        else
            w.state:SetText("|cffff5555OFF|r")
            w.toggle:SetText("Enable")
        end
    end

end

-- ============================================================
-- ROTATION TAB (host the existing Editor)
-- ============================================================

function Menu:BuildRotation(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.rotation = p

    if RaijinLab.RotationEditor and RaijinLab.RotationEditor.Attach then
        RaijinLab.RotationEditor:Attach(p)
    else
        local t = fs(p, "Rotation editor unavailable (RotationEditor:Attach not exported)", "GameFontHighlight")
        t:SetPoint("CENTER")
    end
end

-- ============================================================
-- COMBAT TAB
-- ============================================================

function Menu:BuildCombat(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.combat = p

    local card = UI.inset(p)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", 0, 0)
    card:SetHeight(340)
    UI.section(card, "Combat Brain"):SetPoint("TOPLEFT", 12, -10)

    local blurb = fs(card, "Spatial awareness - engage-worthy target selection - disengage on low HP - auto-switch PvE/PvP posture. Requires the rotation module to actually cast.",
        "GameFontDisableSmall")
    blurb:SetPoint("TOPLEFT", 14, -38); blurb:SetPoint("RIGHT", -14, 0)
    blurb:SetJustifyH("LEFT")

    -- Enable checkbox
    local enable = self:ModuleEnable(card, "combat",
        "Enable Combat Brain (also enables the rotation)", 14, -38)
    enable:SetPoint("TOPLEFT", 14, -74)
    self._combat = { enable = enable }

    local eng = UI.checkbox(card, nextName("RLCombatEngage"), "Engage nearby hostiles automatically",
        RaijinLabDB.combat.engage, function(v) RaijinLabDB.combat.engage = v end)
    eng:SetPoint("TOPLEFT", 14, -102)
    self._combat.engage = eng

    -- Disengage HP slider
    local dis = UI.slider(card, nextName("RLDisHP"), "Disengage below HP %",
        0, 100, 5, RaijinLabDB.combat.disengage_hp or 25,
        function(v) RaijinLabDB.combat.disengage_hp = math.floor(v + 0.5) end,
        function(v) return math.floor(v + 0.5) .. " %" end)
    dis:SetPoint("TOPLEFT", 20, -160)
    self._combat.dis = dis

    -- Engage range slider
    local rng = UI.slider(card, nextName("RLEngRng"), "Engage range (yards)",
        5, 60, 5, RaijinLabDB.combat.engage_range or 30,
        function(v) RaijinLabDB.combat.engage_range = math.floor(v + 0.5) end,
        function(v) return math.floor(v + 0.5) .. " yd" end)
    rng:SetPoint("TOPLEFT", 20, -210)
    self._combat.rng = rng

    -- PVP mode buttons (3.3.5 doesn't have a UIRadioButtonTemplate that
    -- works cleanly with dynamic count - use three UIPanelButtonTemplate
    -- buttons and repaint the active one).
    local pvpLbl = fs(card, "PvP mode", "GameFontNormalSmall", UI.C.dim[1], UI.C.dim[2], UI.C.dim[3])
    pvpLbl:SetPoint("TOPLEFT", 14, -260)
    self._combat.pvpBtns = {}
    local labels = { { "auto", "Auto" }, { "on", "PvP On" }, { "off", "PvP Off" } }
    for i, spec in ipairs(labels) do
        local key, lbl = spec[1], spec[2]
        local b = stockButton(card, lbl, 80, 22, function()
            RaijinLabDB.combat.pvp_mode = key
            self:RefreshCombat()
        end)
        b:SetPoint("TOPLEFT", 14 + (i - 1) * 86, -282)
        self._combat.pvpBtns[key] = b
    end
end

function Menu:RefreshCombat()
    if not self._combat then return end
    self:RefreshEnables()   -- reads modules.combat, the only real flag
    self._combat.engage:SetChecked(RaijinLabDB.combat.engage and true or false)
    self._combat.dis:SetValue(RaijinLabDB.combat.disengage_hp or 25)
    self._combat.rng:SetValue(RaijinLabDB.combat.engage_range or 30)
    for k, b in pairs(self._combat.pvpBtns) do
        if b.LockHighlight then
            if k == RaijinLabDB.combat.pvp_mode then b:LockHighlight() else b:UnlockHighlight() end
        end
    end
end

-- ============================================================
-- NAVIGATION TAB
-- ============================================================

function Menu:BuildNav(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.nav = p

    local card = UI.inset(p)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", 0, 0)
    card:SetHeight(180)
    UI.section(card, "Navigation Service"):SetPoint("TOPLEFT", 12, -10)

    local blurb = fs(card,
        "Shared pathfinding service used by Combat, Gathering, Questing, and Grinding.\n"
        .. "Consumers request goals via Nav.request_move - they never re-implement CTM.\n\n"
        .. "|cffffd200Click-to-move is permanently disabled|r by DisableCTM.lua. It is intercepted "
        .. "at SetCVar and re-forced off on every world-entry.",
        "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", 14, -38); blurb:SetPoint("RIGHT", -14, 0)
    blurb:SetJustifyH("LEFT")

    local dbgCb = UI.checkbox(card, nextName("RLCTMDbg"), "Log CTM force-off events (debug)",
        RaijinLabDB.ctm_debug, function(v) RaijinLabDB.ctm_debug = v end)
    dbgCb:SetPoint("TOPLEFT", 14, -140)

    local force = stockButton(p, "Force CTM Off Now", 160, 22, function()
        if RaijinLab.ctm and RaijinLab.ctm.force_off then
            RaijinLab.ctm.force_off()
            print("|cffffd200RaijinLab|r CTM force-off triggered manually.")
        end
    end)
    force:SetPoint("TOPLEFT", 14, -196)

    -- OM Probe card - arms the runtime OM PROBE dump on next Refresh so the
    -- log records per-guid ObjectPtr outcomes. Runs `/raijin om` internally.
    local probe = UI.inset(p)
    probe:SetPoint("TOPLEFT", 0, -240)
    probe:SetPoint("TOPRIGHT", 0, -240)
    probe:SetHeight(120)
    UI.section(probe, "Object Manager Probe"):SetPoint("TOPLEFT", 12, -10)
    local probeBlurb = fs(probe,
        "Arms the runtime's OM PROBE dump on next Refresh (writes per-guid ObjectPtr "
        .. "mask outcomes + list-walk head to runtime.log). Use when npcs=0 to diagnose "
        .. "which lookup path is failing. `set RL_LOG=1` before inject for persistent logs.",
        "GameFontDisableSmall")
    probeBlurb:SetPoint("TOPLEFT", 14, -34); probeBlurb:SetPoint("RIGHT", -14, 0)
    probeBlurb:SetJustifyH("LEFT")
    local runProbe = stockButton(probe, "Arm OM Probe", 140, 22, function()
        if not (RaijinLab.HasRuntime and RaijinLab:HasRuntime()) then
            print("|cffff5555RaijinLab|r OM probe: runtime not injected.")
            return
        end
        local Mw = RaijinLab.Master
        if Mw and Mw.in_suite_warm and Mw.in_suite_warm() then
            print("|cffffd200RaijinLab|r OM probe blocked during suite warm (~8s).")
            return
        end
        RaijinLab:RuntimeCall("SetSystemVar", "om.enable", "1")
        RaijinLab:RuntimeCall("SetSystemVar", "om.probe", "1")
        local pstr = RaijinLab:RuntimeCall("OmProbe")
        if type(pstr) == "string" and pstr ~= "" then
            print("|cffffd200RaijinLab OM|r  " .. pstr)
        else
            print("|cffffd200RaijinLab|r OM probe armed. Move around near mobs, then check "
                .. "C:\\Ascension\\Workspace\\logs\\runtime.log for 'OM PROBE' lines.")
        end
    end)
    runProbe:SetPoint("TOPLEFT", 14, -92)
end

-- ============================================================
-- GATHERING TAB
-- ============================================================

function Menu:BuildGather(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.gather = p
    p = self:ScrollBody(p, 650)

    local card = UI.inset(p)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", 0, 0)
    card:SetHeight(280)
    UI.section(card, "Gathering"):SetPoint("TOPLEFT", 12, -10)

    self._gather = {}
    self._gather.enable = self:ModuleEnable(card, "gather", "Enable Gatherer", 14, -38)

    -- Radius
    self._gather.radius = UI.slider(card, nextName("RLGathR"), "Scan radius (yards)",
        20, 200, 10, RaijinLabDB.gather.radius or 60,
        function(v) RaijinLabDB.gather.radius = math.floor(v + 0.5) end,
        function(v) return math.floor(v + 0.5) .. " yd" end)
    self._gather.radius:SetPoint("TOPLEFT", 20, -80)

    -- Profession checkboxes
    local profLbl = fs(card, "Professions", "GameFontNormalSmall", UI.C.dim[1], UI.C.dim[2], UI.C.dim[3])
    profLbl:SetPoint("TOPLEFT", 14, -128)
    self._gather.profs = {}
    local profs = { "herbalism", "mining", "fishing", "woodcutting" }
    for i, name in ipairs(profs) do
        local cap = string.upper(name:sub(1,1)) .. name:sub(2)
        local cb = UI.checkbox(card, nextName("RLGathProf"), cap,
            RaijinLabDB.gather.professions[name],
            function(v) RaijinLabDB.gather.professions[name] = v end)
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", 20 + col * 200, -148 - row * 28)
        self._gather.profs[name] = cb
    end
    self._gather.radius:SetPoint("TOPLEFT", 20, -70)

    -- WHICH PROFESSIONS. Herbalism/mining/woodcutting only need a node in range,
    -- so they default ON. FISHING NEEDS A POLE AND A PLACE, so it is strictly
    -- opt-in: defaulting it on is what made enabling this module instantly demand
    -- a fishing rod. See Gatherer.OPT_IN.
    local prof = UI.inset(p)
    prof:SetPoint("TOPLEFT", 0, -290)
    prof:SetPoint("TOPRIGHT", 0, -290)
    prof:SetHeight(200)
    UI.section(prof, "Professions"):SetPoint("TOPLEFT", 12, -10)

    self._gatherProf = self._gatherProf or {}
    local py = -38
    for _, e in ipairs({
        { "herbalism",  "Herbalism - pick herb nodes", true },
        { "mining",     "Mining - mine ore veins", true },
        { "woodcutting","Woodcutting / chests and misc nodes", true },
        { "fishing",    "Fishing - OPT-IN: needs a pole equipped and a pool", false },
    }) do
        local key, label, dflt = e[1], e[2], e[3]
        local g = RaijinLabDB.gather.professions or {}
        local cur = (g[key] ~= nil) and g[key] or dflt
        local cb = UI.checkbox(prof, nextName("RLProf"), label, cur, function(v)
            RaijinLabDB.gather.professions = RaijinLabDB.gather.professions or {}
            RaijinLabDB.gather.professions[key] = v
        end)
        cb:SetPoint("TOPLEFT", 14, py)
        self._gatherProf[key] = { w = cb, default = dflt }
        py = py - 26
    end

    local fish = UI.inset(p)
    fish:SetPoint("TOPLEFT", 0, -498)
    fish:SetPoint("TOPRIGHT", 0, -498)
    fish:SetHeight(130)
    UI.section(fish, "Fishing"):SetPoint("TOPLEFT", 12, -10)
    local fb = fs(fish, "Fishing only fires with a pole equipped AND a pool in sight " ..
        "(or 'fish here' below). Pool detection needs pool entry ids in " ..
        "RaijinLabDB.gather.entries.fishing - there is no built-in list.",
        "GameFontDisableSmall")
    fb:SetPoint("TOPLEFT", 14, -34); fb:SetPoint("RIGHT", -14, 0); fb:SetJustifyH("LEFT")
    self:Options(fish, "gather", {
        { key = "prefer_fishing",
          label = "Fish here - treat this spot as fishable without a detected pool",
          default = false },
    }, -78, "_gatherOpts")
end

function Menu:RefreshGather()
    if not self._gather then return end
    self:RefreshEnables()   -- reads modules.gather, the only real flag
    self._gather.radius:SetValue(RaijinLabDB.gather.radius or 60)
    for name, cb in pairs(self._gather.profs) do
        cb:SetChecked(RaijinLabDB.gather.professions[name] and true or false)
    end
end

-- ============================================================
-- QUESTING TAB
-- ============================================================

-- ============================================================
-- OPTION PANELS
-- ============================================================
-- Laying out twenty controls by hand is where panels rot: a setting gets added to
-- the module and nobody adds the control, or a control is added for a key nothing
-- reads. So a panel is declared as a LIST OF SETTINGS bound to real config keys,
-- and the layout is computed. Adding an option is one line next to the others.
--
-- `store` is the SavedVariables sub-table the panel edits (RaijinLabDB.quest,
-- RaijinLabDB.gather). Every entry names a key that a module actually consumes;
-- a control for a key nothing reads is worse than no control, because it looks
-- like it works.
-- A SCROLLING BODY FOR PAGES THAT OUTGREW THE WINDOW.
--
-- Cards were being anchored at fixed offsets down the page - -228, -486, -498 -
-- against a content area of the window height minus about 90px. Anything past
-- that is simply not reachable: the controls exist, are wired, and cannot be
-- seen or clicked. Adding options to a fixed-height page silently buries them.
--
-- Returns the frame to parent cards to. Anchor cards to it exactly as before;
-- it grows and scrolls instead of clipping.
-- THE ENABLE CONTROL FOR A MODULE PAGE.
--
-- Every page used to carry its own `RaijinLabDB.<mod>.enabled` alongside
-- `RaijinLabDB.modules.<mod>`. Nothing outside the menu ever read those page
-- flags - they were shadow state, written in two places, free to disagree with
-- the switch that actually runs the module. Two flags for one concept is not a
-- convenience, it is a bug waiting for one of them to be set alone.
--
-- So: one flag (`modules[key]`), one control shape, and the same dependency
-- resolution the Home grid uses - enabling the quester here must pull up rotation
-- and combat exactly as it does there, or the two screens disagree about what
-- "on" means.
function Menu:ModuleEnable(card, key, label, x, y)
    local UI = UIx()
    self:EnsureDB()
    local cb = UI.checkbox(card, nextName("RLEn"), label,
        RaijinLabDB.modules[key], function(v)
            RaijinLabDB.modules[key] = v
            if v and RaijinLab.Master and RaijinLab.Master.missing_deps then
                local need = RaijinLab.Master.missing_deps(key)
                for _, dep in ipairs(need) do
                    RaijinLabDB.modules[dep] = true
                    self:ApplyModuleState(dep)
                end
                if #need > 0 and print then
                    print("|cff7ec8e3RaijinLab|r " .. key .. " also needs " ..
                          table.concat(need, ", ") .. " - enabled")
                end
            end
            self:ApplyModuleState(key)
            self:RefreshHome()
        end)
    cb:SetPoint("TOPLEFT", x or 14, y or -38)
    self._enables = self._enables or {}
    self._enables[key] = cb
    return cb
end

-- Push the real flag back into every page checkbox, so the pages and the Home
-- grid can never show different answers.
function Menu:RefreshEnables()
    if not self._enables then return end
    self:EnsureDB()
    for key, cb in pairs(self._enables) do
        if cb.SetChecked then cb:SetChecked(RaijinLabDB.modules[key] and true or false) end
    end
end

function Menu:ScrollBody(page, height)
    local sf = CreateFrame("ScrollFrame", nextName("RLScroll"), page,
                           "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -26, 0)      -- room for the scrollbar
    local body = CreateFrame("Frame", nextName("RLBody"), sf)
    body:SetWidth(1)                        -- width is driven by the scroll frame
    body:SetHeight(height or 900)
    sf:SetScrollChild(body)
    -- The child must be told its width or the anchors inside it collapse.
    sf:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then body:SetWidth(w) end end)
    return body
end

function Menu:Options(card, store_name, spec, startY, refresh_key)
    local UI = UIx()
    self[refresh_key] = self[refresh_key] or {}
    local widgets = self[refresh_key]
    local y = startY or -38
    for _, o in ipairs(spec) do
        local key = o.key
        local function store()
            RaijinLabDB[store_name] = RaijinLabDB[store_name] or {}
            return RaijinLabDB[store_name]
        end
        if o.kind == "header" then
            local h = fs(card, o.label, "GameFontNormal")
            h:SetPoint("TOPLEFT", 14, y)
            y = y - 22
        elseif o.kind == "slider" then
            local cur = store()[key]
            if cur == nil then cur = o.default end
            local w = UI.slider(card, nextName("RLOpt"), o.label,
                o.min, o.max, o.step, cur,
                function(v) store()[key] = math.floor(v + 0.5) end,
                function(v) return math.floor(v + 0.5) .. (o.unit or "") end)
            w:SetPoint("TOPLEFT", 20, y)
            widgets[key] = { w = w, kind = "slider", default = o.default }
            y = y - 50
        else
            local cur = store()[key]
            if cur == nil then cur = o.default end
            local w = UI.checkbox(card, nextName("RLOpt"), o.label, cur, function(v)
                store()[key] = v
                if o.on_change then o.on_change(self, v) end
            end)
            w:SetPoint("TOPLEFT", 14, y)
            widgets[key] = { w = w, kind = "check", default = o.default }
            y = y - 26
        end
    end
    return y
end

-- Push saved values back into the widgets. Without this a panel shows whatever
-- it was built with and silently disagrees with the config it is editing.
function Menu:RefreshOptions(store_name, refresh_key)
    local widgets = self[refresh_key]
    if not widgets then return end
    local store = RaijinLabDB[store_name] or {}
    for key, e in pairs(widgets) do
        local v = store[key]
        if v == nil then v = e.default end
        if e.kind == "check" and e.w.SetChecked then
            e.w:SetChecked(v and true or false)
        elseif e.kind == "slider" and e.w.SetValue then
            pcall(e.w.SetValue, e.w, tonumber(v) or e.default or 0)
        end
    end
end

function Menu:BuildQuest(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.quest = p
    -- The quest page carries three cards totalling ~790px; the window content
    -- area is nowhere near that, so it scrolls.
    p = self:ScrollBody(p, 800)

    local card = UI.inset(p)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", 0, 0)
    card:SetHeight(220)
    UI.section(card, "Questing Suite"):SetPoint("TOPLEFT", 12, -10)

    local blurb = fs(card, "Accept - turn-in - kill - collect - use-object loop. Uses nav + combat + gather primitives.",
        "GameFontDisableSmall")
    blurb:SetPoint("TOPLEFT", 14, -38); blurb:SetPoint("RIGHT", -14, 0)
    blurb:SetJustifyH("LEFT")

    self._quest = {}
    self._quest.enable = self:ModuleEnable(card, "quest",
        "Enable Questing Suite (also enables rotation + combat)", 14, -74)

    self._quest.acc = UI.checkbox(card, nextName("RLQAcc"), "Auto-accept quests when interacting with givers",
        RaijinLabDB.quest.auto_accept, function(v) RaijinLabDB.quest.auto_accept = v end)
    self._quest.acc:SetPoint("TOPLEFT", 14, -102)

    self._quest.turn = UI.checkbox(card, nextName("RLQTurn"), "Auto-turn-in completed quests",
        RaijinLabDB.quest.auto_turnin, function(v) RaijinLabDB.quest.auto_turnin = v end)
    self._quest.turn:SetPoint("TOPLEFT", 14, -130)

    -- WHAT THE QUESTER IS ALLOWED TO DO ON ITS OWN. Each of these is a real
    -- decision the suite makes mid-run - break off to sell, stop to eat, mount
    -- for a long leg - and each was previously only reachable by editing saved
    -- variables by hand.
    local svc = UI.inset(p)
    svc:SetPoint("TOPLEFT", 0, -228)
    svc:SetPoint("TOPRIGHT", 0, -228)
    svc:SetHeight(250)
    UI.section(svc, "Services the quester may use"):SetPoint("TOPLEFT", 12, -10)
    self:Options(svc, "quest", {
        { key = "use_gather",      label = "Gather nodes seen along the way", default = true },
        { key = "use_vendor",      label = "Sell junk and repair when full or damaged", default = true },
        { key = "use_rest",        label = "Eat and drink to recover between fights", default = true },
        { key = "use_mount",       label = "Mount for long travel legs", default = true },
        { key = "use_rotation",    label = "Use the rotation engine to fight", default = true },
        { key = "use_flightpaths", label = "Take flight paths for cross-zone travel", default = true },
        { key = "loot",            label = "Loot corpses", default = true },
    }, -38, "_questOpts")

    local tune = UI.inset(p)
    tune:SetPoint("TOPLEFT", 0, -486)
    tune:SetPoint("TOPRIGHT", 0, -486)
    tune:SetHeight(300)
    UI.section(tune, "Tuning"):SetPoint("TOPLEFT", 12, -10)
    self:Options(tune, "quest", {
        { kind = "slider", key = "flee_hp", label = "Break off and recover below HP %",
          min = 0, max = 90, step = 5, default = 20, unit = " %" },
        { kind = "slider", key = "engage_dist", label = "Engage objectives within",
          min = 5, max = 60, step = 5, default = 30, unit = " yd" },
        { kind = "slider", key = "objective_scan_dist", label = "Scan for objectives out to",
          min = 20, max = 200, step = 10, default = 100, unit = " yd" },
        { kind = "slider", key = "gather_radius", label = "Detour for a node within",
          min = 0, max = 120, step = 10, default = 40, unit = " yd" },
        { kind = "slider", key = "interact_dist", label = "Interact range",
          min = 3, max = 20, step = 1, default = 5, unit = " yd" },
    }, -38, "_questOpts")
end

function Menu:RefreshGather()
    self:RefreshEnables()
    if self._gatherProf then
        local g = (RaijinLabDB.gather and RaijinLabDB.gather.professions) or {}
        for key, e in pairs(self._gatherProf) do
            local v = g[key]
            if v == nil then v = e.default end
            if e.w.SetChecked then e.w:SetChecked(v and true or false) end
        end
    end
    self:RefreshOptions("gather", "_gatherOpts")
end

function Menu:RefreshQuest()
    if not self._quest then return end
    self:RefreshEnables()
    self._quest.acc:SetChecked(RaijinLabDB.quest.auto_accept and true or false)
    self._quest.turn:SetChecked(RaijinLabDB.quest.auto_turnin and true or false)
    self:RefreshOptions("quest", "_questOpts")
end

-- ============================================================
-- GRINDING TAB
-- ============================================================

function Menu:BuildGrind(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.grind = p

    local card = UI.inset(p)
    card:SetPoint("TOPLEFT", 0, 0)
    card:SetPoint("TOPRIGHT", 0, 0)
    card:SetHeight(260)
    UI.section(card, "Grinding"):SetPoint("TOPLEFT", 12, -10)

    self._grind = {}
    self._grind.enable = self:ModuleEnable(card, "grind",
        "Enable Grinder (also enables rotation + combat)", 14, -38)
    self._grind.enable:SetPoint("TOPLEFT", 14, -38)

    self._grind.radius = UI.slider(card, nextName("RLGrindR"), "Grind radius (yards)",
        10, 120, 5, RaijinLabDB.grind.radius or 40,
        function(v) RaijinLabDB.grind.radius = math.floor(v + 0.5) end,
        function(v) return math.floor(v + 0.5) .. " yd" end)
    self._grind.radius:SetPoint("TOPLEFT", 20, -80)

    -- Route control
    local rtLbl = fs(card, "Route waypoints", "GameFontNormalSmall", UI.C.dim[1], UI.C.dim[2], UI.C.dim[3])
    rtLbl:SetPoint("TOPLEFT", 14, -128)
    self._grind.count = fs(card, "0 waypoints", "GameFontHighlightSmall")
    self._grind.count:SetPoint("TOPLEFT", 14, -146)

    local addWP = stockButton(card, "Add current position", 160, 22, function()
        RaijinLabDB.grind.route = RaijinLabDB.grind.route or {}
        local x, y, z
        if RaijinLab.ObjectPosition then
            x, y, z = RaijinLab:ObjectPosition("player")
        end
        if not x then print("|cffff5555RaijinLab|r no player position (runtime not injected?)") return end
        table.insert(RaijinLabDB.grind.route, { x = x, y = y, z = z })
        print(string.format("|cffffd200RaijinLab|r waypoint %d added @ (%.1f, %.1f, %.1f)",
            #RaijinLabDB.grind.route, x, y, z))
        self:RefreshGrind()
    end)
    addWP:SetPoint("TOPLEFT", 14, -172)

    local clr = stockButton(card, "Clear all", 90, 22, function()
        RaijinLabDB.grind.route = {}
        self:RefreshGrind()
        print("|cffffd200RaijinLab|r route cleared.")
    end)
    clr:SetPoint("LEFT", addWP, "RIGHT", 8, 0)

    local pop = stockButton(card, "Remove last", 100, 22, function()
        if RaijinLabDB.grind.route and #RaijinLabDB.grind.route > 0 then
            table.remove(RaijinLabDB.grind.route)
            self:RefreshGrind()
        end
    end)
    pop:SetPoint("LEFT", clr, "RIGHT", 8, 0)
end

function Menu:RefreshGrind()
    if not self._grind then return end
    self:RefreshEnables()   -- reads modules.grind, the only real flag
    self._grind.radius:SetValue(RaijinLabDB.grind.radius or 40)
    local n = RaijinLabDB.grind.route and #RaijinLabDB.grind.route or 0
    self._grind.count:SetText(n == 0
        and "|cff888888no waypoints yet|r"
        or  string.format("%d waypoint%s configured", n, n == 1 and "" or "s"))
end

-- ============================================================
-- DEBUG TAB - live log window + verbose-chat toggle
-- ============================================================
function Menu:BuildDebug(parent)
    local UI = UIx()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(); p:Hide()
    self.pages.debug = p

    -- WORLD RENDERING. Short labels so the log panel below is not crushed, and
    -- the body is ANCHORED TO head - never absolute TOPLEFT -66 (that overlaid
    -- the entire log on top of these checkboxes - the live "buggy disaster").
    local rend = UI.inset(p)
    rend:SetPoint("TOPLEFT", 0, 0)
    rend:SetPoint("TOPRIGHT", 0, 0)
    local LAYER_LABEL = {
        grid       = "Nav grid",
        path       = "Path + waypoints",
        search     = "Search field",
        target     = "Target markers",
        controller = "Steering probe",
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
    -- 5 layers * 26px + header ~ 34 + pad
    rend:SetHeight(34 + (#rspec * 26) + 16)
    UI.section(rend, "World rendering"):SetPoint("TOPLEFT", 12, -10)
    self:Options(rend, "vision", rspec, -34, "_visionOpts")

    -- Header row: verbose toggle + Clear + Copy
    local head = UI.inset(p)
    head:SetPoint("TOPLEFT", rend, "BOTTOMLEFT", 0, -6)
    head:SetPoint("TOPRIGHT", rend, "BOTTOMRIGHT", 0, -6)
    head:SetHeight(52)
    UI.section(head, "Debug log"):SetPoint("TOPLEFT", 12, -8)

    local verbCb = CreateFrame("CheckButton", "RaijinLabDebugVerboseCB", head, "UICheckButtonTemplate")
    verbCb:SetWidth(24); verbCb:SetHeight(24)
    verbCb:SetPoint("TOPLEFT", 14, -26)
    verbCb:SetChecked(RaijinLab.chat_verbose and true or false)
    local verbTxt = _G[verbCb:GetName() .. "Text"]
    if verbTxt then
        verbTxt:SetText("Verbose chat")
        verbTxt:SetFontObject(GameFontHighlightSmall)
    end
    verbCb:SetScript("OnClick", function(self_)
        RaijinLab.chat_verbose = self_:GetChecked() and true or false
        RaijinLab:SetSystemVar("RaijinLab.chat_verbose", tostring(RaijinLab.chat_verbose))
    end)

    local clear = stockButton(head, "Clear", 70, 22, function()
        if RaijinLab.DebugLog and RaijinLab.DebugLog.Clear then RaijinLab.DebugLog.Clear() end
    end)
    clear:SetPoint("TOPRIGHT", -14, -24)

    local copy = stockButton(head, "Copy", 70, 22, function() self:ShowDebugCopyDialog() end)
    copy:SetPoint("RIGHT", clear, "LEFT", -6, 0)

    -- Body: scrolling log - MUST hang under head, not absolute y=-66.
    local body = UI.inset(p)
    body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
    body:SetPoint("BOTTOMRIGHT", 0, 0)

    local scroll = CreateFrame("ScrollFrame", nil, body)
    scroll:SetPoint("TOPLEFT", 10, -10)
    scroll:SetPoint("BOTTOMRIGHT", -28, 10)
    scroll:EnableMouseWheel(true)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(600)   -- resized on each refresh to match scroll width
    child:SetHeight(1)
    scroll:SetScrollChild(child)

    local text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", 0, 0)
    text:SetJustifyH("LEFT"); text:SetJustifyV("TOP")
    text:SetWidth(600)
    text:SetText("")

    local slider = CreateFrame("Slider", nil, body)
    slider:SetPoint("TOPRIGHT", -10, -10)
    slider:SetPoint("BOTTOMRIGHT", -10, 10)
    slider:SetWidth(14)
    slider:SetOrientation("VERTICAL")
    slider:SetValueStep(20)
    if UI.paint then UI.paint(slider, UI.C.bg2) end
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(1, 1, 1, 1)
    thumb:SetVertexColor(0.35, 0.65, 0.8, 1)
    thumb:SetWidth(12); thumb:SetHeight(28)
    slider:SetThumbTexture(thumb)
    slider:SetMinMaxValues(0, 1)
    slider:SetValue(0)
    slider:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local cur = slider:GetValue() or 0
        local _, mx = slider:GetMinMaxValues()
        slider:SetValue(math.max(0, math.min(mx, cur - delta * 40)))
    end)

    self._debug = {
        page = p, text = text, child = child, scroll = scroll, slider = slider,
        verb = verbCb, autoscroll = true,
    }

    -- Track user scroll: if they scroll away from bottom, stop auto-following.
    slider:HookScript("OnValueChanged", function(_, v)
        local _, mx = slider:GetMinMaxValues()
        self._debug.autoscroll = (mx == 0) or (v >= mx - 2)
    end)

    -- Subscribe to log push events. Throttle UI rebuild to ~8 Hz so a busy
    -- rotation cannot freeze the client by rebuilding a 3000-line FontString
    -- every frame (that made the Debug tab look "dead" / unreadable).
    if RaijinLab.DebugLog and RaijinLab.DebugLog.Subscribe then
        RaijinLab.DebugLog.Subscribe(function()
            if self.activeTab == "debug" and self._debug and self._debug.page:IsShown() then
                self._debug.dirty = true
            end
        end)
    end
    p:SetScript("OnUpdate", function(_, elapsed)
        if not self._debug or not self._debug.dirty then return end
        self._debug._acc = (self._debug._acc or 0) + (elapsed or 0)
        if self._debug._acc < 0.12 then return end
        self._debug._acc = 0
        self._debug.dirty = false
        if self.activeTab == "debug" and self._debug.page:IsShown() then
            self:RefreshDebug()
        end
    end)
end

function Menu:ShowDebugCopyDialog()
    local UI = UIx()
    local f = _G.RaijinLabDebugCopy or CreateFrame("Frame", "RaijinLabDebugCopy", UIParent)
    f:SetWidth(560); f:SetHeight(360)
    f:ClearAllPoints(); f:SetPoint("CENTER")
    if UI and UI.RegisterWindow then UI.RegisterWindow(f)
    else f:SetFrameStrata("DIALOG"); f:SetFrameLevel(240) end
    if UI and UI.dialogFrame then UI.dialogFrame(f, "Debug log - Ctrl+A / Ctrl+C") end
    if UI and UI.paint then UI.paint(f, { 0.06, 0.05, 0.03, 1.0 }) end
    f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self_) self_:StartMoving() end)
    f:SetScript("OnDragStop",  function(self_) self_:StopMovingOrSizing() end)
    if not f._built then
        UI.closeButton(f)
        local sc = CreateFrame("ScrollFrame", nil, f)
        sc:SetPoint("TOPLEFT", 16, -40)
        sc:SetPoint("BOTTOMRIGHT", -16, 16)
        local eb = CreateFrame("EditBox", nil, sc)
        eb:SetMultiLine(true); eb:SetAutoFocus(true)
        eb:SetFontObject(GameFontHighlightSmall or "GameFontHighlightSmall")
        eb:SetWidth(500); eb:SetMaxLetters(0)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sc:SetScrollChild(eb)
        f._eb = eb
        f._built = true
    end
    -- Cap the copied log: 3000 spam lines concatenated into one SetText froze
    -- the client for ~20 s. The last 800 lines are plenty for diagnosis and the
    -- concat/SetText stays cheap.
    local snap = RaijinLab.DebugLog and RaijinLab.DebugLog.Snapshot() or {}
    local first = math.max(1, #snap - 799)
    local lines = {}
    for i = first, #snap do
        local e = snap[i]
        lines[#lines + 1] = e.t .. " " .. e.text
    end
    f._eb:SetText(table.concat(lines, "\n"))
    f._eb:HighlightText(); f._eb:SetFocus()
    f:Show()
end

function Menu:RefreshDebug()
    -- Without this the checkboxes show whatever they were built with and
    -- silently disagree with the config they edit.
    self:RefreshOptions("vision", "_visionOpts")
    local d = self._debug
    if not d then return end
    -- Rebuild the full text - cheap enough for a 500-line ring buffer.
    local snap = RaijinLab.DebugLog and RaijinLab.DebugLog.Snapshot() or {}
    local lines = {}
    for _, e in ipairs(snap) do lines[#lines + 1] = "|cff888888" .. e.t .. "|r " .. e.text end
    d.text:SetText(table.concat(lines, "\n"))
    -- Resize child to text height so the ScrollFrame can scroll all of it.
    local w = d.scroll:GetWidth() - 4
    if w and w > 0 then d.child:SetWidth(w); d.text:SetWidth(w) end
    local h = d.text:GetStringHeight() + 4
    d.child:SetHeight(math.max(h, d.scroll:GetHeight()))
    local visible = d.scroll:GetHeight()
    local maxScroll = math.max(0, h - visible)
    d.slider:SetMinMaxValues(0, maxScroll)
    if d.autoscroll then
        d.slider:SetValue(maxScroll)
        d.scroll:SetVerticalScroll(maxScroll)
    end
    -- Keep the checkbox in sync with the flag (may have been toggled via /raijin quiet).
    if d.verb then d.verb:SetChecked(RaijinLab.chat_verbose and true or false) end
end

if RaijinLab then
    RaijinLab.Menu = Menu
end

return Menu
