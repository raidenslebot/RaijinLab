-- Rotation priority editor: slots, drag reorder, condition add/edit.
-- Uses shared UI skin; condition dialogs are movable + accept spell drops.

local Editor = {}

local function UI()
    -- Prefer shared skin; fall back to Menu's resolver if present
    if RaijinLab and RaijinLab.UI and RaijinLab.UI.paint then
        return RaijinLab.UI
    end
    if RaijinLab and RaijinLab.Menu and type(RaijinLab.Menu) == "table" then
        -- touch skin via a paint-less path: ensure UI.lua export
    end
    return RaijinLab and RaijinLab.UI or nil
end

local function paint(f, r, g, b, a)
    local u = UI()
    if u then
        u.paint(f, { r, g, b, a or 1 })
        return
    end
    if not f._bg then
        f._bg = f:CreateTexture(nil, "BACKGROUND")
        f._bg:SetAllPoints()
    end
    f._bg:SetTexture(1, 1, 1, 1)
    f._bg:SetVertexColor(r, g, b, a or 1)
end

-- Recolor an existing UI.border on a POOLED frame. UI.border() caches its edge
-- textures in _rl_border and no-ops on later calls, so a reused frame whose
-- selection state flipped (accent gold vs tan line) needs its border tint
-- pushed directly. Safe no-op when the frame has no border yet or c is nil.
local function setBorderColor(frame, c)
    local bd = frame and frame._rl_border
    if not bd or not c then return end
    for _, tex in pairs(bd) do
        tex:SetTexture(1, 1, 1, 1)
        tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    end
end

-- ============================================================
-- Condition-editor presentation helpers.
-- Friendly labels for enum values (dropdowns + preview) and a per-condition
-- plain-English summary. Kept in the editor (presentation) so the pure
-- Conditions module stays logic-only. All ASCII - 3.3.5 fonts render the
-- unicode math glyphs (>=, in-range arrows) as "?".
-- ============================================================
local VALUE_LABELS = {
    op = {
        [">="] = "greater than or equal to",
        ["<="] = "less than or equal to",
        [">"]  = "greater than",
        ["<"]  = "less than",
        ["="]  = "equals",
        ["in_range"] = "in range (min to max)",
        ["ready"] = "ready (off cooldown)",
        ["on_cd"] = "on cooldown",
    },
    mode = { pct = "percent  (0-100%)", units = "raw units  (0, 1, 2 ...)" },
    state = { present = "present  (has it)", missing = "missing  (lacks it)" },
    unit = { player = "Player (self)", target = "Target" },
    kind = { buff = "Buff", debuff = "Debuff" },
    auto_mode = {
        melee = "Melee (Attack)",
        ranged = "Ranged (Auto Shot / Wand)",
        any = "Any auto-repeat",
    },
    power_type = {
        primary = "Primary (current pool)",
        mana = "Mana", rage = "Rage", energy = "Energy", focus = "Focus",
        runic = "Runic Power", runes = "Runes",
        combo_points = "Combo Points", felfury = "FelFury",
    },
}
VALUE_LABELS.ptype = VALUE_LABELS.power_type

local function titlecase(s)
    s = tostring(s or "")
    s = s:gsub("_", " ")
    return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- Friendly display for an enum value given its param key.
local function prettyValue(key, value)
    local tbl = VALUE_LABELS[key]
    if tbl and value ~= nil and tbl[value] then return tbl[value] end
    -- Cross-table fallback: some params share a key but a different value
    -- space. auto_repeat's param key is "mode" (collides with power's
    -- pct/units "mode"), yet its values are melee/ranged/any which live under
    -- auto_mode. Look there so the dropdown shows the rich labels too.
    if key == "mode" and value ~= nil and VALUE_LABELS.auto_mode[value] then
        return VALUE_LABELS.auto_mode[value]
    end
    return titlecase(value)
end

-- Per-condition one-line summary of what the condition tests. `a` is cond.args.
local COND_SUMMARY = {
    power = function(a)
        local pt = prettyValue("power_type", a.power_type or "primary")
        local m = tostring(a.mode or "pct")
        local suffix = (m == "units" or m == "amount" or m == "raw") and "" or "%"
        local op = tostring(a.op or ">=")
        if op == "in_range" then
            return string.format("%s between %s and %s%s", pt, tostring(a.value or 0), tostring(a.value_max or 0), suffix)
        end
        return string.format("%s %s %s%s", pt, prettyValue("op", op), tostring(a.value or 0), suffix)
    end,
    health_pct = function(a)
        local op = tostring(a.op or "<=")
        if op == "in_range" then return string.format("your health is %s to %s%%", tostring(a.value or 0), tostring(a.value_max or 0)) end
        return string.format("your health is %s %s%%", prettyValue("op", op), tostring(a.value or 0))
    end,
    target_health_pct = function(a)
        local op = tostring(a.op or "<=")
        if op == "in_range" then return string.format("target health is %s to %s%%", tostring(a.value or 0), tostring(a.value_max or 0)) end
        return string.format("target health is %s %s%%", prettyValue("op", op), tostring(a.value or 0))
    end,
    target_exists = function(a)
        local st = string.lower(tostring(a.state or "has_target"))
        if st == "no_target" or st == "none" or st == "missing" or st == "no" then
            return "has no target"
        end
        if st == "any" or st == "both" or st == "either" then
            return "target existence (any)"
        end
        return "has a target"
    end,
    target_hostility = function(a)
        local parts = {}
        local function on(v) return v == true or v == 1 or v == "true" end
        local h, n, f = a.hostile, a.neutral, a.friendly
        if h == nil and n == nil and f == nil then h = true end
        if on(h) then parts[#parts + 1] = "hostile" end
        if on(n) then parts[#parts + 1] = "neutral" end
        if on(f) then parts[#parts + 1] = "friendly" end
        if #parts == 0 then return "target hostility (none selected)" end
        if #parts == 3 then return "target is hostile, neutral, or friendly" end
        if #parts == 1 then return "target is " .. parts[1] end
        return "target is " .. table.concat(parts, " or ")
    end,
    target_distance = function(a)
        return string.format("target distance is %s %s yd", prettyValue("op", a.op or "<="), tostring(a.range or 5))
    end,
    target_ttd = function(a)
        local op = tostring(a.op or "<=")
        if op == "in_range" then return string.format("target dies in %s to %ss", tostring(a.seconds or 5), tostring(a.value_max or 10)) end
        return string.format("target dies in %s %ss", prettyValue("op", op), tostring(a.seconds or 5))
    end,
    enemies_in_range = function(a)
        return string.format("enemies within %s yd is %s %s", tostring(a.range or 8), prettyValue("op", a.op or ">="), tostring(a.count or 3))
    end,
    corpse = function(a)
        local st = tostring(a.state or "available")
        if st == "not_consumed" or st == "fresh" then st = "available" end
        if st == "both" then st = "any" end
        if st == "available" then st = "available (not ability-consumed)" end
        if st == "consumed" then st = "ability-consumed" end
        return string.format("%s corpse(s) within %s yd is %s %s",
            st, tostring(a.range or 30), prettyValue("op", a.op or ">="), tostring(a.count or 1))
    end,
    cooldown = function(a)
        local op = tostring(a.op or "ready")
        local who = (tonumber(a.spell_id) or 0) == 0 and "this spell" or ("spell #" .. tostring(a.spell_id))
        if op == "ready" then return who .. " is off cooldown" end
        if op == "on_cd" then return who .. " is on cooldown" end
        return string.format("%s cooldown remaining is %s %ss", who, prettyValue("op", op), tostring(a.seconds or 1))
    end,
    aura_search = function(a)
        local kind = tostring(a.kind or "debuff")
        local state = tostring(a.state or "missing")
        local id_or_name = (a.name and a.name ~= "") and a.name
            or ((tonumber(a.spell_id) or 0) > 0 and ("#" .. tostring(a.spell_id)) or "aura")
        local verb = (state == "missing") and "lacking" or "having"
        local s = string.format("search %s %s %s within %syd",
            kind, verb, id_or_name, tostring(a.range or 40))
        local acq = a.acquire_target == true or a.acquire_target == 1 or a.acquire_target == "true"
            or a.retarget == true or a.retarget == 1 or a.retarget == "true"
        if acq then
            s = s .. " (acquire"
            if a.reset_after == true or a.reset_after == 1 or a.reset_after == "true" then
                s = s .. "+reset"
            end
            s = s .. ")"
        else
            s = s .. " (cast by GUID)"
        end
        return s
    end,
    auto_face = function(a)
        return "turn to face cast unit before casting (does not change target)"
    end,
    facing_target = function(a)
        return "already facing current target (no turn)"
    end,
    aura = function(a)
        local who = (tostring(a.unit) == "target") and "target" or "you"
        local kind = tostring(a.kind or "buff")
        local id_or_name = (a.name and a.name ~= "") and a.name
            or ((tonumber(a.spell_id) or 0) > 0 and ("#" .. tostring(a.spell_id)) or "aura")
        local verb = (tostring(a.state) == "missing") and "lacks" or "has"
        local s = string.format("%s %s %s %s", who, verb, kind, id_or_name)
        if tostring(a.state) ~= "missing" then
            local mn = tonumber(a.min_stacks) or 1
            local mx = tonumber(a.max_stacks) or 0
            if mn > 1 or mx > 0 then
                if mx > 0 then s = s .. string.format("  stacks %d-%d", mn, mx)
                else s = s .. "  x" .. tostring(mn) end
            end
            local op = string.lower(tostring(a.remaining_op or "any"))
            local rv = tonumber(a.remaining)
            if (op == "any" or op == "") and (tonumber(a.min_remaining) or 0) > 0 then
                op, rv = ">=", tonumber(a.min_remaining)
            end
            if op ~= "any" and op ~= "" then
                if op == "in_range" then
                    s = s .. string.format("  rem %s-%ss",
                        tostring(rv or 0), tostring(a.remaining_max or 0))
                else
                    s = s .. string.format("  rem %s %ss", prettyValue("op", op), tostring(rv or 0))
                end
            end
        end
        return s
    end,
    auto_repeat = function(a)
        return "auto-repeat: " .. prettyValue("auto_mode", a.mode or "melee")
    end,
    is_casting = function(a)
        local ic = a.include_channel
        if ic == false or ic == 0 or ic == "false" then return "you are casting (not channels)" end
        return "you are casting or channeling"
    end,
    player_state = function(a)
        local st = string.lower(tostring(a.state or "free"))
        if st == "free" then return "player is free (not in loot/gossip/quest/trade/AH/craft)" end
        if st == "busy" or st == "any_interaction" or st == "any_busy" then
            return "player is in a user-action UI (busy)"
        end
        return "player state is " .. st
    end,
    -- Spell-scoped conditions: 0 means "this slot's own spell".
    spell_known = function(a)
        local id = tonumber(a.spell_id) or 0
        return (id == 0 and "this slot's spell" or ("spell #" .. tostring(id))) .. " is known"
    end,
    spell_usable = function(a)
        local id = tonumber(a.spell_id) or 0
        return (id == 0 and "this slot's spell" or ("spell #" .. tostring(id))) .. " is usable"
    end,
    spell_in_range = function(a)
        local id = tonumber(a.spell_id) or 0
        return (id == 0 and "this slot's spell" or ("spell #" .. tostring(id))) .. " is in range"
    end,
    form_equals = function(a)
        return "stance/form is " .. tostring(a.form or 0)
    end,
    target_protected = function(a)
        local id = tonumber(a.spell_id) or 0
        local who = id == 0 and "this slot's spell" or ("spell #" .. tostring(id))
        return "target is protected from " .. who
    end,
    target_can_take_damage = function(a)
        local id = tonumber(a.spell_id) or 0
        local who = id == 0 and "this slot's spell" or ("spell #" .. tostring(id))
        return "target can take damage from " .. who
    end,
    target_casting = function(a)
        local kind = tostring(a.kind or "any")
        local verb = kind == "cast" and "casting" or kind == "channel" and "channeling" or "casting or channeling"
        local s = "target is " .. verb
        if a.interruptible_only == true then s = s .. " (interruptible)" end
        if (tonumber(a.min_remaining) or 0) > 0 then s = s .. " with " .. tostring(a.min_remaining) .. "s+ left" end
        return s
    end,
    target_classification = function(a)
        return "target is " .. tostring(a.value or "elite")
    end,
    group_size = function(a)
        return string.format("group size is %s %s", prettyValue("op", a.op or ">="), tostring(a.count or 2))
    end,
    threat_situation = function(a)
        return string.format("threat is %s %s", prettyValue("op", a.op or ">="), tostring(a.level or 3))
    end,
    item_ready = function(a)
        local slot = tonumber(a.slot) or 0
        if slot > 0 then return "equipped item in slot " .. tostring(slot) .. " is ready" end
        local id = tonumber(a.item_id) or 0
        return (id > 0 and ("item #" .. tostring(id)) or "item") .. " is off cooldown"
    end,
}

local function summarizeCondition(cond, def)
    local base
    local f = COND_SUMMARY[cond.id]
    if f then
        local ok, s = pcall(f, cond.args or {})
        base = (ok and s) or (def.name or cond.id)
    else
        base = def.name or cond.id
    end
    local a = cond.args
    if a and (a.invert == true or a.invert == 1 or a.invert == "true") then
        base = "NOT ( " .. base .. " )"
    end
    return base
end

function Editor:Attach(parent)
    self.parent = parent
    local U = UI()
    if self.root then
        self.root:SetParent(parent)
        self.root:SetAllPoints()
        self.root:Show()
        self:Refresh()
        return
    end

    local root = CreateFrame("Frame", "RaijinLabRotationEditor", parent)
    root:SetAllPoints()
    self.root = root

    local header = U and U.card(root) or CreateFrame("Frame", nil, root)
    header:SetPoint("TOPLEFT", 10, -10)
    header:SetPoint("TOPRIGHT", -10, -10)
    header:SetHeight(44)
    if not U then paint(header, 0.08, 0.1, 0.14, 1) end

    local title = (U and U.label(header, "Priority Rotation", "GameFontNormalLarge"))
        or header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 14, 4)
    title:SetText("|cff59c7eaPriority Rotation|r")
    local sub = (U and U.dim(header, "Top slot = highest priority  -  drag slots to reorder", "GameFontDisableSmall"))
        or header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("LEFT", 14, -12)
    if not U then sub:SetText("Top slot = highest priority - drag slots to reorder") end

    -- Config bar (per-character rotations). Sits under the title in a compact
    -- row: < [ConfigName]  >  [New] [Rename] [Delete]. Character context comes
    -- from RaijinLab:CharacterKey - displayed to the right so the user knows
    -- what character these rotations belong to.
    local configRow = CreateFrame("Frame", nil, header)
    configRow:SetPoint("TOP", header, "TOP", 0, -2)
    configRow:SetPoint("LEFT", header, "LEFT", 180, 0)
    configRow:SetHeight(28); configRow:SetWidth(520)

    local prevBtn = (U and U.button(configRow, "<", 22, 22, function() self:CycleConfig(-1) end))
        or CreateFrame("Button", nil, configRow)
    prevBtn:SetPoint("LEFT", 0, 6)

    local nameLbl = (U and U.label(configRow, "", "GameFontNormalSmall"))
        or configRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl:SetPoint("LEFT", prevBtn, "RIGHT", 6, 0)
    nameLbl:SetWidth(140)
    nameLbl:SetJustifyH("CENTER")
    nameLbl:SetText("Default")

    local nextBtn = (U and U.button(configRow, ">", 22, 22, function() self:CycleConfig(1) end))
        or CreateFrame("Button", nil, configRow)
    nextBtn:SetPoint("LEFT", nameLbl, "RIGHT", 6, 6)

    local newBtn = (U and U.button(configRow, "New", 44, 22, function() self:PromptNewConfig() end))
        or CreateFrame("Button", nil, configRow)
    newBtn:SetPoint("LEFT", nextBtn, "RIGHT", 12, 0)

    local renBtn = (U and U.button(configRow, "Rename", 64, 22, function() self:PromptRenameConfig() end))
        or CreateFrame("Button", nil, configRow)
    renBtn:SetPoint("LEFT", newBtn, "RIGHT", 6, 0)

    local copyBtn = (U and U.button(configRow, "Copy", 50, 22, function() self:PromptCopyConfig() end))
        or CreateFrame("Button", nil, configRow)
    copyBtn:SetPoint("LEFT", renBtn, "RIGHT", 6, 0)

    local delBtn = (U and U.button(configRow, "Delete", 60, 22, function() self:PromptDeleteConfig() end))
        or CreateFrame("Button", nil, configRow)
    delBtn:SetPoint("LEFT", copyBtn, "RIGHT", 6, 0)

    self.configBar = { row = configRow, name = nameLbl, prev = prevBtn, next = nextBtn,
                       newBtn = newBtn, renBtn = renBtn, copyBtn = copyBtn, delBtn = delBtn }

    local function toggleRotation()
        RaijinLabDB = RaijinLabDB or {}
        local Ex = RaijinLab.RotationExecutor
        if not Ex then
            print("|cff7ec8e3RaijinLab|r RotationExecutor not loaded")
            return
        end
        -- Use executor state (frame), not only SavedVariables - avoids stuck "enabled" with no ticks
        local running = Ex._frame ~= nil and RaijinLabDB.rotation_enabled
        if running then
            Ex.stop()
        else
            Ex.start()
            if Ex.status then
                print("|cff7ec8e3RaijinLab|r " .. Ex.status())
            end
        end
        -- Single source of truth (see SyncEnableButton below).
        if self.SyncEnableButton then self:SyncEnableButton() end
    end
    local enableBtn = (U and U.button(header, "Start", 90, 28, toggleRotation)) or CreateFrame("Button", nil, header)
    if not U then
        enableBtn:SetWidth(90)
        enableBtn:SetHeight(28)
        paint(enableBtn, 0.16, 0.28, 0.18, 1)
        local efs = enableBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        efs:SetPoint("CENTER")
        efs:SetText("Start")
        enableBtn:SetScript("OnClick", toggleRotation)
        enableBtn.SetLabel = function(_, s) efs:SetText(s) end
    end
    enableBtn:SetPoint("RIGHT", -12, 0)
    self.enableBtn = enableBtn

    -- Single source of truth for the button's visible state. The label was
    -- previously updated only inside the click handler, so any external state
    -- change (/raijin rotation start|stop, executor auto-stop after arm
    -- failure, DB restore on /reload) left the button lying. Route every
    -- state read + label write through this helper and call it from every
    -- refresh path - plus poll ~1 Hz for external state that never triggers
    -- an addon refresh (chat commands from another window).
    function Editor:SyncEnableButton()
        local btn = self.enableBtn
        if not btn or not btn.SetLabel then return end
        local Ex = RaijinLab and RaijinLab.RotationExecutor
        local running = Ex and Ex._frame ~= nil and RaijinLabDB and RaijinLabDB.rotation_enabled
        btn:SetLabel(running and "Stop" or "Start")
    end
    self:SyncEnableButton()

    -- Poll for external state changes. Attached to enableBtn (destroyed with
    -- the header frame on Editor rebuild) so we don't leak an orphan ticker.
    local acc = 0
    enableBtn:SetScript("OnUpdate", function(_, dt)
        acc = acc + (dt or 0)
        if acc >= 1.0 then
            acc = 0
            Editor:SyncEnableButton()
        end
    end)

    -- Left: slots card
    local list = (U and U.card(root)) or CreateFrame("Frame", nil, root)
    list:SetPoint("TOPLEFT", 10, -64)
    list:SetWidth(300)
    list:SetPoint("BOTTOMLEFT", 10, 12)
    if not U then paint(list, 0.08, 0.09, 0.12, 1) end
    self.list = list

    local listTitle = (U and U.label(list, "Slots", "GameFontNormal")) or list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    listTitle:SetPoint("TOPLEFT", 12, -10)
    if not U then listTitle:SetText("Slots (drag to reorder)") end
    local listHint = (U and U.dim(list, "Drag to reorder - drop spell on empty", "GameFontDisableSmall"))
        or list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    listHint:SetPoint("TOPLEFT", 12, -26)

    self.slotButtons = {}
    self.selectedIndex = 1

    -- Right: detail card
    local detail = (U and U.card(root)) or CreateFrame("Frame", nil, root)
    detail:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, 0)
    detail:SetPoint("BOTTOMRIGHT", -10, 12)
    if not U then paint(detail, 0.08, 0.09, 0.12, 1) end
    self.detail = detail

    self.detailTitle = (U and U.label(detail, "Select a slot", "GameFontNormalLarge"))
        or detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.detailTitle:SetPoint("TOPLEFT", 14, -12)

    self.detailBody = (U and U.dim(detail, "", "GameFontHighlightSmall"))
        or detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.detailBody:SetPoint("TOPLEFT", 14, -40)
    self.detailBody:SetPoint("RIGHT", -14, 0)
    self.detailBody:SetJustifyH("LEFT")
    self.detailBody:SetJustifyV("TOP")

    -- Per-slot casting attributes. off_gcd: the ability ignores the global
    -- cooldown, so the rotation may fire it DURING another spell's GCD.
    -- while_casting: it can be used while you're already casting/channeling
    -- (instants auto-qualify; this forces cast-time abilities through too).
    -- These make priority honor real spell mechanics instead of blanket-blocking.
    if U and U.checkbox then
        self.offGcdCheck = U.checkbox(detail, "RaijinLabSlotOffGcd",
            "Off-GCD (usable during another spell's cooldown)", false, function(on)
                local r = self:GetRotation()
                local slot = r and r.slots[self.selectedIndex]
                if slot then slot.off_gcd = on and true or false; self:Save(r) end
            end)
        self.offGcdCheck:SetPoint("TOPLEFT", 12, -92)
        self.whileCastCheck = U.checkbox(detail, "RaijinLabSlotWhileCast",
            "Castable while casting / channeling", false, function(on)
                local r = self:GetRotation()
                local slot = r and r.slots[self.selectedIndex]
                if slot then slot.while_casting = on and true or false; self:Save(r) end
            end)
        self.whileCastCheck:SetPoint("TOPLEFT", 12, -114)
    end

    -- Conditions area: give it its own inset backdrop so the section is
    -- visibly framed even when empty. Previously condHost was a bare
    -- CreateFrame (no paint), which made the whole conditions region read as
    -- an invisible submenu - user reported it consistently.
    self.condHost = CreateFrame("Frame", nil, detail)
    self.condHost:SetPoint("TOPLEFT", 10, -144)
    self.condHost:SetPoint("BOTTOMRIGHT", -10, 72)
    if U then
        U.paint(self.condHost, U.C.bg1)
        U.border(self.condHost, U.C.line)
    else
        paint(self.condHost, 0.06, 0.05, 0.03, 0.65)
    end
    self.condButtons = {}

    local addCond = (U and U.button(detail, "Add Condition...", 140, 28, function() self:OpenAddCondition() end))
        or CreateFrame("Button", nil, detail)
    addCond:SetPoint("BOTTOMLEFT", 12, 32)
    if not U then
        addCond:SetWidth(140)
        addCond:SetHeight(28)
        paint(addCond, 0.16, 0.28, 0.22, 1)
        local acfs = addCond:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        acfs:SetPoint("CENTER")
        acfs:SetText("Add Condition...")
        addCond:SetScript("OnClick", function() self:OpenAddCondition() end)
    end

    local setSpell = (U and U.button(detail, "Set Spell", 120, 28, function() self:SetSpellFromCursor() end))
        or CreateFrame("Button", nil, detail)
    setSpell:SetPoint("LEFT", addCond, "RIGHT", 8, 0)
    if not U then
        setSpell:SetWidth(120)
        setSpell:SetHeight(28)
        paint(setSpell, 0.16, 0.22, 0.32, 1)
        local ssfs = setSpell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ssfs:SetPoint("CENTER")
        ssfs:SetText("Set Spell")
        setSpell:SetScript("OnClick", function() self:SetSpellFromCursor() end)
    end

    -- Remove: deletes ONE selected slot from the priority list.
    --         Greyed out when no populated slot is selected.
    -- Clear:  wipes the ENTIRE rotation (every slot -> empty).
    -- Two clearly distinct actions.
    local remSlot = (U and U.button(detail, "Remove", 80, 28, function() self:RemoveSelected() end))
        or CreateFrame("Button", nil, detail)
    remSlot:SetPoint("BOTTOMRIGHT", -12, 32)
    if not U then
        remSlot:SetWidth(80); remSlot:SetHeight(28)
        paint(remSlot, 0.35, 0.12, 0.12, 1)
        local rsfs = remSlot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rsfs:SetPoint("CENTER"); rsfs:SetText("Remove")
        remSlot:SetScript("OnClick", function() self:RemoveSelected() end)
    end
    self.removeBtn = remSlot

    local clrRot = (U and U.button(detail, "Clear", 80, 28, function() self:ClearRotation() end))
        or CreateFrame("Button", nil, detail)
    clrRot:SetPoint("RIGHT", remSlot, "LEFT", -6, 0)
    if not U then
        clrRot:SetWidth(80); clrRot:SetHeight(28)
        paint(clrRot, 0.28, 0.20, 0.10, 1)
        local dsfs = clrRot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dsfs:SetPoint("CENTER"); dsfs:SetText("Clear")
        clrRot:SetScript("OnClick", function() self:ClearRotation() end)
    end
    self.clearBtn = clrRot

    local help = (U and U.dim(detail, "Drag a spell from your spellbook onto a slot or the Set Spell button", "GameFontDisableSmall"))
        or detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("BOTTOMLEFT", 12, 10)

    -- Spell drop on detail panel too
    if U then
        U.enableSpellDrop(detail, function(spellId, name, ctype, petIndex)
            self:ApplySpellToSelected(spellId, name, ctype or "spell", petIndex)
        end)
    end

    self:Refresh()
end

function Editor:GetRotation()
    local Ex = RaijinLab.RotationExecutor
    local Engine = RaijinLab.RotationEngine
    if not Ex or not Engine then return Engine and Engine.new_rotation() or nil end
    return select(1, Ex.get_active_rotation())
end

function Editor:Save(rotation)
    if RaijinLab.RotationExecutor then
        -- force=true: user explicitly saved; empty rotation is allowed (clear all).
        RaijinLab.RotationExecutor.save_rotation(rotation, nil, { force = true })
    end
end

-- Build one reusable slot button. Scripts are attached ONCE and read the live
-- `b.index` field (updated each Refresh), so the pooled frame keeps working as
-- its meaning changes. Fontstrings are cached on the frame for text updates.
function Editor:_makeSlotButton()
    local b = CreateFrame("Button", nil, self.list)
    b:SetWidth(276)
    b:SetHeight(34)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 12, 0)
    b._fs = fs
    local idFs = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    idFs:SetPoint("RIGHT", -10, 0)
    b._idFs = idFs
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)
    b:SetScript("OnClick", function(btn)
        self.selectedIndex = btn.index
        self:Refresh()
    end)
    b:SetScript("OnDragStart", function(btn)
        self.dragFrom = btn.index
        btn:StartMoving()
    end)
    b:SetScript("OnDragStop", function(btn)
        btn:StopMovingOrSizing()
        -- Re-fetch: the rotation is stale after any intervening Refresh /
        -- SavedVariables reload. Mutating a stale table silently drops changes
        -- on Save.
        local r = self:GetRotation()
        if not r then self.dragFrom = nil; self:Refresh(); return end
        local Engine = RaijinLab.RotationEngine
        local scale = UIParent:GetEffectiveScale()
        local cy = select(2, GetCursorPosition()) / scale
        local ly = self.list:GetTop()
        local rel = ly - cy
        local idx = math.floor((rel - 44) / 38) + 1
        if idx < 1 then idx = 1 end
        if idx > #r.slots then idx = #r.slots end
        if self.dragFrom and self.dragFrom ~= idx then
            Engine.move_slot(r, self.dragFrom, idx)
            self.selectedIndex = idx
            self:Save(r)
        end
        self.dragFrom = nil
        self:Refresh()
    end)
    b:SetScript("OnReceiveDrag", function(btn)
        self.selectedIndex = btn.index
        self:SetSpellFromCursor()
    end)
    local U = UI()
    if U then
        U.enableSpellDrop(b, function(spellId, name, ctype, petIndex)
            self.selectedIndex = b.index
            self:ApplySpellToSelected(spellId, name, ctype or "spell", petIndex)
        end)
    end
    return b
end

function Editor:Refresh()
    if not self.list then return end
    if self.SyncEnableButton then self:SyncEnableButton() end
    if self.SyncEditButtons then self:SyncEditButtons() end
    if self.SyncConfigBar then self:SyncConfigBar() end
    local U = UI()
    local rotation = self:GetRotation()
    if not rotation then return end
    local Engine = RaijinLab.RotationEngine
    Engine.ensure_trailing_empty(rotation)

    -- Pool: reuse slot buttons by index, grow on demand, hide the surplus.
    -- WoW frames can't be destroyed or GC'd, so create-then-hide leaked one
    -- button (plus its fontstrings) on every Refresh - and Refresh fires on
    -- every click / drag / remove.
    self.slotButtons = self.slotButtons or {}
    local y = -44
    for i, slot in ipairs(rotation.slots) do
        local b = self.slotButtons[i]
        if not b then
            b = self:_makeSlotButton()
            self.slotButtons[i] = b
        end
        b:ClearAllPoints()  -- a prior drag (StartMoving) left stale anchors
        b:SetPoint("TOPLEFT", 12, y)
        y = y - 38
        local selected = (i == self.selectedIndex)
        if U then
            U.paint(b, selected and U.C.tabOn or U.C.bg2)
            U.border(b, selected and U.C.accent or U.C.line)
            setBorderColor(b, selected and U.C.accent or U.C.line)  -- recolor reused
            if U.bevel then U.bevel(b) end
            if U.sheen then U.sheen(b, selected and 0.08 or 0.04) end
        else
            paint(b, selected and 0.18 or 0.12, selected and 0.28 or 0.14, selected and 0.36 or 0.18, 1)
        end
        b.index = i
        if slot.spell_id == 0 then
            b._fs:SetText(string.format("%d   empty slot - drop a spell", i))
            b._fs:SetTextColor(0.5, 0.55, 0.6)
        else
            b._fs:SetText(string.format("%d   %s   -  %d conditions", i, slot.name or "?", #(slot.conditions or {})))
            b._fs:SetTextColor(0.92, 0.95, 0.97)
        end
        if slot.spell_id ~= 0 then
            b._idFs:SetText("id " .. tostring(slot.spell_id))
        else
            b._idFs:SetText("")
        end
        b:Show()
    end
    for j = #rotation.slots + 1, #self.slotButtons do
        self.slotButtons[j]:Hide()
    end

    self:RefreshDetail(rotation)
end

-- Build one reusable condition row (drag handle + click-to-edit label + Edit +
-- Remove). Scripts read the live `row._ci` / `row._nice` fields, set fresh each
-- RefreshDetail, so the pooled row stays correct as conditions are added,
-- removed, or reordered. `local U` is captured once (the skin never changes
-- after load), which decides the paint vs fallback branch permanently.
function Editor:_makeCondRow()
    local U = UI()
    local row = CreateFrame("Frame", nil, self.condHost)
    row:SetWidth(400)
    row:SetHeight(32)
    if U then
        U.paint(row, U.C.bg2)
        U.border(row, U.C.line)
        if U.bevel then U.bevel(row) end
    else
        paint(row, 0.14, 0.16, 0.2, 1)
    end

    -- Drag handle (left strip)
    local drag = CreateFrame("Button", nil, row)
    drag:SetWidth(28)
    drag:SetHeight(28)
    drag:SetPoint("LEFT", 2, 0)
    if U then U.paint(drag, U.C.bg3) else paint(drag, 0.18, 0.2, 0.24, 1) end
    local dfs = drag:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dfs:SetPoint("CENTER")
    dfs:SetText("=") -- ASCII grip (unicode icons often render as ?)
    dfs:SetTextColor(0.6, 0.7, 0.8)
    drag:RegisterForDrag("LeftButton")
    drag:SetMovable(true)
    drag:SetScript("OnDragStart", function(btn)
        self.condDragFrom = btn.ci
        btn:StartMoving()
    end)
    drag:SetScript("OnDragStop", function(btn)
        btn:StopMovingOrSizing()
        local Engine = RaijinLab.RotationEngine
        -- Re-fetch: closure over the outer rotation becomes stale after any
        -- Refresh cycle. See slot OnDragStop above.
        local r = self:GetRotation()
        if not r or not r.slots[self.selectedIndex] then
            self.condDragFrom = nil; self:Refresh(); return
        end
        local liveList = r.slots[self.selectedIndex].conditions or {}
        local scale = UIParent:GetEffectiveScale()
        local cy = select(2, GetCursorPosition()) / scale
        local top = self.condHost:GetTop()
        if not top then self.condDragFrom = nil; self:Refresh(); return end
        local rel = top - cy
        local idx = math.floor(rel / 36) + 1
        if idx < 1 then idx = 1 end
        if idx > #liveList then idx = #liveList end
        if self.condDragFrom and self.condDragFrom ~= idx then
            Engine.move_condition(r, self.selectedIndex, self.condDragFrom, idx)
            self:Save(r)
        end
        self.condDragFrom = nil
        self:Refresh()
    end)
    row._drag = drag

    -- Main click area -> edit
    local b = CreateFrame("Button", nil, row)
    b:SetPoint("LEFT", 32, 0)
    b:SetPoint("RIGHT", -120, 0)
    b:SetHeight(28)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 4, 0)
    fs:SetPoint("RIGHT", -4, 0)
    fs:SetJustifyH("LEFT")
    b._fs = fs
    b:SetScript("OnClick", function(btn) self:EditCondition(btn.ci) end)
    b:SetScript("OnEnter", function()
        if U then U.paint(row, U.C.btnHi) else paint(row, 0.18, 0.24, 0.32, 1) end
    end)
    b:SetScript("OnLeave", function()
        if U then U.paint(row, U.C.bg2) else paint(row, 0.14, 0.16, 0.2, 1) end
    end)
    row._b = b

    -- Edit button
    local editBtn = (U and U.button(row, "Edit", 50, 24, function()
        self:EditCondition(row._ci)
    end)) or CreateFrame("Button", nil, row)
    editBtn:SetPoint("RIGHT", -58, 0)
    if not U then
        editBtn:SetWidth(50); editBtn:SetHeight(24)
        paint(editBtn, 0.16, 0.22, 0.32, 1)
        local efs = editBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        efs:SetPoint("CENTER"); efs:SetText("Edit")
        editBtn:SetScript("OnClick", function() self:EditCondition(row._ci) end)
    end
    row._edit = editBtn

    -- Remove button (explicit - do not rely on right-click alone)
    local remBtn = (U and U.button(row, "Remove", 56, 24, function()
        local Engine = RaijinLab.RotationEngine
        -- Re-fetch: the outer rotation is stale after Refresh.
        local r = self:GetRotation()
        if not r then self:Refresh(); return end
        Engine.remove_condition(r, self.selectedIndex, row._ci)
        self:Save(r)
        self:Refresh()
        print("|cff7ec8e3RaijinLab|r removed condition " .. tostring(row._nice))
    end)) or CreateFrame("Button", nil, row)
    remBtn:SetPoint("RIGHT", -2, 0)
    if not U then
        remBtn:SetWidth(56); remBtn:SetHeight(24)
        paint(remBtn, 0.35, 0.12, 0.12, 1)
        local rfs = remBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rfs:SetPoint("CENTER"); rfs:SetText("Remove")
        remBtn:SetScript("OnClick", function()
            local Engine = RaijinLab.RotationEngine
            -- Re-fetch: the outer rotation is stale after Refresh.
            local r = self:GetRotation()
            if not r then self:Refresh(); return end
            Engine.remove_condition(r, self.selectedIndex, row._ci)
            self:Save(r)
            self:Refresh()
        end)
    end
    row._rem = remBtn

    return row
end

function Editor:RefreshDetail(rotation)
    rotation = rotation or self:GetRotation()
    if not rotation then return end
    local U = UI()
    local slot = rotation.slots[self.selectedIndex]
    if not slot then
        self.detailTitle:SetText("No slot")
        self.detailBody:SetText("")
        -- Hide any pooled rows so a stale list doesn't linger under "No slot".
        if self.condButtons then
            for _, row in ipairs(self.condButtons) do row:Hide() end
        end
        return
    end
    self.detailTitle:SetText(string.format("Slot %d  -  %s", self.selectedIndex, slot.name or "Empty"))
    local rankInfo = ""
    local RR = RaijinLab and RaijinLab.RankResolver
    if RR and RR.describe and tonumber(slot.spell_id) and tonumber(slot.spell_id) ~= 0 then
        local rid, rt, changed, status = RR.describe(slot.spell_id)
        if status == "unlisted" then rankInfo = "      Rank  (as saved)"
        elseif changed then rankInfo = "      Rank  -> " .. tostring(rt or ("id " .. rid)) .. " (id " .. tostring(rid) .. ")"
        else rankInfo = "      Rank  max" end
    end
    self.detailBody:SetText(string.format(
        "Type  %s      Spell ID  %s      Enabled  %s%s",
        tostring(slot.action_type),
        tostring(slot.spell_id),
        tostring(slot.enabled ~= false),
        rankInfo
    ))
    -- Sync the per-slot attribute toggles to this slot.
    if self.offGcdCheck then self.offGcdCheck:SetChecked(slot.off_gcd and true or false) end
    if self.whileCastCheck then self.whileCastCheck:SetChecked(slot.while_casting and true or false) end

    -- Pool: reuse condition rows by index (see Refresh for the leak rationale).
    self.condButtons = self.condButtons or {}
    local y = 0
    local condList = slot.conditions or {}
    for ci, cond in ipairs(condList) do
        local row = self.condButtons[ci]
        if not row then
            row = self:_makeCondRow()
            self.condButtons[ci] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        y = y - 36
        if U then
            U.paint(row, U.C.bg2)  -- resets any lingering hover tint on reuse
        else
            paint(row, 0.14, 0.16, 0.2, 1)
        end
        -- The drag handle may have been left off-anchor by a prior StartMoving.
        row._drag:ClearAllPoints()
        row._drag:SetPoint("LEFT", 2, 0)
        row._drag.ci = ci
        row._b.ci = ci
        row._ci = ci

        local args = cond.args or {}
        local argstr = {}
        for k, v in pairs(args) do
            if k ~= "invert" and v ~= "" and v ~= nil and v ~= false then
                argstr[#argstr + 1] = k .. "=" .. tostring(v)
            elseif k == "invert" and (v == true or v == 1) then
                argstr[#argstr + 1] = "NOT"
            end
        end
        table.sort(argstr)
        local def = RaijinLab.Conditions and RaijinLab.Conditions.get(cond.id)
        local nice = def and def.name or cond.id
        row._nice = nice
        row._b._fs:SetText(string.format("%d. %s  %s", ci, nice, table.concat(argstr, " - ")))
        row:Show()
    end
    for j = #condList + 1, #self.condButtons do
        self.condButtons[j]:Hide()
    end
end

function Editor:ApplySpellToSelected(spellId, name, actionType, petIndex)
    local rotation = self:GetRotation()
    local Engine = RaijinLab.RotationEngine
    if not rotation then return end
    -- Pet actions have no spell id (sentinel 0); everything else requires one.
    if actionType ~= "petaction" and not spellId then return end
    local idx = self.selectedIndex or 1
    local isPet = (actionType == "petaction")
    Engine.set_slot_action(rotation, idx, {
        spell_id = spellId or 0,
        name = name or (isPet and "Pet Action" or ("Spell " .. tostring(spellId))),
        action_type = actionType or "spell",
        pet_index = petIndex,
        pet_cmd = isPet and tostring(name or ""):lower() or nil,
    })
    self:Save(rotation)
    self:Refresh()
    print("|cff7ec8e3RaijinLab|r slot " .. idx .. " = " .. tostring(name)
        .. (isPet and " (pet command)" or (" (id " .. tostring(spellId) .. ")")))
end

local function resolve_cursor_spell()
    if not GetCursorInfo then return nil end
    local ctype, a, b = GetCursorInfo()
    if not ctype then return nil end
    if ctype == "spell" then
        local SU = RaijinLab and RaijinLab.SpellUtil
        local spellId, name
        if SU then
            spellId, name = SU.resolve_spellbook_cursor(a, b, GetSpellLink, GetSpellName, GetSpellInfo)
        elseif GetSpellLink then
            local link = GetSpellLink(a, b)
            if type(link) == "string" then
                spellId = tonumber(link:match("[Hh]spell:(%d+)") or link:match("spell:(%d+)"))
            end
            name = GetSpellName and GetSpellName(a, b)
        end
        if spellId then return spellId, name or ("Spell " .. tostring(spellId)), "spell" end
        return nil
    end
    if ctype == "item" then
        return a, (GetItemInfo and GetItemInfo(a)) or ("Item " .. tostring(a)), "item"
    end
    if ctype == "petaction" then
        local pname = (GetPetActionInfo and GetPetActionInfo(a)) or ("Pet Action " .. tostring(a))
        return 0, pname, "petaction", a  -- spellId 0 sentinel; a = pet-bar index
    end
    return nil
end

function Editor:SetSpellFromCursor()
    local spellId, name, actionType, petIndex = resolve_cursor_spell()
    -- spellId is 0 (truthy) for pet actions; only nil means "nothing on cursor".
    if spellId == nil then
        print("|cff7ec8e3RaijinLab|r: pick a spell/pet command (cursor must hold it), then click Set Spell or drop on a slot")
        if ClearCursor then ClearCursor() end
        return
    end
    self:ApplySpellToSelected(spellId, name, actionType, petIndex)
    if ClearCursor then ClearCursor() end
end

function Editor:ClearSelected()
    -- Reset the selected slot's contents to Empty. Keeps the slot in the list.
    local rotation = self:GetRotation()
    local Engine = RaijinLab.RotationEngine
    if not rotation then return end
    Engine.set_slot_action(rotation, self.selectedIndex, { spell_id = 0, name = "Empty", conditions = {} })
    rotation.slots[self.selectedIndex].conditions = {}
    self:Save(rotation)
    self:Refresh()
end

function Editor:RemoveSelected()
    -- Delete the selected slot from the priority list entirely. Selection moves
    -- to the previous slot (or slot 1 if we removed the first). Silently no-op
    -- when nothing populated is selected - the button is greyed in that state,
    -- but a keybind or programmatic call could still reach here.
    local rotation = self:GetRotation()
    local Engine = RaijinLab.RotationEngine
    if not rotation or not rotation.slots then return end
    local idx = self.selectedIndex or 0
    local slot = rotation.slots[idx]
    if not slot then return end
    if Engine.slot_is_empty and Engine.slot_is_empty(slot) then return end
    Engine.remove_slot(rotation, idx)
    Engine.ensure_trailing_empty(rotation)
    self.selectedIndex = math.max(1, math.min(idx, #rotation.slots))
    self:Save(rotation)
    self:Refresh()
end

-- Wipe every slot in the current rotation. Leaves a single trailing empty
-- (ensure_trailing_empty always re-appends one). Different action from Remove
-- (per-slot) and from Clear-slot (which was renamed away; that behavior lives
-- on Remove or by simply dropping a new spell onto an existing slot).
function Editor:ClearRotation()
    local rotation = self:GetRotation()
    local Engine = RaijinLab.RotationEngine
    if not rotation then return end
    rotation.slots = {}
    Engine.ensure_trailing_empty(rotation)
    self.selectedIndex = 1
    self:Save(rotation)
    self:Refresh()
end

-- Config bar sync - reflect current active config name + grey Delete when
-- only one config exists (deleting the last one auto-creates a new Default
-- but that's confusing UX; better to keep the button greyed).
function Editor:SyncConfigBar()
    local bar = self.configBar
    if not bar then return end
    local Ex = RaijinLab.RotationExecutor
    if not Ex or not Ex.list_configs then return end
    local names, active = Ex.list_configs()
    bar.name:SetText(active or "Default")
    local n = #names
    if bar.delBtn then
        if n > 1 then
            if bar.delBtn.Enable then bar.delBtn:Enable() end
        else
            if bar.delBtn.Disable then bar.delBtn:Disable() end
        end
    end
    if bar.prev and bar.next then
        local multi = n > 1
        for _, b in ipairs({ bar.prev, bar.next }) do
            if multi then
                if b.Enable then b:Enable() end
            else
                if b.Disable then b:Disable() end
            end
        end
    end
end

-- Move the active config pointer forward (delta=+1) or backward (delta=-1)
-- through the sorted config list. No-op with only one config.
function Editor:CycleConfig(delta)
    local Ex = RaijinLab.RotationExecutor
    if not Ex or not Ex.list_configs then return end
    local names, active = Ex.list_configs()
    if #names < 2 then return end
    local idx = 1
    for i, n in ipairs(names) do if n == active then idx = i; break end end
    idx = ((idx - 1 + delta) % #names) + 1
    Ex.set_active_config(names[idx])
    self.selectedIndex = 1
    self:Refresh()
end

-- Text-input popup for New / Rename. Uses StaticPopup so it feels native and
-- gets proper focus behavior. Callback receives the entered text; empty input
-- cancels silently.
local function _popup(id, title, defaultText, callback)
    StaticPopupDialogs[id] = {
        text = title,
        button1 = "OK",
        button2 = "Cancel",
        hasEditBox = true,
        maxLetters = 40,
        OnShow = function(self_)
            local eb = self_.editBox or _G[self_:GetName() .. "EditBox"]
            if eb then eb:SetText(defaultText or ""); eb:HighlightText() end
        end,
        OnAccept = function(self_)
            local eb = self_.editBox or _G[self_:GetName() .. "EditBox"]
            local text = eb and eb:GetText() or ""
            text = (text:gsub("^%s+", ""):gsub("%s+$", ""))
            if text ~= "" and callback then callback(text) end
        end,
        EditBoxOnEnterPressed = function(self_)
            local parent = self_:GetParent()
            local text = (self_:GetText():gsub("^%s+", ""):gsub("%s+$", ""))
            if text ~= "" and callback then callback(text) end
            parent:Hide()
        end,
        EditBoxOnEscapePressed = function(self_) self_:GetParent():Hide() end,
        timeout = 0, whileDead = true, hideOnEscape = true, exclusive = true,
    }
    StaticPopup_Show(id)
end

function Editor:PromptNewConfig()
    local Ex = RaijinLab.RotationExecutor
    if not Ex or not Ex.set_active_config then return end
    _popup("RAIJINLAB_CFG_NEW", "New rotation config name:", "", function(name)
        -- create=true is intentional ONLY for New; Cycle must never invent empties.
        Ex.set_active_config(name, { create = true })
        self.selectedIndex = 1
        self:Refresh()
    end)
end

function Editor:PromptRenameConfig()
    local Ex = RaijinLab.RotationExecutor
    if not Ex or not Ex.rename_config then return end
    local _, active = Ex.list_configs()
    _popup("RAIJINLAB_CFG_REN", "Rename config to:", active or "", function(name)
        local ok, why = Ex.rename_config(active, name)
        if not ok then
            print("|cffff5555RaijinLab|r rename failed: " .. tostring(why))
        else
            self:Refresh()
        end
    end)
end

function Editor:PromptDeleteConfig()
    local Ex = RaijinLab.RotationExecutor
    if not Ex or not Ex.delete_config then return end
    local names, active = Ex.list_configs()
    if #names <= 1 then return end
    StaticPopupDialogs["RAIJINLAB_CFG_DEL"] = {
        text = "Delete config '" .. tostring(active) .. "'? This cannot be undone.",
        button1 = "Delete", button2 = "Cancel",
        OnAccept = function()
            Ex.delete_config(active)
            self.selectedIndex = 1
            self:Refresh()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, exclusive = true,
    }
    StaticPopup_Show("RAIJINLAB_CFG_DEL")
end

-- Copy the active config into a new name (full deep copy of slots + conditions).
function Editor:PromptCopyConfig()
    local Ex = RaijinLab.RotationExecutor
    if not Ex or not Ex.copy_config or not Ex.list_configs then return end
    local _, active = Ex.list_configs()
    local def = (active and (active .. " Copy")) or "Copy"
    _popup("RAIJINLAB_CFG_COPY",
        "Copy config '" .. tostring(active) .. "' to new name:",
        def,
        function(name)
            local ok, why = Ex.copy_config(active, name, { switch = true })
            if not ok then
                print("|cffff5555RaijinLab|r copy failed: " .. tostring(why))
            else
                print("|cff7ec8e3RaijinLab|r copied '" .. tostring(active)
                    .. "' -> '" .. tostring(name) .. "' (now active)")
                self.selectedIndex = 1
                self:Refresh()
            end
        end)
end

-- Enable / grey out the per-slot Remove button based on whether the current
-- selection actually points at a populated slot. Called from Refresh + on
-- every selection change.
function Editor:SyncEditButtons()
    local btn = self.removeBtn
    if not btn then return end
    local rotation = self:GetRotation()
    local Engine = RaijinLab.RotationEngine
    local slot = rotation and rotation.slots and rotation.slots[self.selectedIndex or 0]
    local canRemove = slot and Engine and Engine.slot_is_empty and (not Engine.slot_is_empty(slot))
    if canRemove then
        if btn.Enable then btn:Enable() end
    else
        if btn.Disable then btn:Disable() end
    end
end

-- Build the add-condition picker modal ONCE. All chrome (title bar, close,
-- scroll, slider, footer) is persistent; only the catalog rows are pooled and
-- re-laid-out per open. Previously a whole modal + one button per catalog entry
-- leaked on every open (hide-only, never destroyable).
function Editor:_ensureAddFrame(rowH, visibleRows)
    if self.addFrame then return end
    local U = UI()
    -- Nameless frame: no global _G entry keeps it alive after orphaning.
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetWidth(400)
    f:SetHeight(64 + visibleRows * rowH + 40)
    f:SetPoint("CENTER")
    local UIw = RaijinLab and RaijinLab.UI
    if UIw and UIw.RegisterWindow then UIw.RegisterWindow(f)
    else f:SetFrameStrata("DIALOG"); f:SetFrameLevel(200) end
    -- Opaque background. dialogFrame's SetBackdrop parchment does NOT render on
    -- this dynamically-created DIALOG-strata frame (it works on the persistent
    -- main menu, but not here - Ascension quirk), leaving it see-through. The
    -- U.paint helper creates a solid BACKGROUND texture and is PROVEN to render
    -- (the condition rows below use it and are visible). So paint an opaque fill
    -- first (guaranteed visible), then layer the gold rope border on top.
    if U then
        if U.dialogFrame then U.dialogFrame(f) end       -- rope border aesthetic
        U.paint(f, { 0.06, 0.05, 0.03, 1.0 })            -- GUARANTEED opaque interior
        U.border(f, U.C.line)
    else
        paint(f, 0.06, 0.08, 0.1, 1.0)
    end
    f:EnableMouse(true)

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 0, -3)
    titleBar:SetPoint("TOPRIGHT", 0, -3)
    titleBar:SetHeight(36)
    if U then U.paint(titleBar, U.C.bg1) else paint(titleBar, 0.08, 0.1, 0.14, 1) end
    if U then U.makeMovable(f, titleBar) else
        f:SetMovable(true)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
        titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    end

    local t = (U and U.label(titleBar, "", "GameFontNormal"))
        or titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("LEFT", 14, 0)
    self._addTitle = t

    -- ASCII "X" - unicode X often renders as "?" on 3.3.5 fonts
    local close = (U and U.button(titleBar, "X", 28, 24, function() f:Hide() end)) or CreateFrame("Button", nil, titleBar)
    close:SetPoint("RIGHT", -8, 0)
    if not U then
        close:SetWidth(28)
        close:SetHeight(24)
        paint(close, 0.3, 0.1, 0.1, 1)
        local cfs = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cfs:SetPoint("CENTER"); cfs:SetText("X")
        close:SetScript("OnClick", function() f:Hide() end)
    end

    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 12, -48)
    scroll:SetPoint("BOTTOMRIGHT", -28, 32)
    scroll:EnableMouseWheel(true)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(350)
    child:SetHeight(visibleRows * rowH)
    scroll:SetScrollChild(child)

    local slider = CreateFrame("Slider", nil, f)
    slider:SetPoint("TOPRIGHT", -10, -48)
    slider:SetPoint("BOTTOMRIGHT", -10, 32)
    slider:SetWidth(14)
    slider:SetOrientation("VERTICAL")
    slider:SetValueStep(1)
    if U then U.paint(slider, U.C.bg2) else paint(slider, 0.15, 0.15, 0.18, 1) end
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(1, 1, 1, 1)
    thumb:SetVertexColor(0.35, 0.65, 0.8, 1)
    thumb:SetWidth(12)
    thumb:SetHeight(28)
    slider:SetThumbTexture(thumb)
    slider:SetScript("OnValueChanged", function(_, val) scroll:SetVerticalScroll(val) end)
    -- Read the per-open max off the frame (recomputed each open by the pool).
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local maxScroll = scroll._maxScroll or 0
        local cur = slider:GetValue() or 0
        slider:SetValue(math.max(0, math.min(maxScroll, cur - delta * rowH * 3)))
    end)

    local foot = (U and U.dim(f, "Scroll - mouse wheel  -  drag title bar to move", "GameFontDisableSmall"))
        or f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    foot:SetPoint("BOTTOM", 0, 10)
    if not U then foot:SetText("Scroll for all - drag title to move") end

    self.addFrame = f
    self._addScroll = scroll
    self._addChild = child
    self._addSlider = slider
    self._addRows = {}
end

-- Build one reusable catalog button. `btn.def` (set per open) carries the
-- condition definition the click handler acts on.
function Editor:_makeAddRow()
    local U = UI()
    local b = CreateFrame("Button", nil, self._addChild)
    b:SetWidth(340)
    b:SetHeight(24)
    if U then U.paint(b, U.C.bg2); U.border(b, U.C.line) else paint(b, 0.12, 0.14, 0.18, 1) end
    local cat = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cat:SetPoint("LEFT", 8, 0)
    cat:SetWidth(70)
    cat:SetJustifyH("LEFT")
    b._cat = cat
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", 84, 0)
    b._name = fs
    b:SetScript("OnClick", function(btn)
        local Conditions = RaijinLab.Conditions
        local Engine = RaijinLab.RotationEngine
        -- Re-fetch: the rotation captured at picker-open time can go stale if
        -- the user reloads / saves in the meantime.
        local r = self:GetRotation()
        if not r then self.addFrame:Hide(); self:Refresh(); return end
        local cond = { id = btn.def.id, args = Conditions.default_args(btn.def.id) }
        Engine.add_condition(r, self.selectedIndex, cond)
        self:Save(r)
        self.addFrame:Hide()
        self:Refresh()
        -- Immediately open editor for the new condition
        local slot = r.slots[self.selectedIndex]
        if slot and slot.conditions then
            self:EditCondition(#slot.conditions)
        end
    end)
    b:SetScript("OnEnter", function(sb)
        if U then U.paint(sb, U.C.btnHi) else paint(sb, 0.18, 0.24, 0.32, 1) end
    end)
    b:SetScript("OnLeave", function(sb)
        if U then U.paint(sb, U.C.bg2) else paint(sb, 0.12, 0.14, 0.18, 1) end
    end)
    return b
end

function Editor:OpenAddCondition()
    local Conditions = RaijinLab.Conditions
    local rotation = self:GetRotation()
    local U = UI()
    if not Conditions or not rotation then return end

    local catalog = Conditions.list()
    local rowH, visibleRows = 28, 12

    -- Reuse the modal (do NOT SetParent(nil) - see the Menu:Hide rationale;
    -- orphaning an anchored frame can leave a stale pointer WoW derefs on the
    -- next anchor recompute, crashing deep in the render path).
    self:_ensureAddFrame(rowH, visibleRows)
    local f = self.addFrame
    local child = self._addChild
    local scroll = self._addScroll
    local slider = self._addSlider
    local rows = self._addRows

    if U then
        self._addTitle:SetText(string.format("Add Condition  -  %d available", #catalog))
    else
        self._addTitle:SetText(string.format("Add Condition (%d)", #catalog))
    end
    child:SetHeight(math.max(#catalog * rowH, visibleRows * rowH))

    -- Pool: reuse catalog buttons by index, grow on demand, hide the surplus.
    for i, def in ipairs(catalog) do
        local b = rows[i]
        if not b then
            b = self:_makeAddRow()
            rows[i] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 0, -((i - 1) * rowH))
        b._cat:SetText(def.category)
        b._name:SetText(def.name)
        b.def = def
        b:Show()
    end
    for j = #catalog + 1, #rows do rows[j]:Hide() end

    local maxScroll = math.max(0, #catalog * rowH - visibleRows * rowH)
    scroll._maxScroll = maxScroll
    slider:SetMinMaxValues(0, maxScroll > 0 and maxScroll or 1)
    slider:SetValue(0)
    scroll:SetVerticalScroll(0)

    f:Show()
end

-- Build the condition-editor modal ONCE. All chrome (title, live preview line,
-- description band, scroll host, Done button, spell-drop) is persistent. Param
-- rows are pooled per condition def.id (identical structure every time that id
-- is edited); the only per-open state - which condition + its args - lives in
-- self._ec, and every widget closure reads through it. That indirection is what
-- lets a cached row serve any condition instance of its id.
function Editor:_ensureEditChrome()
    if self.editFrame then return end
    local editor = self
    local U = UI()

    local FRAME_W  = 460
    local HEADER_H = 116   -- title + preview + description band
    local FOOTER_H = 54    -- Done button band
    local ROW_H    = 28

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(260)
    f:SetPoint("CENTER")
    local UIw = RaijinLab and RaijinLab.UI
    if UIw and UIw.RegisterWindow then UIw.RegisterWindow(f)
    else f:SetFrameStrata("DIALOG"); f:SetFrameLevel(220) end
    if U then
        if U.dialogFrame then U.dialogFrame(f) end
        U.paint(f, { 0.06, 0.05, 0.03, 1.0 })
        U.border(f, U.C.line)
    else
        paint(f, 0.06, 0.08, 0.1, 1.0)
    end
    f:EnableMouse(true)

    -- Movable title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 0, -3)
    titleBar:SetPoint("TOPRIGHT", 0, -3)
    titleBar:SetHeight(38)
    if U then U.paint(titleBar, U.C.bg1) else paint(titleBar, 0.08, 0.1, 0.14, 1) end
    if U then
        U.makeMovable(f, titleBar)
    else
        f:SetMovable(true)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
        titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    end

    local t = (U and U.label(titleBar, "", "GameFontNormalLarge"))
        or titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("LEFT", 14, 0)
    self._editTitle = t

    local function closeModal()
        if U and U.closeDropdowns then U.closeDropdowns() end
        f:Hide()
        editor:Refresh()
    end
    local close = (U and U.button(titleBar, "X", 28, 24, closeModal)) or CreateFrame("Button", nil, titleBar)
    close:SetPoint("RIGHT", -8, 0)
    if not U then
        close:SetWidth(28); close:SetHeight(24)
        paint(close, 0.3, 0.1, 0.1, 1)
        local cfs = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cfs:SetPoint("CENTER"); cfs:SetText("X")
        close:SetScript("OnClick", closeModal)
    end

    -- Live plain-English preview of what this condition tests. Updates on
    -- every edit so the user reads a sentence, not a stack of raw fields.
    local previewBox = CreateFrame("Frame", nil, f)
    previewBox:SetPoint("TOPLEFT", 10, -46)
    previewBox:SetPoint("TOPRIGHT", -10, -46)
    previewBox:SetHeight(36)
    if U then U.paint(previewBox, U.C.bg2); U.border(previewBox, U.C.line) end
    local castLbl = (U and U.dim(previewBox, "CASTS WHEN", "GameFontDisableSmall"))
        or previewBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    castLbl:SetPoint("LEFT", 8, 0)
    castLbl:SetWidth(76); castLbl:SetJustifyH("LEFT")
    local previewFs = (U and U.label(previewBox, "", "GameFontNormal"))
        or previewBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    previewFs:SetPoint("LEFT", castLbl, "RIGHT", 6, 0)
    previewFs:SetPoint("RIGHT", -8, 0)
    previewFs:SetJustifyH("LEFT")
    if previewFs.SetTextColor then previewFs:SetTextColor(1, 0.94, 0.6) end

    -- Description / spell-drop status line.
    local hintFs = (U and U.dim(f, "", "GameFontDisableSmall"))
        or f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFs:SetPoint("TOPLEFT", 14, -88)
    hintFs:SetPoint("TOPRIGHT", -14, -88)
    hintFs:SetJustifyH("LEFT")
    hintFs:SetHeight(22)
    self._editHint = hintFs

    -- Scroll host for parameter rows.
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 8, -HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", -26, FOOTER_H)
    local host = CreateFrame("Frame", nil, scroll)
    host:SetWidth(FRAME_W - 34)
    host:SetHeight(10)
    scroll:SetScrollChild(host)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local cur = scroll:GetVerticalScroll() or 0
        local maxS = scroll._maxScroll or 0
        scroll:SetVerticalScroll(math.max(0, math.min(maxS, cur - delta * 34)))
    end)
    self._editScroll = scroll

    -- Enum option sets. A param's own `cycle` overrides these defaults so a
    -- single key (e.g. `op`) can carry a different option list per condition.
    local STRING_CYCLES = {
        power_type = { "primary", "mana", "rage", "energy", "runic", "focus", "runes", "combo_points", "felfury" },
        mode       = { "pct", "units" },
        unit       = { "player", "target" },
        kind       = { "buff", "debuff" },
        state      = { "present", "missing" },
        -- ptype is a legacy alias of power_type; keep the lists identical so a
        -- stored value from either always round-trips to a pool World can read.
        ptype      = { "primary", "mana", "rage", "energy", "runic", "focus", "runes", "combo_points", "felfury" },
        school     = { "auto", "physical", "holy", "fire", "nature", "frost", "shadow", "arcane", "magic" },
        op         = { ">=", "<=", "=", ">", "<", "in_range" },
        auto_mode  = { "melee", "ranged", "any" },
    }

    local function truthy(v) return v == true or v == 1 or v == "true" end

    -- Current edit context accessors. self._ec is (re)bound by EditCondition on
    -- every open: { cond = ..., ci = ..., def = ..., rows = ... }.
    local function curArgs() return editor._ec.cond.args end

    local relayout    -- forward declaration (setArg calls it)

    -- Pools that are discrete counts (not percentages). Selecting one should
    -- compare as raw units, else "felfury >= 3" silently means ">= 3%". Runes is
    -- an equally discrete 0-6 pool, so it belongs here too.
    local DISCRETE_POOLS = { felfury = true, combo_points = true, runes = true }

    -- Resolve a CASTABLE spell name -> book spell id (GetSpellLink).
    -- This returns the skill you cast, NOT necessarily the buff/debuff application
    -- id (they often share a name but have different ids). Never use this to
    -- overwrite an aura condition's spell_id.
    local function resolve_name_to_spell_id(name)
        name = tostring(name or "")
        if name == "" then return nil end
        if GetSpellLink then
            local ok, link = pcall(GetSpellLink, name)
            if ok and type(link) == "string" then
                local id = link:match("spell:(%d+)") or link:match("Hspell:(%d+)")
                if id then return tonumber(id) end
            end
        end
        if GetSpellInfo then
            local ok, n = pcall(GetSpellInfo, name)
            if ok and n and n ~= "" and GetSpellLink then
                local ok2, link2 = pcall(GetSpellLink, n)
                if ok2 and type(link2) == "string" then
                    local id = link2:match("spell:(%d+)") or link2:match("Hspell:(%d+)")
                    if id then return tonumber(id) end
                end
            end
        end
        return nil
    end

    -- Conditions whose spell_id is an AURA application id (buff/debuff), not a
    -- castable book spell. GetSpellLink(name) returns the skill id, which is
    -- often DIFFERENT from the aura id even when names match - overwriting the
    -- user-entered debuff id with the skill id is a hard bug.
    local function is_aura_id_condition(cond_id)
        cond_id = tostring(cond_id or "")
        if cond_id == "aura" then return true end
        -- Legacy aura shims still present on old saved rotations.
        if cond_id:find("buff", 1, true) or cond_id:find("debuff", 1, true)
            or cond_id:find("aura", 1, true) then
            return true
        end
        return false
    end

    local function setArg(key, value)
        local e = editor._ec
        if not e then return end
        e.cond.args[key] = value
        local cond_id = e.cond and e.cond.id
        local aura_cond = is_aura_id_condition(cond_id)

        if key == "spell_id" then
            -- Id -> name display fill only. Never reverse-resolve id from that name.
            local id = tonumber(value) or 0
            if id > 0 and GetSpellInfo then
                local ok, sn = pcall(GetSpellInfo, id)
                if ok and type(sn) == "string" and sn ~= "" then
                    e.cond.args.name = sn
                end
            end
        elseif key == "name" then
            local nm = tostring(value or "")
            if nm ~= "" and not aura_cond then
                -- Castable-spell conditions (cooldown, usable, in_range, known):
                -- bidirectional name <-> book id is correct.
                local id = resolve_name_to_spell_id(nm)
                if id and id > 0 then
                    e.cond.args.spell_id = id
                    if GetSpellInfo then
                        local ok, sn = pcall(GetSpellInfo, id)
                        if ok and type(sn) == "string" and sn ~= "" then
                            e.cond.args.name = sn
                        end
                    end
                end
            end
            -- Aura conditions: name is an independent match key / label.
            -- spell_id (when set) is authoritative and must stay as the user typed it.
        end
        -- When the power pool changes on the unified `power` condition, snap the
        -- compare mode to "units" for a discrete pool (counts can't be a percent
        -- of a small cap without being a footgun). Do NOT force "pct" for a
        -- continuous pool - that would silently clobber a user who deliberately
        -- chose raw units for, say, mana.
        if (key == "power_type" or key == "ptype") and e.cond and e.cond.id == "power"
            and DISCRETE_POOLS[tostring(value)] then
            e.cond.args.mode = "units"
        end
        local Engine = RaijinLab.RotationEngine
        -- Re-fetch: the rotation may outlive a reload; commit against the live
        -- copy at fire time, never a captured one.
        local r = editor:GetRotation()
        if r then
            Engine.update_condition(r, editor.selectedIndex, e.ci, { args = e.cond.args })
            editor:Save(r)
        end
        if relayout then relayout() end
    end

    -- ---- row builders -------------------------------------------------
    local function newRow()
        local row = CreateFrame("Frame", nil, host)
        row:SetHeight(ROW_H)
        return row
    end

    local function addLabel(row, text)
        local lbl = (U and U.label(row, text, "GameFontNormalSmall"))
            or row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 6, 0)
        lbl:SetWidth(150); lbl:SetJustifyH("LEFT")
        return lbl
    end

    -- Enum -> dropdown
    local function makeEnumRow(p, options)
        local row = newRow()
        addLabel(row, p.label or p.key)
        local dd
        if U and U.dropdown then
            dd = U.dropdown(row, 250,
                function() return options end,
                function() return curArgs()[p.key] end,
                function(v) setArg(p.key, v) end,
                function(v) return prettyValue(p.key, v) end)
            dd:SetPoint("LEFT", 160, 0)
        end
        row._param = p
        row._sync = function()
            if dd then
                local v = curArgs()[p.key]; if v == nil then v = p.default end
                dd:SetValue(v)
            end
        end
        return row
    end

    -- Bool -> checkbox
    local function makeBoolRow(p, labelText)
        local row = newRow()
        local cb
        if U and U.checkbox then
            cb = U.checkbox(row, nil, labelText or p.label or p.key, truthy(curArgs()[p.key]),
                function(on) setArg(p.key, on) end)
            cb:SetPoint("LEFT", 4, 0)
        end
        row._param = p
        row._sync = function() if cb then cb:SetChecked(truthy(curArgs()[p.key])) end end
        return row
    end

    -- Free-text -> editbox (aura name, etc.)
    local function makeTextRow(p)
        local row = newRow()
        addLabel(row, p.label or p.key)
        local eb = CreateFrame("EditBox", nil, row)
        eb:SetPoint("LEFT", 160, 0)
        eb:SetWidth(250); eb:SetHeight(24)
        eb:SetAutoFocus(false)
        eb:SetFontObject(GameFontHighlightSmall or "GameFontHighlightSmall")
        eb:SetTextInsets(6, 6, 0, 0)
        if U then U.paint(eb, U.C.bg2); U.border(eb, U.C.line) else paint(eb, 0.12, 0.14, 0.18, 1) end
        eb:SetScript("OnEnterPressed", function(s) setArg(p.key, s:GetText() or ""); s:ClearFocus() end)
        eb:SetScript("OnEditFocusLost", function(s) setArg(p.key, s:GetText() or "") end)
        eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        row._param = p
        row._sync = function()
            if not eb:HasFocus() then eb:SetText(tostring(curArgs()[p.key] or p.default or "")) end
        end
        return row
    end

    local function stepValue(p, delta)
        local step = tonumber(p.step) or 1
        local cur = tonumber(curArgs()[p.key]) or tonumber(p.default) or 0
        cur = cur + delta * step
        if p.min then cur = math.max(p.min, cur) end
        if p.max then cur = math.min(p.max, cur) end
        setArg(p.key, cur)
    end

    -- Number -> [-] [editbox] [+]  (+ Cursor button for spell_id)
    local function makeNumberRow(p)
        local row = newRow()
        addLabel(row, p.label or p.key)
        local dec = (U and U.button(row, "-", 24, 24, function() stepValue(p, -1) end)) or CreateFrame("Button", nil, row)
        dec:SetPoint("LEFT", 160, 0)
        if not U then dec:SetWidth(24); dec:SetHeight(24); paint(dec, 0.2, 0.2, 0.25, 1); dec:SetScript("OnClick", function() stepValue(p, -1) end) end
        local eb = CreateFrame("EditBox", nil, row)
        eb:SetPoint("LEFT", dec, "RIGHT", 4, 0)
        eb:SetWidth(66); eb:SetHeight(24)
        eb:SetAutoFocus(false); eb:SetJustifyH("CENTER")
        eb:SetFontObject(GameFontHighlightSmall or "GameFontHighlightSmall")
        if U then U.paint(eb, U.C.bg2); U.border(eb, U.C.line) else paint(eb, 0.12, 0.14, 0.18, 1) end
        local function commit(s)
            local v = tonumber(s:GetText())
            if v then
                if p.min then v = math.max(p.min, v) end
                if p.max then v = math.min(p.max, v) end
                setArg(p.key, v)
            else
                s:SetText(tostring(curArgs()[p.key] or p.default or 0))
            end
        end
        eb:SetScript("OnEnterPressed", function(s) commit(s); s:ClearFocus() end)
        eb:SetScript("OnEditFocusLost", function(s) commit(s) end)
        eb:SetScript("OnEscapePressed", function(s) s:SetText(tostring(curArgs()[p.key] or p.default or 0)); s:ClearFocus() end)
        local inc = (U and U.button(row, "+", 24, 24, function() stepValue(p, 1) end)) or CreateFrame("Button", nil, row)
        inc:SetPoint("LEFT", eb, "RIGHT", 4, 0)
        if not U then inc:SetWidth(24); inc:SetHeight(24); paint(inc, 0.2, 0.2, 0.25, 1); inc:SetScript("OnClick", function() stepValue(p, 1) end) end

        local extraFs
        if p.key == "spell_id" then
            local cursorBtn = (U and U.button(row, "Cursor", 64, 24, function()
                local sid, sname = resolve_cursor_spell()
                if sid then
                    -- Only set spell_id. setArg fills name from GetSpellInfo(id).
                    -- Do NOT setArg("name") afterward - that re-resolved the name
                    -- via GetSpellLink and overwrote aura debuff ids with skill ids.
                    setArg("spell_id", sid)
                else
                    print("|cff7ec8e3RaijinLab|r: pick up a spell first, or drop it on this window")
                end
            end)) or CreateFrame("Button", nil, row)
            cursorBtn:SetPoint("LEFT", inc, "RIGHT", 8, 0)
            if not U then cursorBtn:SetWidth(64); cursorBtn:SetHeight(24); paint(cursorBtn, 0.16, 0.28, 0.36, 1) end
            extraFs = (U and U.dim(row, "", "GameFontDisableSmall")) or row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            extraFs:SetPoint("LEFT", cursorBtn, "RIGHT", 8, 0)
            extraFs:SetPoint("RIGHT", -4, 0)
            extraFs:SetJustifyH("LEFT")
        end

        row._param = p
        row._sync = function()
            local v = curArgs()[p.key]; if v == nil then v = p.default end
            if not eb:HasFocus() then eb:SetText(tostring(v or 0)) end
            if extraFs then
                local id = tonumber(v) or 0
                if id > 0 and GetSpellInfo then
                    local sn = GetSpellInfo(id)
                    extraFs:SetText(sn and ("= " .. sn) or "")
                elseif editor._ec.def.id == "aura" then
                    -- Aura at id 0 matches by the name field, not the slot spell.
                    extraFs:SetText("0 = match by name below")
                else
                    extraFs:SetText("0 = this slot's spell")
                end
            end
        end
        return row
    end

    -- ---- classify + build rows ----------------------------------------
    local function isBoolParam(p) return p.type == "bool" or p.key == "ready" or p.key == "want" end
    local function enumOptions(p) return p.cycle or STRING_CYCLES[p.key] end
    local function isNumberParam(p)
        if p.type == "number" then return true end
        local k = p.key
        return k == "spell_id" or k == "value" or k == "value_max" or k == "amount"
            or k == "count" or k == "pct" or k == "range" or k == "seconds"
            or k == "n" or k == "min" or k == "max" or k == "form"
            or k == "stacks" or k == "min_stacks" or k == "max_stacks"
            or k == "min_remaining" or k == "remaining" or k == "remaining_max"
    end

    -- Build (once) the full row set for one condition definition. Cached by
    -- def.id in self._editRowsById; every row is a child of the shared host.
    local function buildRowsFor(def)
        local rows = {}
        for _, p in ipairs(def.params or {}) do
            local row
            if isBoolParam(p) then
                row = makeBoolRow(p)
            elseif enumOptions(p) then
                row = makeEnumRow(p, enumOptions(p))
            elseif isNumberParam(p) then
                row = makeNumberRow(p)
            else
                row = makeTextRow(p)
            end
            rows[#rows + 1] = row
        end
        -- Universal invert, always last, as a checkbox.
        rows[#rows + 1] = makeBoolRow(
            { key = "invert", type = "bool", default = false },
            "NOT  -  invert (slot passes when this is FALSE)")
        return rows
    end
    self._editBuildRows = buildRowsFor

    -- ---- layout + live refresh ----------------------------------------
    relayout = function()
        local e = editor._ec
        if not e then return end
        local cond, def = e.cond, e.def
        local yy = -4
        for _, row in ipairs(e.rows) do
            local p = row._param
            local vis = true
            if p and p.show_if then
                local ok, r = pcall(p.show_if, cond.args)
                vis = ok and r and true or false
            end
            if vis then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", host, "TOPLEFT", 4, yy)
                row:SetPoint("RIGHT", host, "RIGHT", -4, 0)
                row:Show()
                if row._sync then row._sync() end
                yy = yy - (ROW_H + 6)
            else
                row:Hide()
            end
        end
        local contentH = math.max(-yy + 6, 10)
        host:SetHeight(contentH)
        previewFs:SetText(summarizeCondition(cond, def))

        local desired = HEADER_H + contentH + FOOTER_H
        local frameH  = math.max(220, math.min(desired, 560))
        f:SetHeight(frameH)
        local viewport = frameH - HEADER_H - FOOTER_H
        scroll._maxScroll = math.max(0, contentH - viewport)
        if (scroll:GetVerticalScroll() or 0) > scroll._maxScroll then
            scroll:SetVerticalScroll(scroll._maxScroll)
        end
    end
    self._editRelayout = relayout

    -- Spell drop: prefer spell_id (authoritative). setArg fills name from the id.
    -- Do not also setArg("name") - name->id reverse overwrote aura debuff ids.
    local function onSpellDrop(spellId, name)
        local e = editor._ec
        if not e then return end
        local has_id, has_name = false, false
        for _, p in ipairs(e.def.params or {}) do
            if p.key == "spell_id" then has_id = true end
            if p.key == "name" then has_name = true end
        end
        if has_id and spellId then
            setArg("spell_id", spellId)
            hintFs:SetText("|cff59d97aSpell set:|r " .. tostring(name or "") .. "  (" .. tostring(spellId) .. ")")
        elseif has_name and name then
            setArg("name", name)
            hintFs:SetText("|cff59d97aName set:|r " .. tostring(name))
        else
            hintFs:SetText("This condition has no spell field.")
        end
    end
    if U and U.enableSpellDrop then
        U.enableSpellDrop(f, onSpellDrop)
        U.enableSpellDrop(titleBar, onSpellDrop)
    else
        f:SetScript("OnReceiveDrag", function()
            local sid, sn = resolve_cursor_spell()
            if sid then onSpellDrop(sid, sn) end
            if ClearCursor then ClearCursor() end
        end)
    end

    local done = (U and U.button(f, "Done", 110, 28, closeModal)) or CreateFrame("Button", nil, f)
    done:SetPoint("BOTTOM", 0, 14)
    if not U then
        done:SetWidth(110); done:SetHeight(28)
        paint(done, 0.16, 0.3, 0.22, 1)
        done:SetScript("OnClick", closeModal)
    end

    self.editFrame = f
    self._editRowsById = {}
end

function Editor:EditCondition(ci)
    local Conditions = RaijinLab.Conditions
    local Engine = RaijinLab.RotationEngine
    local rotation = self:GetRotation()
    local U = UI()
    local slot = rotation and rotation.slots[self.selectedIndex]
    local cond = slot and slot.conditions and slot.conditions[ci]
    if not cond then return end
    local def = Conditions.get(cond.id)
    if not def then return end
    cond.args = cond.args or {}
    if cond.args.invert == nil then cond.args.invert = false end

    -- Seed any unset param with its default so the on-screen value, the stored
    -- value, and evaluation all agree. Matters most for value_max: eval falls
    -- back to `value` when it's absent, so an unseeded field would display a
    -- default the logic doesn't actually use. Runs once, persists once.
    do
        local seeded = false
        for _, p in ipairs(def.params or {}) do
            if cond.args[p.key] == nil and p.default ~= nil then
                cond.args[p.key] = p.default
                seeded = true
            end
        end
        if seeded then
            local r0 = self:GetRotation()
            if r0 then
                Engine.update_condition(r0, self.selectedIndex, ci, { args = cond.args })
                self:Save(r0)
            end
        end
    end

    -- Close any stray dropdown popup (hide only, never orphan - see Menu:Hide
    -- rationale). A leftover popup could outlive its anchor.
    if U and U.closeDropdowns then U.closeDropdowns() end

    self:_ensureEditChrome()

    -- Bind the current edit context; every pooled widget reads through it.
    self._ec = { cond = cond, ci = ci, def = def }

    -- Hide rows built for other condition ids, then reuse (or build once) the
    -- row set for this id. Rows are pooled per id, not per open.
    for _, list in pairs(self._editRowsById) do
        for _, row in ipairs(list) do row:Hide() end
    end
    local rows = self._editRowsById[def.id]
    if not rows then
        rows = self._editBuildRows(def)
        self._editRowsById[def.id] = rows
    end
    self._ec.rows = rows

    -- Refresh chrome text for this condition.
    if U then
        self._editTitle:SetText(def.name or cond.id)
    else
        self._editTitle:SetText("Edit: " .. (def.name or cond.id))
    end
    self._editHint:SetText(def.description or "")

    self._editScroll:SetVerticalScroll(0)  -- open at the top, like a fresh modal
    self._editRelayout()
    self.editFrame:Show()
end

if RaijinLab then
    RaijinLab.RotationEditor = Editor
end

return Editor
