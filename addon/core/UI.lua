-- Shared UI skin for RaijinLab (3.3.5-safe, no retail BackdropTemplate required).
-- Layered textures + accent chrome for a cleaner control-panel look.

local UI = {}

-- WoW-authentic palette (warm parchment / gold). Chosen to harmonize with
-- SetBackdrop("Interface\\DialogFrame\\UI-DialogBox-Background") used by
-- UI.dialogFrame() so cards/rows read as darker insets on parchment.
UI.C = {
    bg0     = { 0.00, 0.00, 0.00, 0.00 },  -- transparent (outer frame uses SetBackdrop)
    bg1     = { 0.06, 0.05, 0.03, 0.88 },  -- dark warm brown - section cards
    bg2     = { 0.12, 0.09, 0.05, 0.88 },  -- rows
    bg3     = { 0.20, 0.15, 0.09, 0.92 },  -- row hover
    line    = { 0.42, 0.32, 0.20, 1.00 },  -- tan-gold rule
    accent  = { 1.00, 0.82, 0.00, 1.00 },  -- WoW classic gold (GameFontNormal)
    accent2 = { 0.80, 0.65, 0.10, 1.00 },
    text    = { 1.00, 0.82, 0.00, 1.00 },  -- yellow (Normal)
    textLt  = { 1.00, 1.00, 1.00, 1.00 },  -- white (Highlight)
    dim     = { 0.55, 0.45, 0.35, 1.00 },
    good    = { 0.10, 1.00, 0.10, 1.00 },  -- uncommon green
    warn    = { 1.00, 0.60, 0.10, 1.00 },
    bad     = { 1.00, 0.10, 0.10, 1.00 },
    btn     = { 0.10, 0.07, 0.05, 0.90 },
    btnHi   = { 0.24, 0.16, 0.08, 1.00 },
    tabOn   = { 0.16, 0.11, 0.06, 1.00 },
    tabOff  = { 0.06, 0.04, 0.03, 1.00 },
    hi      = { 0.58, 0.47, 0.29, 0.55 },  -- warm light bevel edge (top/left)
    shadow  = { 0.00, 0.00, 0.00, 0.45 },  -- dark bevel edge (bottom/right)
}

local WHITE = "Interface\\Buttons\\WHITE8X8"

local function solid(tex, c)
    tex:SetTexture(1, 1, 1, 1)
    tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
end

-- ---- window layering ------------------------------------------------------
-- WoW draws by STRATA first, then by frame level within a strata. The order is
--   BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG
-- so a window at HIGH is drawn UNDER anything at DIALOG - including Blizzard's
-- own panels and our own editor. That is why the suite menu could end up behind
-- the very windows it opens.
--
-- Policy: every suite window lives in ONE strata (DIALOG) and is ordered purely
-- by frame level, with a shared counter so the window you last clicked is on top.
-- Keeping them in the same strata is what makes "click to raise" work at all -
-- across strata, level is ignored.
UI.WINDOW_STRATA = "DIALOG"
UI.MODAL_STRATA  = "FULLSCREEN_DIALOG"   -- dropdowns/confirms must beat our windows
UI._z = 100                              -- next free level in the window strata
UI._windows = {}

-- Bring `frame` above every other registered suite window.
function UI.BringToFront(frame)
    if not frame or not frame.SetFrameLevel then return end
    -- Frame levels are bounded, so re-base rather than counting up forever.
    if UI._z > 600 then
        UI._z = 100
        for _, w in ipairs(UI._windows) do
            if w and w.SetFrameLevel and w ~= frame then
                UI._z = UI._z + 10
                pcall(w.SetFrameLevel, w, UI._z)
            end
        end
    end
    UI._z = UI._z + 10
    pcall(frame.SetFrameStrata, frame, UI.WINDOW_STRATA)
    pcall(frame.SetFrameLevel, frame, UI._z)
    if frame.Raise then pcall(frame.Raise, frame) end
end

-- Register a suite window: puts it in the window strata, makes it come to the
-- front when clicked or shown, and keeps it in the re-base set.
--   opts.base   - starting level offset (a child window can sit above its parent)
--   opts.modal  - use the modal strata instead (dropdowns, confirmations)
function UI.RegisterWindow(frame, opts)
    if not frame then return end
    opts = opts or {}
    local known = false
    for _, w in ipairs(UI._windows) do if w == frame then known = true end end
    if not known then UI._windows[#UI._windows + 1] = frame end

    if opts.modal then
        pcall(frame.SetFrameStrata, frame, UI.MODAL_STRATA)
        if frame.SetFrameLevel then pcall(frame.SetFrameLevel, frame, opts.base or 20) end
    else
        UI.BringToFront(frame)
    end
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, true) end
    -- SetToplevel handles raising within a strata for MOUSE-ENABLED frames, but it
    -- does not cover programmatic Show(), so both are wired.
    if frame.SetToplevel then pcall(frame.SetToplevel, frame, true) end

    if frame.HookScript then
        pcall(frame.HookScript, frame, "OnMouseDown", function(self_)
            if not opts.modal then UI.BringToFront(self_) end
        end)
        pcall(frame.HookScript, frame, "OnShow", function(self_)
            if not opts.modal then UI.BringToFront(self_) end
        end)
    end
    return frame
end

function UI.paint(frame, c)
    if not frame._rl_bg then
        frame._rl_bg = frame:CreateTexture(nil, "BACKGROUND")
        frame._rl_bg:SetAllPoints()
    end
    solid(frame._rl_bg, c or UI.C.bg1)
end

function UI.border(frame, c)
    c = c or UI.C.line
    if frame._rl_border then return end
    local edges = {
        { "TOPLEFT", "TOPRIGHT", 0, 0, "TOP", 1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 0, "BOTTOM", 1 },
        { "TOPLEFT", "BOTTOMLEFT", 0, 0, "LEFT", 1 },
        { "TOPRIGHT", "BOTTOMRIGHT", 0, 0, "RIGHT", 1 },
    }
    frame._rl_border = {}
    -- top
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetPoint("TOPLEFT", 0, 0)
    t:SetPoint("TOPRIGHT", 0, 0)
    t:SetHeight(1)
    solid(t, c)
    frame._rl_border.t = t
    local b = frame:CreateTexture(nil, "BORDER")
    b:SetPoint("BOTTOMLEFT", 0, 0)
    b:SetPoint("BOTTOMRIGHT", 0, 0)
    b:SetHeight(1)
    solid(b, c)
    frame._rl_border.b = b
    local l = frame:CreateTexture(nil, "BORDER")
    l:SetPoint("TOPLEFT", 0, 0)
    l:SetPoint("BOTTOMLEFT", 0, 0)
    l:SetWidth(1)
    solid(l, c)
    frame._rl_border.l = l
    local r = frame:CreateTexture(nil, "BORDER")
    r:SetPoint("TOPRIGHT", 0, 0)
    r:SetPoint("BOTTOMRIGHT", 0, 0)
    r:SetWidth(1)
    solid(r, c)
    frame._rl_border.r = r
end

function UI.accentBar(frame, height)
    local bar = frame:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(height or 3)
    solid(bar, UI.C.accent)
    return bar
end

-- Inset bevel: a light top/left edge + dark bottom/right edge, drawn INSIDE the
-- frame's border to give a subtle raised/framed look. Idempotent.
function UI.bevel(frame)
    if frame._rl_bevel then return end
    local top = frame:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT", 1, -1); top:SetPoint("TOPRIGHT", -1, -1); top:SetHeight(1)
    solid(top, UI.C.hi)
    local left = frame:CreateTexture(nil, "BORDER")
    left:SetPoint("TOPLEFT", 1, -1); left:SetPoint("BOTTOMLEFT", 1, 1); left:SetWidth(1)
    solid(left, UI.C.hi)
    local bot = frame:CreateTexture(nil, "BORDER")
    bot:SetPoint("BOTTOMLEFT", 1, 1); bot:SetPoint("BOTTOMRIGHT", -1, 1); bot:SetHeight(1)
    solid(bot, UI.C.shadow)
    local right = frame:CreateTexture(nil, "BORDER")
    right:SetPoint("TOPRIGHT", -1, -1); right:SetPoint("BOTTOMRIGHT", -1, 1); right:SetWidth(1)
    solid(right, UI.C.shadow)
    frame._rl_bevel = { top, left, bot, right }
end

-- Subtle top-lit vertical sheen (white gradient fading down). Adds a soft
-- polish to flat panels/buttons. No-op if the client lacks SetGradientAlpha.
function UI.sheen(frame, strength)
    if frame._rl_sheen then return end
    local t = frame:CreateTexture(nil, "ARTWORK")
    t:SetTexture(WHITE)
    t:SetPoint("TOPLEFT", 1, -1); t:SetPoint("BOTTOMRIGHT", -1, 1)
    local a = strength or 0.06
    if t.SetGradientAlpha then
        -- 3.3.5 VERTICAL gradient: first color = bottom, second = top.
        t:SetGradientAlpha("VERTICAL", 1, 1, 1, 0.0, 1, 1, 1, a)
    else
        t:SetTexture(1, 1, 1, a * 0.5)
    end
    frame._rl_sheen = t
end

function UI.label(parent, text, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", size or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetTextColor(UI.C.text[1], UI.C.text[2], UI.C.text[3])
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
    return fs
end

function UI.dim(parent, text, size)
    local fs = UI.label(parent, text, size or "GameFontNormalSmall")
    fs:SetTextColor(UI.C.dim[1], UI.C.dim[2], UI.C.dim[3])
    return fs
end

function UI.button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w or 120)
    b:SetHeight(h or 26)
    UI.paint(b, UI.C.btn)
    UI.border(b, UI.C.line)
    UI.bevel(b)          -- raised look
    UI.sheen(b, 0.07)    -- top-lit sheen so buttons read as clickable
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(text or "")
    fs:SetTextColor(UI.C.accent[1], UI.C.accent[2], UI.C.accent[3])
    b._fs = fs
    b:SetScript("OnEnter", function(self)
        UI.paint(self, UI.C.btnHi)
        if self._fs then self._fs:SetTextColor(1, 1, 1) end
    end)
    b:SetScript("OnLeave", function(self)
        UI.paint(self, self._active and UI.C.tabOn or UI.C.btn)
        if self._fs then
            local c = self._active and UI.C.text or UI.C.accent
            self._fs:SetTextColor(c[1], c[2], c[3])
        end
    end)
    b:SetScript("OnClick", onClick)
    function b:SetActive(on)
        self._active = on and true or false
        UI.paint(self, on and UI.C.tabOn or UI.C.btn)
        if self._fs then
            local c = on and UI.C.text or UI.C.accent
            self._fs:SetTextColor(c[1], c[2], c[3])
        end
        if self._underline then
            if on then self._underline:Show() else self._underline:Hide() end
        end
    end
    function b:SetLabel(s)
        if self._fs then self._fs:SetText(s) end
    end
    return b
end

function UI.tab(parent, text, w, h, onClick)
    local b = UI.button(parent, text, w, h, onClick)
    local u = b:CreateTexture(nil, "OVERLAY")
    u:SetPoint("BOTTOMLEFT", 4, 1)
    u:SetPoint("BOTTOMRIGHT", -4, 1)
    u:SetHeight(2)
    solid(u, UI.C.accent)
    u:Hide()
    b._underline = u
    return b
end

function UI.card(parent)
    local f = CreateFrame("Frame", nil, parent)
    UI.paint(f, UI.C.bg2)
    UI.border(f, UI.C.line)
    UI.bevel(f)          -- inset depth
    UI.sheen(f, 0.04)    -- faint top sheen
    return f
end

function UI.makeMovable(frame, handle)
    handle = handle or frame
    frame:SetMovable(true)
    frame:EnableMouse(true)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() frame:StartMoving() end)
    handle:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
end

-- Drop zone: call onDrop(spellId, name) when a spell is dropped / clicked with cursor spell
function UI.enableSpellDrop(frame, onDrop)
    frame:EnableMouse(true)
    local function tryDrop()
        if not GetCursorInfo then return false end
        local ctype, a, b = GetCursorInfo()
        if ctype ~= "spell" and ctype ~= "item" and ctype ~= "petaction" then return false end
        local SU = RaijinLab and RaijinLab.SpellUtil
        local spellId, name, petIndex
        if ctype == "spell" and SU then
            spellId, name = SU.resolve_spellbook_cursor(a, b, GetSpellLink, GetSpellName, GetSpellInfo)
        elseif ctype == "spell" and GetSpellLink then
            local link = GetSpellLink(a, b)
            spellId = SU and SU.spell_id_from_link(link) or (type(link) == "string" and tonumber(link:match("spell:(%d+)")))
            name = GetSpellName and GetSpellName(a, b) or (spellId and GetSpellInfo and GetSpellInfo(spellId))
        elseif ctype == "item" then
            spellId, name = a, (GetItemInfo and GetItemInfo(a)) or ("Item " .. tostring(a))
        elseif ctype == "petaction" then
            -- Pet-bar command (Attack / Follow / Stay / stances). `a` is the pet
            -- action slot index (1-10). Store index as a hint; the executor
            -- re-resolves by name at cast time since indices shift per pet.
            petIndex = a
            name = (GetPetActionInfo and GetPetActionInfo(a)) or ("Pet Action " .. tostring(a))
            spellId = 0 -- pet actions have no castable spell id; sentinel 0
        end
        -- Pet actions legitimately have spellId 0; everything else needs a real id.
        if (ctype == "petaction" or spellId) and onDrop then
            onDrop(spellId or 0, name, ctype, petIndex)
            if ClearCursor then ClearCursor() end
            return true
        end
        return false
    end
    frame:SetScript("OnReceiveDrag", function() tryDrop() end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then tryDrop() end
    end)
    -- Visual hint while dragging
    frame:SetScript("OnEnter", function(self)
        local ct = GetCursorInfo and select(1, GetCursorInfo())
        if ct == "spell" or ct == "item" or ct == "petaction" then
            UI.paint(self, UI.C.btnHi)
        end
    end)
end

-- ============================================================
-- Default-WoW aesthetic helpers (added 1.6.2)
--
-- Menu.lua uses these for the outer chrome + native widgets so the addon
-- reads as first-party UI. Editor.lua continues to use paint/border/card
-- above for its internal drag/drop rows.
-- ============================================================

-- Apply the standard 3.3.5 dialog backdrop (brown parchment + gold rope
-- border). Optionally attach the DialogBox header banner + title text.
-- Returns the header frame (nil if no title given) for further layout.
function UI.dialogFrame(frame, titleText)
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetBackdropColor(1, 1, 1, 1)
    if not titleText then return nil end
    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetWidth(315)
    header:SetHeight(64)
    header:SetPoint("TOP", 0, 12)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText(titleText)
    return header, title
end

-- Standard top-right close X. Returns the button.
function UI.closeButton(frame, onClose)
    local c = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    c:SetPoint("TOPRIGHT", -3, -3)
    if onClose then
        c:SetScript("OnClick", function() onClose(frame) end)
    end
    return c
end

-- Bottom-of-panel tab button. Uses plain UIPanelButtonTemplate (universally
-- available on 3.3.5-class builds - CharacterFrameTabButtonTemplate was
-- unreliable on Ascension and rendered as stacked text with no chrome).
-- Callers should space tabs with `SetPoint("LEFT", prev, "RIGHT", 4, 0)`.
function UI.panelTab(parent, index, text, onClick)
    local name = "RaijinLabMenuTab" .. tostring(index)
    local tab = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    tab:SetWidth(92); tab:SetHeight(24)
    tab:SetText(text or "Tab")
    tab:SetID(index)
    if onClick then tab:SetScript("OnClick", function() onClick(index) end) end
    -- Active-tab visual: Disable() is the WoW standard for panel tabs - it
    -- greys the text (clear "you are here" signal) and blocks re-clicking the
    -- current tab. We used to LockHighlight() but Ascension's UIPanelButton
    -- highlight texture rendered as a red-pressed tint that read as a glitch.
    function tab:SetActive(on)
        if on then
            self:Disable()
            self:UnlockHighlight()
        else
            self:Enable()
            self:UnlockHighlight()
        end
    end
    return tab
end

-- Standard UICheckButtonTemplate with an attached label. `checked` sets
-- initial state. `onChange(newChecked)` fires on click.
function UI.checkbox(parent, name, labelText, checked, onChange)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetWidth(24); cb:SetHeight(24)
    cb:SetChecked(checked and true or false)
    -- Nil name is legal (anonymous checkbox); guard the _G lookup so we don't
    -- concatenate nil. Falls through to creating our own label fontstring.
    local textFs = name and _G[name .. "Text"] or nil
    if textFs then
        textFs:SetText(labelText or "")
        textFs:SetFontObject("GameFontNormalSmall")
    else
        textFs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        textFs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
        textFs:SetText(labelText or "")
    end
    cb._text = textFs
    if onChange then
        cb:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
    end
    return cb
end

-- Standard OptionsSliderTemplate. `format` (optional) formats the current-value
-- display next to the slider.
function UI.slider(parent, name, labelText, minV, maxV, step, initialV, onChange, format)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetWidth(180); s:SetHeight(16)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step or 1)
    s:SetValue(initialV or minV)
    local low, high, txt = _G[name .. "Low"], _G[name .. "High"], _G[name .. "Text"]
    if low then low:SetText(tostring(minV)) end
    if high then high:SetText(tostring(maxV)) end
    if txt then txt:SetText(labelText or "") end
    -- Live value badge to the right (OptionsSliderTemplate has no built-in one).
    local val = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("LEFT", s, "RIGHT", 8, 0)
    local function fmt(v)
        if format then return format(v) end
        if step and step < 1 then return string.format("%.2f", v) end
        return tostring(math.floor(v + 0.5))
    end
    val:SetText(fmt(initialV or minV))
    s._val = val
    s:SetScript("OnValueChanged", function(self, v)
        if val then val:SetText(fmt(v)) end
        if onChange then onChange(v) end
    end)
    return s
end

-- Standard scroll frame + scrollchild + hooked scrollbar. Returns (scrollFrame, scrollChild).
function UI.scrollFrame(parent, name)
    local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    local child = CreateFrame("Frame", (name or "RLScroll") .. "Child", sf)
    child:SetWidth(1); child:SetHeight(1)
    sf:SetScrollChild(child)
    return sf, child
end

-- Small inset panel using Interface\\Tooltips\\UI-Tooltip-Background for a
-- readable dark inset on the parchment. Preferred over UI.card for outer
-- sections; UI.card remains for Editor internal rows.
function UI.inset(parent)
    local f = CreateFrame("Frame", nil, parent)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0.05, 0.04, 0.02, 0.85)
        f:SetBackdropBorderColor(UI.C.line[1], UI.C.line[2], UI.C.line[3], 1)
    else
        UI.paint(f, UI.C.bg1)
        UI.border(f, UI.C.line)
    end
    return f
end

-- Yellow header label - "section title" text with a gold underline rule that
-- fades to the right. The rule anchors to the label, so it follows wherever the
-- caller positions the returned FontString (no extra layout work for callers).
function UI.section(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetText(text or "")
    fs:SetTextColor(UI.C.accent[1], UI.C.accent[2], UI.C.accent[3])
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetTexture(WHITE)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    rule:SetPoint("TOPRIGHT", fs, "BOTTOMRIGHT", 160, -3)  -- extend past the text
    local a = UI.C.accent
    if rule.SetGradientAlpha then
        rule:SetGradientAlpha("HORIZONTAL", a[1], a[2], a[3], 0.65, a[1], a[2], a[3], 0.0)
    else
        solid(rule, UI.C.line)
    end
    fs._rule = rule
    return fs
end

-- ============================================================
-- Themed dropdown (custom; dark theme).
--
-- Deliberately NOT UIDropDownMenu: that widget is gold-parchment styled
-- (clashes with this addon's dark chrome), globally named, and taint-fussy.
-- Instead we use ONE shared popup frame + a fullscreen click-catcher,
-- created lazily and reused by every dropdown on screen. Only one popup is
-- ever open, so a singleton is correct and leak-free.
--
-- A dropdown button displays the current value (via an optional formatter)
-- and, on click, opens the popup listing the options; picking one calls
-- onSelect(value) and closes. Clicking anywhere else closes it.
-- ============================================================
local function ensureDropdownPopup()
    if UI._ddPopup then return UI._ddPopup end

    -- Fullscreen transparent catcher: any click outside the popup closes it.
    -- Sits just below the popup within the same (top) strata.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetFrameStrata(UI.MODAL_STRATA)
    catcher:SetFrameLevel(1)
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:Hide()

    local popup = CreateFrame("Frame", nil, UIParent)
    -- Dropdowns are modal: they must draw above every suite window, so they use
    -- the modal strata and are deliberately NOT part of the click-to-raise set.
    popup:SetFrameStrata(UI.MODAL_STRATA)
    popup:SetFrameLevel(20)
    UI.paint(popup, { 0.05, 0.04, 0.02, 1.0 })
    UI.border(popup, UI.C.line)
    popup:Hide()
    popup._rows = {}

    catcher:SetScript("OnMouseDown", function() popup:Hide() end)
    popup:SetScript("OnHide", function()
        catcher:Hide()
        popup._owner = nil
    end)

    UI._ddPopup = popup
    UI._ddCatcher = catcher
    return popup
end

-- Close any open dropdown popup. Call when tearing down a host modal so a
-- stray popup can't outlive its anchor.
function UI.closeDropdowns()
    if UI._ddPopup then UI._ddPopup:Hide() end
end

-- parent      : frame the button lives in
-- width       : button width
-- getOptions  : function() -> { value, value, ... }  (ordered option values)
-- getValue    : function() -> current value (for highlighting the active row)
-- onSelect    : function(value) called on pick
-- formatValue : optional function(value) -> display string (friendly labels)
function UI.dropdown(parent, width, getOptions, getValue, onSelect, formatValue)
    local dd = CreateFrame("Button", nil, parent)
    dd:SetWidth(width or 180)
    dd:SetHeight(24)
    UI.paint(dd, UI.C.bg2)
    UI.border(dd, UI.C.line)
    UI.bevel(dd)

    local fs = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 8, 0)
    fs:SetPoint("RIGHT", -18, 0)
    fs:SetJustifyH("LEFT")
    dd._fs = fs

    -- ASCII caret (v) - the unicode down-triangle renders as "?" on 3.3.5 fonts.
    local caret = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    caret:SetPoint("RIGHT", -6, 0)
    caret:SetText("v")
    caret:SetTextColor(UI.C.accent[1], UI.C.accent[2], UI.C.accent[3])

    dd._format = formatValue
    function dd:SetValue(v)
        self._value = v
        self._fs:SetText((self._format and self._format(v)) or tostring(v))
    end

    dd:SetScript("OnEnter", function(self) UI.paint(self, UI.C.bg3) end)
    dd:SetScript("OnLeave", function(self) UI.paint(self, UI.C.bg2) end)

    dd:SetScript("OnClick", function(self)
        local popup = ensureDropdownPopup()
        -- Toggle: clicking the same dropdown that's open closes it.
        if popup._owner == self and popup:IsShown() then
            popup:Hide()
            return
        end
        popup._owner = self

        local opts = getOptions() or {}
        local rowH = 22
        local rows = popup._rows
        local n = #opts
        local cur = getValue and getValue() or nil

        for i = 1, n do
            local val = opts[i]
            local r = rows[i]
            if not r then
                r = CreateFrame("Button", nil, popup)
                r:SetHeight(rowH)
                r._hl = r:CreateTexture(nil, "BACKGROUND")
                r._hl:SetAllPoints()
                r._fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                r._fs:SetPoint("LEFT", 8, 0)
                r._fs:SetPoint("RIGHT", -8, 0)
                r._fs:SetJustifyH("LEFT")
                r:SetScript("OnEnter", function(s) s._hl:SetTexture(UI.C.accent2[1], UI.C.accent2[2], UI.C.accent2[3], 0.35) end)
                r:SetScript("OnLeave", function(s) s._hl:SetTexture(0, 0, 0, 0) end)
                rows[i] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -2 - (i - 1) * rowH)
            r:SetPoint("RIGHT", popup, "RIGHT", -2, 0)
            r._fs:SetText((formatValue and formatValue(val)) or tostring(val))
            r._hl:SetTexture(0, 0, 0, 0)
            if cur ~= nil and cur == val then
                r._fs:SetTextColor(UI.C.accent[1], UI.C.accent[2], UI.C.accent[3])
            else
                r._fs:SetTextColor(1, 1, 1)
            end
            r:SetScript("OnClick", function()
                popup:Hide()
                dd:SetValue(val)
                if onSelect then onSelect(val) end
            end)
            r:Show()
        end
        for i = n + 1, #rows do rows[i]:Hide() end

        local w = math.max(self:GetWidth(), 200)
        local h = n * rowH + 4
        popup:SetWidth(w)
        popup:SetHeight(h)
        popup:ClearAllPoints()
        -- Flip above the button if there isn't room below.
        local btnBottom = self:GetBottom()
        if btnBottom and (btnBottom - h) < 40 then
            popup:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 2)
        else
            popup:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        end
        UI._ddCatcher:Show()
        popup:Show()
        popup:Raise()
    end)

    return dd
end

-- WoW addon loader ignores file-level `return`; always export onto RaijinLab.
RaijinLab = RaijinLab or {}
RaijinLab.UI = UI

return UI
