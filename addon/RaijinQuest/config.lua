-- multi api compat
local compat = RaijinQuestCompat
local L = RaijinQuest_Loc

RaijinQuest_history = {}
RaijinQuest_colors = {}
RaijinQuest_config = {}

local reset = {
  config = function()
    local dialog = StaticPopupDialogs["PFQUEST_RESET"]
    dialog.text = L["Do you really want to reset the configuration?"]
    dialog.OnAccept = function()
      RaijinQuest_config = nil
      ReloadUI()
    end

    StaticPopup_Show("PFQUEST_RESET")
  end,
  history = function()
    local dialog = StaticPopupDialogs["PFQUEST_RESET"]
    dialog.text = L["Do you really want to reset the quest history?"]
    dialog.OnAccept = function()
      RaijinQuest_history = nil
      ReloadUI()
    end

    StaticPopup_Show("PFQUEST_RESET")
  end,
  cache = function()
    local dialog = StaticPopupDialogs["PFQUEST_RESET"]
    dialog.text = L["Do you really want to reset the caches?"]
    dialog.OnAccept = function()
      RaijinQuest_questcache = nil
      ReloadUI()
    end

    StaticPopup_Show("PFQUEST_RESET")
  end,
  everything = function()
    local dialog = StaticPopupDialogs["PFQUEST_RESET"]
    dialog.text = L["Do you really want to reset everything?"]
    dialog.OnAccept = function()
      RaijinQuest_config, RaijinQuestBrowser_fav, RaijinQuest_history, RaijinQuest_colors, RaijinQuest_server = nil
      ReloadUI()
    end

    StaticPopup_Show("PFQUEST_RESET")
  end,
}

-- default config
RaijinQuest_defconfig = {
  { -- 1: All Quests; 2: Tracked; 3: Manual; 4: Hide
    config = "trackingmethod",
    text = nil, default = 1, type = nil
  },

  { text = L["General"],
    default = nil, type = "header" },
  { text = L["Enable World Map Menu"],
    default = "1", type = "checkbox", config = "worldmapmenu" },
  { text = L["Enable Minimap Button"],
    default = "1", type = "checkbox", config = "minimapbutton" },
  { text = L["Enable Quest Tracker"],
    default = "1", type = "checkbox", config = "showtracker" },
  { text = L["Enable Quest Log Buttons"],
    default = "1", type = "checkbox", config = "questlogbuttons" },
  { text = L["Enable Quest Link Support"],
    default = "1", type = "checkbox", config = "questlinks" },
  { text = L["Show Database IDs"],
    default = "0", type = "checkbox", config = "showids" },
  { text = L["Draw Favorites On Login"],
    default = "0", type = "checkbox", config = "favonlogin" },
  { text = L["Minimum Item Drop Chance"],
    default = "1", type = "text", config = "mindropchance" },
  { text = L["Show Tooltips"],
    default = "1", type = "checkbox", config = "showtooltips" },
  { text = L["Show Help On Tooltips"],
    default = "1", type = "checkbox", config = "tooltiphelp" },
  { text = L["Show Level On Quest Tracker"],
    default = "1", type = "checkbox", config = "trackerlevel" },
  { text = L["Show Level On Quest Log"],
    default = "0", type = "checkbox", config = "questloglevel" },

  { text = L["Questing"],
    default = nil, type = "header" },
  { text = L["Quest Tracker Visibility"],
    default = "0", type = "text", config = "trackeralpha" },
  { text = L["Quest Tracker Font Size"],
    default = "12", type = "text", config = "trackerfontsize", },
  { text = L["Quest Tracker Unfold Objectives"],
    default = "0", type = "checkbox", config = "trackerexpand" },
  { text = L["Quest Objective Spawn Points (World Map)"],
    default = "1", type = "checkbox", config = "showspawn" },
  { text = L["Quest Objective Spawn Points (Mini Map)"],
    default = "1", type = "checkbox", config = "showspawnmini" },
  { text = L["Quest Objective Icons (World Map)"],
    default = "1", type = "checkbox", config = "showcluster" },
  { text = L["Quest Objective Icons (Mini Map)"],
    default = "0", type = "checkbox", config = "showclustermini" },
  { text = L["Display Available Quest Givers"],
    default = "1", type = "checkbox", config = "allquestgivers" },
  { text = L["Display Current Quest Givers"],
    default = "1", type = "checkbox", config = "currentquestgivers" },
  { text = L["Display Low Level Quest Givers"],
    default = "0", type = "checkbox", config = "showlowlevel" },
  { text = L["Display Level+3 Quest Givers"],
    default = "0", type = "checkbox", config = "showhighlevel" },
  { text = L["Display Event & Daily Quests"],
    default = "0", type = "checkbox", config = "showfestival" },

  { text = L["Map & Minimap"],
    default = nil, type = "header" },
  { text = L["Enable Minimap Nodes"],
    default = "1", type = "checkbox", config = "minimapnodes" },
  { text = L["Use Monochrome Cluster Icons"],
    default = "0", type = "checkbox", config = "clustermono" },
  { text = L["Use Cut-Out Minimap Node Icons"],
    default = "1", type = "checkbox", config = "cutoutminimap" },
  { text = L["Use Cut-Out World Map Node Icons"],
    default = "0", type = "checkbox", config = "cutoutworldmap" },
  { text = L["Color Map Nodes By Spawn"],
    default = "0", type = "checkbox", config = "spawncolors" },
  { text = L["World Map Node Transparency"],
    default = "1.0", type = "text", config = "worldmaptransp" },
  { text = L["Minimap Node Transparency"],
    default = "1.0", type = "text", config = "minimaptransp" },
  { text = L["Node Fade Transparency"],
    default = "0.3", type = "text", config = "nodefade" },
  { text = L["Highlight Nodes On Mouseover"],
    default = "1", type = "checkbox", config = "mouseover" },

  { text = L["Routes"],
    default = nil, type = "header" },
  { text = L["Show Route Between Objects"],
    default = "1", type = "checkbox", config = "routes" },
  { text = L["Include Unified Quest Locations"],
    default = "1", type = "checkbox", config = "routecluster" },
  { text = L["Include Quest Enders"],
    default = "1", type = "checkbox", config = "routeender" },
  { text = L["Include Quest Starters"],
    default = "0", type = "checkbox", config = "routestarter" },
  { text = L["Show Route On Minimap"],
    default = "0", type = "checkbox", config = "routeminimap" },
  { text = L["Show Arrow Along Routes"],
    default = "1", type = "checkbox", config = "arrow" },

  { text = L["User Data"],
    default = nil, type = "header" },
  { text = L["Reset Configuration"],
    default = "1", type = "button", func = reset.config },
  { text = L["Reset Quest History"],
    default = "1", type = "button", func = reset.history },
  { text = L["Reset Cache"],
    default = "1", type = "button", func = reset.cache },
  { text = L["Reset Everything"],
    default = "1", type = "button", func = reset.everything },
}

StaticPopupDialogs["PFQUEST_RESET"] = {
  button1 = YES,
  button2 = NO,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
}

RaijinQuestConfig = CreateFrame("Frame", "RaijinQuestConfig", UIParent)
RaijinQuestConfig:Hide()
RaijinQuestConfig:SetWidth(280)
RaijinQuestConfig:SetHeight(550)
RaijinQuestConfig:SetPoint("CENTER", 0, 0)
RaijinQuestConfig:SetFrameStrata("HIGH")
RaijinQuestConfig:SetMovable(true)
RaijinQuestConfig:EnableMouse(true)
RaijinQuestConfig:SetClampedToScreen(true)
RaijinQuestConfig:RegisterEvent("ADDON_LOADED")
RaijinQuestConfig:SetScript("OnEvent", function()
  if arg1 == "RaijinQuest" or arg1 == "RaijinQuest-tbc" or arg1 == "RaijinQuest-wotlk" then
    RaijinQuestConfig:LoadConfig()
    RaijinQuestConfig:MigrateHistory()
    RaijinQuestConfig:CreateConfigEntries(RaijinQuest_defconfig)

    RaijinQuest_questcache = RaijinQuest_questcache or {}
    RaijinQuest_history = RaijinQuest_history or {}
    RaijinQuest_colors = RaijinQuest_colors or {}
    RaijinQuest_config = RaijinQuest_config or {}
    RaijinQuestBrowser_fav = RaijinQuestBrowser_fav or {["units"] = {}, ["objects"] = {}, ["items"] = {}, ["quests"] = {}}

    -- clear quest history on new characters
    if UnitXP("player") == 0 and UnitLevel("player") == 1 then
      RaijinQuest_history = {}
    end

    if RaijinQuestBrowserIcon and RaijinQuest_config["minimapbutton"] == "0" then
      RaijinQuestBrowserIcon:Hide()
    end
  end
end)

RaijinQuestConfig:SetScript("OnMouseDown", function()
  this:StartMoving()
end)

RaijinQuestConfig:SetScript("OnMouseUp", function()
  this:StopMovingOrSizing()
end)

RaijinQuestConfig:SetScript("OnShow", function()
  this:UpdateConfigEntries()
end)

RaijinQuestConfig.vpos = 40

pfUI.api.CreateBackdrop(RaijinQuestConfig, nil, true, 0.75)
table.insert(UISpecialFrames, "RaijinQuestConfig")

-- WE ARE VENDORED. WE ARE NOT AN ADDON ANY MORE.
--
-- This detected its own folder with GetAddOnInfo("RaijinQuest"), which worked
-- when it WAS a top-level addon. It now lives inside RaijinLab, so every
-- candidate returned nil, `path` was never set, and the first concatenation of
-- it threw - in map.lua, before RaijinQuestMap was ever created. Everything
-- downstream then failed on a nil global (284 errors from quest.lua alone).
--
-- Our location is known, so state it. The detection loop below stays as a
-- fallback so an unmodified copy still works as a standalone addon.
RaijinQuestConfig.path = "Interface\\AddOns\\RaijinLab\\RaijinQuest"
RaijinQuestConfig.version = tostring(
  (GetAddOnMetadata and GetAddOnMetadata("RaijinLab", "Version")) or "vendored")

-- detect current addon path
local tocs = { "", "-master", "-tbc", "-wotlk" }
for _, name in pairs(tocs) do
  local current = string.format("RaijinQuest%s", name)
  local _, title = GetAddOnInfo(current)
  if title then
    RaijinQuestConfig.path = "Interface\\AddOns\\" .. current
    RaijinQuestConfig.version = tostring(GetAddOnMetadata(current, "Version"))
    break
  end
end

RaijinQuestConfig.title = RaijinQuestConfig:CreateFontString("Status", "LOW", "GameFontNormal")
RaijinQuestConfig.title:SetFontObject(GameFontWhite)
RaijinQuestConfig.title:SetPoint("TOP", RaijinQuestConfig, "TOP", 0, -8)
RaijinQuestConfig.title:SetJustifyH("LEFT")
RaijinQuestConfig.title:SetFont(pfUI.font_default, 14)
RaijinQuestConfig.title:SetText("|cff33ffccpf|rQuest " .. L["Config"])

RaijinQuestConfig.close = CreateFrame("Button", "RaijinQuestConfigClose", RaijinQuestConfig)
RaijinQuestConfig.close:SetPoint("TOPRIGHT", -5, -5)
RaijinQuestConfig.close:SetHeight(20)
RaijinQuestConfig.close:SetWidth(20)
RaijinQuestConfig.close.texture = RaijinQuestConfig.close:CreateTexture("RaijinQuestionDialogCloseTex")
RaijinQuestConfig.close.texture:SetTexture(RaijinQuestConfig.path.."\\compat\\close")
RaijinQuestConfig.close.texture:ClearAllPoints()
RaijinQuestConfig.close.texture:SetPoint("TOPLEFT", RaijinQuestConfig.close, "TOPLEFT", 4, -4)
RaijinQuestConfig.close.texture:SetPoint("BOTTOMRIGHT", RaijinQuestConfig.close, "BOTTOMRIGHT", -4, 4)

RaijinQuestConfig.close.texture:SetVertexColor(1,.25,.25,1)
pfUI.api.SkinButton(RaijinQuestConfig.close, 1, .5, .5)
RaijinQuestConfig.close:SetScript("OnClick", function()
  this:GetParent():Hide()
end)

RaijinQuestConfig.save = CreateFrame("Button", "RaijinQuestConfigReload", RaijinQuestConfig)
RaijinQuestConfig.save:SetWidth(160)
RaijinQuestConfig.save:SetHeight(28)
RaijinQuestConfig.save:SetPoint("BOTTOM", 0, 10)
RaijinQuestConfig.save:SetScript("OnClick", ReloadUI)
RaijinQuestConfig.save.text = RaijinQuestConfig.save:CreateFontString("Caption", "LOW", "GameFontWhite")
RaijinQuestConfig.save.text:SetAllPoints(RaijinQuestConfig.save)
RaijinQuestConfig.save.text:SetFont(pfUI.font_default, pfUI_config.global.font_size, "OUTLINE")
RaijinQuestConfig.save.text:SetText(L["Close & Reload"])
pfUI.api.SkinButton(RaijinQuestConfig.save)

function RaijinQuestConfig:LoadConfig()
  if not RaijinQuest_config then RaijinQuest_config = {} end
  for id, data in pairs(RaijinQuest_defconfig) do
    if data.config and not RaijinQuest_config[data.config] then
      RaijinQuest_config[data.config] = data.default
    end
  end
end

function RaijinQuestConfig:MigrateHistory()
  if not RaijinQuest_history then return end

  local match = false

  for entry, data in pairs(RaijinQuest_history) do
    if type(entry) == "string" then
      for id in pairs(RaijinQuestDatabase:GetIDByName(entry, "quests")) do
        RaijinQuest_history[id] = { 0, 0 }
        RaijinQuest_history[entry] = nil
        match = true
      end
    elseif data == true then
      RaijinQuest_history[entry] = { 0, 0 }
    elseif type(data) == "table" and not data[1] then
      RaijinQuest_history[entry] = { 0, 0 }
    end
  end

  if match == true then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest|r: " .. L["Quest history migration completed."])
  end
end

local maxh, maxw = 0, 0
local width, height = 230, 22
local maxtext = 130
local configframes = {}
function RaijinQuestConfig:CreateConfigEntries(config)
  local count = 1

  for _, data in pairs(config) do
    if data.type then
      -- basic frame
      local frame = CreateFrame("Frame", "RaijinQuestConfig" .. count, RaijinQuestConfig)
      configframes[data.text] = frame

      -- caption
      frame.caption = frame:CreateFontString("Status", "LOW", "GameFontWhite")
      frame.caption:SetFont(pfUI.font_default, pfUI_config.global.font_size, "OUTLINE")
      frame.caption:SetPoint("LEFT", 20, 0)
      frame.caption:SetJustifyH("LEFT")
      frame.caption:SetText(data.text)
      maxtext = max(maxtext, frame.caption:GetStringWidth())

      -- header
      if data.type == "header" then
        frame.caption:SetPoint("LEFT", 10, 0)
        frame.caption:SetTextColor(.3,1,.8)
        frame.caption:SetFont(pfUI.font_default, pfUI_config.global.font_size+2, "OUTLINE")

      -- checkbox
      elseif data.type == "checkbox" then
        frame.input = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        frame.input:SetNormalTexture("")
        frame.input:SetPushedTexture("")
        frame.input:SetHighlightTexture("")
        pfUI.api.CreateBackdrop(frame.input, nil, true)

        frame.input:SetWidth(16)
        frame.input:SetHeight(16)
        frame.input:SetPoint("RIGHT" , -20, 0)

        frame.input.config = data.config
        if RaijinQuest_config[data.config] == "1" then
          frame.input:SetChecked()
        end

        frame.input:SetScript("OnClick", function ()
          if this:GetChecked() then
            RaijinQuest_config[this.config] = "1"
          else
            RaijinQuest_config[this.config] = "0"
          end

          RaijinQuest:ResetAll()
        end)
      elseif data.type == "text" then
        -- input field
        frame.input = CreateFrame("EditBox", nil, frame)
        frame.input:SetTextColor(.2,1,.8,1)
        frame.input:SetJustifyH("RIGHT")
        frame.input:SetTextInsets(5,5,5,5)
        frame.input:SetWidth(32)
        frame.input:SetHeight(16)
        frame.input:SetPoint("RIGHT", -20, 0)
        frame.input:SetFontObject(GameFontNormal)
        frame.input:SetAutoFocus(false)
        frame.input:SetScript("OnEscapePressed", function(self)
          this:ClearFocus()
        end)

        frame.input.config = data.config
        frame.input:SetText(RaijinQuest_config[data.config])

        frame.input:SetScript("OnTextChanged", function(self)
          RaijinQuest_config[this.config] = this:GetText()
        end)

        pfUI.api.CreateBackdrop(frame.input, nil, true)
      elseif data.type == "button" and data.func then
        frame.input = CreateFrame("Button", nil, frame)
        frame.input:SetWidth(32)
        frame.input:SetHeight(16)
        frame.input:SetPoint("RIGHT", -20, 0)
        frame.input:SetScript("OnClick", data.func)
        frame.input.text = frame.input:CreateFontString("Caption", "LOW", "GameFontWhite")
        frame.input.text:SetAllPoints(frame.input)
        frame.input.text:SetFont(pfUI.font_default, pfUI_config.global.font_size, "OUTLINE")
        frame.input.text:SetText("OK")
        pfUI.api.SkinButton(frame.input)
      end

      -- increase size and zoom back due to blizzard backdrop reasons...
      if frame.input and pfUI.api.emulated then
        frame.input:SetWidth(frame.input:GetWidth()/.6)
        frame.input:SetHeight(frame.input:GetHeight()/.6)
        frame.input:SetScale(.8)
        if frame.input.SetTextInsets then
          frame.input:SetTextInsets(8,8,8,8)
        end
      end

      count = count + 1
    end
  end

  -- update sizes / positions
  width = maxtext + 100
  local column, row = 1, 0

  for _, data in pairs(config) do
    if data.type then
      -- empty line for headers, next column for > 20 entries
      row = row + ( data.type == "header" and row > 1 and 2 or 1 )
      if row > 20 and data.type == "header" then
        column, row = column + 1, 1
      end

      -- update max size values
      maxw, maxh = max(maxw, column), max(maxh, row)

      -- align frames to sizings
      local spacer = (column-1)*20
      local x, y = (column-1)*width, -(row-1)*height
      local frame = configframes[data.text]
      frame:SetWidth(width)
      frame:SetHeight(height)
      frame:SetPoint("TOPLEFT", RaijinQuestConfig, "TOPLEFT", x + spacer + 10, y - 40)
    end
  end

  local spacer = (maxw-1)*20
  RaijinQuestConfig:SetWidth(maxw*width + spacer + 20)
  RaijinQuestConfig:SetHeight(maxh*height + 100)
end

function RaijinQuestConfig:UpdateConfigEntries()
  for _, data in pairs(RaijinQuest_defconfig) do
    if data.type and configframes[data.text] then
      if data.type == "checkbox" then
        configframes[data.text].input:SetChecked((RaijinQuest_config[data.config] == "1" and true or nil))
      elseif data.type == "text" then
        configframes[data.text].input:SetText(RaijinQuest_config[data.config])
      end
    end
  end
end

do -- welcome/init popup dialog
  local config_stage = {
    arrow = 1,
    mode = 2
  }

  -- create welcome/init window
  RaijinQuestInit = CreateFrame("Frame", "RaijinQuestInit", UIParent)
  RaijinQuestInit:Hide()
  RaijinQuestInit:SetWidth(400)
  RaijinQuestInit:SetHeight(270)
  RaijinQuestInit:SetPoint("CENTER", 0, 0)
  RaijinQuestInit:RegisterEvent("PLAYER_ENTERING_WORLD")
  RaijinQuestInit:SetScript("OnEvent", function()
    if RaijinQuest_config.welcome ~= "1" then
      -- parse current config
      if RaijinQuest_config["showspawn"] == "0" and RaijinQuest_config["showcluster"] == "1" then
        config_stage.mode = 1
      elseif RaijinQuest_config["showspawn"] == "1" and RaijinQuest_config["showcluster"] == "0" then
        config_stage.mode = 3
      end

      if RaijinQuest_config["arrow"] == "0" then
        config_stage.arrow = nil
      end

      -- reload ui elements
      RaijinQuestInit[1].bg:SetDesaturated(true)
      RaijinQuestInit[2].bg:SetDesaturated(true)
      RaijinQuestInit[3].bg:SetDesaturated(true)
      RaijinQuestInit[config_stage.mode].bg:SetDesaturated(false)
      RaijinQuestInit.checkbox:SetChecked(config_stage.arrow)

      RaijinQuestInit:Show()
    end
    this:UnregisterAllEvents()
  end)

  pfUI.api.CreateBackdrop(RaijinQuestInit, nil, true, 0.85)

  -- welcome title
  RaijinQuestInit.title = RaijinQuestInit:CreateFontString("Status", "LOW", "GameFontWhite")
  RaijinQuestInit.title:SetPoint("TOP", RaijinQuestInit, "TOP", 0, -17)
  RaijinQuestInit.title:SetJustifyH("LEFT")
  RaijinQuestInit.title:SetText(L["Please select your preferred |cff33ffccpf|cffffffffQuest|r mode:"])

  -- questing mode
  local buttons = {
    { caption = L["Simple Markers"], texture = "\\img\\init\\simple", position = { "TOPLEFT", 10, -40 },
      tooltip = L["Only show cluster icons with summarized objective locations based on spawn points"] },
    { caption = L["Combined"], texture = "\\img\\init\\combined", position = { "TOP", 0, -40 },
      tooltip = L["Show cluster icons with summarized locations and also display all spawn points of each quest objective"] },
    { caption = L["Spawn Points"], texture = "\\img\\init\\spawns", position = { "TOPRIGHT", -10, -40 },
      tooltip = L["Display all spawn points of each quest objective and hide summarized cluster icons."] },
  }

  for i, button in pairs(buttons) do
    RaijinQuestInit[i] = CreateFrame("Button", "RaijinQuestInitLeft", RaijinQuestInit)
    RaijinQuestInit[i]:SetWidth(120)
    RaijinQuestInit[i]:SetHeight(160)
    RaijinQuestInit[i]:SetPoint(unpack(button.position))
    RaijinQuestInit[i]:SetID(i)

    RaijinQuestInit[i].bg = RaijinQuestInit[i]:CreateTexture(nil, "NORMAL")
    RaijinQuestInit[i].bg:SetWidth(200)
    RaijinQuestInit[i].bg:SetHeight(200)
    RaijinQuestInit[i].bg:SetPoint("CENTER", 0, 0)
    RaijinQuestInit[i].bg:SetTexture(RaijinQuestConfig.path..button.texture)

    RaijinQuestInit[i].caption = RaijinQuestInit:CreateFontString("Status", "LOW", "GameFontWhite")
    RaijinQuestInit[i].caption:SetPoint("TOP", RaijinQuestInit[i], "BOTTOM", 0, -5)
    RaijinQuestInit[i].caption:SetJustifyH("LEFT")
    RaijinQuestInit[i].caption:SetText(button.caption)

    pfUI.api.SkinButton(RaijinQuestInit[i])

    RaijinQuestInit[i]:SetScript("OnClick", function()
      RaijinQuestInit[1].bg:SetDesaturated(true)
      RaijinQuestInit[2].bg:SetDesaturated(true)
      RaijinQuestInit[3].bg:SetDesaturated(true)
      RaijinQuestInit[this:GetID()].bg:SetDesaturated(false)

      config_stage.mode = this:GetID()
    end)

    local OnEnter = RaijinQuestInit[i]:GetScript("OnEnter")
    RaijinQuestInit[i]:SetScript("OnEnter", function()
      if OnEnter then OnEnter() end
      GameTooltip_SetDefaultAnchor(GameTooltip, this)

      GameTooltip:SetText(this.caption:GetText())
      GameTooltip:AddLine(buttons[this:GetID()].tooltip, 1, 1, 1, true)
      GameTooltip:SetWidth(100)
      GameTooltip:Show()
    end)

    local OnLeave = RaijinQuestInit[i]:GetScript("OnLeave")
    RaijinQuestInit[i]:SetScript("OnLeave", function()
      if OnLeave then OnLeave() end
      GameTooltip:Hide()
    end)
  end

  -- show arrows
  RaijinQuestInit.checkbox = CreateFrame("CheckButton", nil, RaijinQuestInit, "UICheckButtonTemplate")
  RaijinQuestInit.checkbox:SetPoint("BOTTOMLEFT", 10, 10)
  RaijinQuestInit.checkbox:SetNormalTexture("")
  RaijinQuestInit.checkbox:SetPushedTexture("")
  RaijinQuestInit.checkbox:SetHighlightTexture("")
  RaijinQuestInit.checkbox:SetWidth(22)
  RaijinQuestInit.checkbox:SetHeight(22)
  pfUI.api.CreateBackdrop(RaijinQuestInit.checkbox, nil, true)

  RaijinQuestInit.checkbox.caption = RaijinQuestInit:CreateFontString("Status", "LOW", "GameFontWhite")
  RaijinQuestInit.checkbox.caption:SetPoint("LEFT", RaijinQuestInit.checkbox, "RIGHT", 5, 0)
  RaijinQuestInit.checkbox.caption:SetJustifyH("LEFT")
  RaijinQuestInit.checkbox.caption:SetText(L["Show Navigation Arrow"])
  RaijinQuestInit.checkbox:SetScript("OnClick", function()
    config_stage.arrow = this:GetChecked()
  end)

  RaijinQuestInit.checkbox:SetScript("OnEnter", function()
    GameTooltip_SetDefaultAnchor(GameTooltip, this)
    GameTooltip:SetText(L["Navigation Arrow"])
    GameTooltip:AddLine(L["Show navigation arrow that points you to the nearest quest location."], 1, 1, 1, true)
    GameTooltip:SetWidth(100)
    GameTooltip:Show()
  end)

  RaijinQuestInit.checkbox:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  -- save button
  RaijinQuestInit.save = CreateFrame("Button", nil, RaijinQuestInit)
  RaijinQuestInit.save:SetWidth(100)
  RaijinQuestInit.save:SetHeight(24)
  RaijinQuestInit.save:SetPoint("BOTTOMRIGHT", -10, 10)
  RaijinQuestInit.save.text = RaijinQuestInit.save:CreateFontString("Caption", "LOW", "GameFontWhite")
  RaijinQuestInit.save.text:SetAllPoints(RaijinQuestInit.save)
  RaijinQuestInit.save.text:SetText("Save & Close")

  pfUI.api.SkinButton(RaijinQuestInit.save)

  RaijinQuestInit.save:SetScript("OnClick", function()
    -- write current config
    if config_stage.mode == 1 then
      RaijinQuest_config["showspawn"] = "0"
      RaijinQuest_config["showspawnmini"] = "0"
      RaijinQuest_config["showcluster"] = "1"
      RaijinQuest_config["showclustermini"] = "1"
    elseif config_stage.mode == 2 then
      RaijinQuest_config["showspawn"] = "1"
      RaijinQuest_config["showspawnmini"] = "1"
      RaijinQuest_config["showcluster"] = "1"
      RaijinQuest_config["showclustermini"] = "0"
    elseif config_stage.mode == 3 then
      RaijinQuest_config["showspawn"] = "1"
      RaijinQuest_config["showspawnmini"] = "1"
      RaijinQuest_config["showcluster"] = "0"
      RaijinQuest_config["showclustermini"] = "0"
    end

    if config_stage.arrow then
      RaijinQuest_config["arrow"] = "1"
    else
      RaijinQuest_config["arrow"] = "0"
    end

    -- save welcome flag and reload
    RaijinQuest_config["welcome"] = "1"
    RaijinQuest:ResetAll()
    RaijinQuestInit:Hide()
  end)
end
