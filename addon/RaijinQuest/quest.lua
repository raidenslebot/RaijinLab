-- multi api compat
local compat = RaijinQuestCompat
local _, _, _, client = GetBuildInfo()
client = client or 11200
local _G = client == 11200 and getfenv(0) or _G

RaijinQuest = CreateFrame("Frame")
RaijinQuest.icons = {}

if client >= 30300 then
  RaijinQuest.dburl = "https://www.wowhead.com/wotlk/quest="
elseif client >= 20400 then
  RaijinQuest.dburl = "https://www.wowhead.com/tbc/quest="
else
  RaijinQuest.dburl = "https://www.wowhead.com/classic/quest="
end

function RaijinQuest:Debug(msg)
  -- only show debug output if enabled
  if not RaijinQuest_config.debug and RaijinQuest.debugwin then
    RaijinQuest.debugwin:Hide()
    return
  elseif not RaijinQuest_config.debug then
    return
  end

  if not RaijinQuest.debugwin then
    RaijinQuest.debugwin = CreateFrame("ScrollingMessageFrame", nil, UIParent)
    RaijinQuest.debugwin:SetWidth(320)
    RaijinQuest.debugwin:SetHeight(320)
    RaijinQuest.debugwin:SetPoint("RIGHT", -42, 0)
    RaijinQuest.debugwin:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    RaijinQuest.debugwin:SetFading(false)
    RaijinQuest.debugwin:SetMaxLines(150)
    RaijinQuest.debugwin:SetJustifyH("RIGHT")
    RaijinQuest.debugwin:SetJustifyV("CENTER")
  end

  RaijinQuest.debugwin:AddMessage(msg)
  RaijinQuest.debugwin:Show()
end

function RaijinQuest:SortedPairs(t, index, reverse)
  -- collect the keys
  local keys = {}
  for k, v in pairs(t) do
    if v then keys[table.getn(keys)+1] = k end
  end

  local order
  if reverse then
    order = function(t,a,b) return t[a][index] < t[b][index] end
  else
    order = function(t,a,b) return t[a][index] > t[b][index] end
  end
  table.sort(keys, function(a,b) return order(t, a, b) end)

  -- return the iterator function
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

RaijinQuest.queue = {}
RaijinQuest.abandon = ""
RaijinQuest.questlog = {}
RaijinQuest.questlog_tmp = {}

local function tsize(tbl)
  if not tbl or not type(tbl) == "table" then return 0 end
  local c = 0
  for _ in pairs(tbl) do c = c + 1 end
  return c
end

local skillstate = ""
RaijinQuest:RegisterEvent("QUEST_WATCH_UPDATE")
RaijinQuest:RegisterEvent("QUEST_LOG_UPDATE")
RaijinQuest:RegisterEvent("QUEST_FINISHED")
RaijinQuest:RegisterEvent("PLAYER_LEVEL_UP")
RaijinQuest:RegisterEvent("PLAYER_ENTERING_WORLD")
RaijinQuest:RegisterEvent("SKILL_LINES_CHANGED")
RaijinQuest:RegisterEvent("ADDON_LOADED")
RaijinQuest:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == "RaijinQuest" or arg1 == "RaijinQuest-tbc" or arg1 == "RaijinQuest-wotlk" then
      RaijinQuest:AddQuestLogIntegration()
      RaijinQuest:AddWorldMapIntegration()
      this.lock = GetTime() + 10
    else
      return
    end
  elseif event == "SKILL_LINES_CHANGED" then
    local skills = ""
    for i=0, GetNumSkillLines() do
      skills = skills .. (GetSkillLineInfo(i) or "")
    end

    -- update quest givers when new skills or
    -- professions became available
    if skills ~= skillstate then
      RaijinQuest.updateQuestGivers = true
      skillstate = skills
    end
  elseif event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD" then
    RaijinQuest.updateQuestGivers = true
  else
    RaijinQuest.updateQuestLog = true
  end

  if event == "QUEST_LOG_UPDATE" then
    -- lock initial scan during incoming events
    if this.lock and this.lock > GetTime() then
      this.lock = GetTime() + 1.5
    end
  end
end)

RaijinQuest:SetScript("OnUpdate", function()
  if this.lock and this.lock > GetTime() then return end
  if not RaijinQuestDatabase.localized then return end

  if ( this.tick or .05) > GetTime() then return else this.tick = GetTime() + .05 end

  -- check questlog each second
  if ( this.qlogtick or 1) < GetTime() then
    if RaijinQuest:UpdateQuestlog() then
      RaijinQuest:Debug("Update Quest|cff33ffcc Log|r [|cffff3333Tick|r]")
    end
    this.qlogtick = GetTime() + 1
  end

  if this.updateQuestLog == true and tsize(this.queue) == 0 then
    RaijinQuest:Debug("Update Quest|cff33ffcc Log")
    RaijinQuest:UpdateQuestlog()
    this.updateQuestLog = false
  end

  if this.updateQuestGivers == true then
    RaijinQuest:Debug("Update Quest|cff33ffcc Givers")
    if RaijinQuest_config["trackingmethod"] ~= 4 and
      RaijinQuest_config["allquestgivers"] == "1"
    then
      local meta = { ["addon"] = "PFQUEST" }
      RaijinQuestDatabase:SearchQuests(meta)
    end
    this.updateQuestGivers = false
  end

  if tsize(this.queue) == 0 then return end

  -- process queue
  for id, entry in pairs(this.queue) do

    -- remove quest
    if entry[4] == "REMOVE" then
      RaijinQuest:Debug("|cffff5555Remove Quest: " .. entry[1] .. " (" .. entry[2] .. ")")

      -- write RaijinQuest.questlog history
      if entry[1] == RaijinQuest.abandon then
        RaijinQuest_history[entry[2]] = nil
      else
        RaijinQuest_history[entry[2]] = { time(), UnitLevel("player") }
      end

      if RaijinQuest_config["trackingmethod"] ~= 4 then
        -- delete nodes by title
        RaijinQuestMap:DeleteNode("PFQUEST", entry[1])

        -- also delete nodes by quest ids for servers with different names
        if entry[2] and RaijinQuestDB["quests"]["loc"][entry[2]] and RaijinQuestDB["quests"]["loc"][entry[2]].T then
          RaijinQuestMap:DeleteNode("PFQUEST", RaijinQuestDB["quests"]["loc"][entry[2]].T)
        end
      end

      RaijinQuest.abandon = ""
    else
      if entry[4] == "NEW" then
        RaijinQuest:Debug("|cff55ff55New Quest: " .. entry[1] .. " (" .. entry[2] .. ")")
      else
        RaijinQuest:Debug("|cffffff55Update Quest: " .. entry[1] .. " (" .. entry[2] .. ")")
      end

      -- update quest nodes
      if RaijinQuest_config["trackingmethod"] ~= 4 then
        -- delete node by title
        RaijinQuestMap:DeleteNode("PFQUEST", entry[1])

        -- delete nodes by quest ids for servers with different names
        if entry[2] and RaijinQuestDB["quests"]["loc"][entry[2]] and RaijinQuestDB["quests"]["loc"][entry[2]].T then
          RaijinQuestMap:DeleteNode("PFQUEST", RaijinQuestDB["quests"]["loc"][entry[2]].T)
        end

        -- skip quest objective detection on manual and tacked mode
        if RaijinQuest_config["trackingmethod"] ~= 3 and
          (RaijinQuest_config["trackingmethod"] ~= 2 or IsQuestWatched(entry[3]))
        then
          local meta = { ["addon"] = "PFQUEST", ["qlogid"] = entry[3] }
          RaijinQuestDatabase:SearchQuestID(entry[2], meta)
        end
      end
    end

    -- remove entry from queue
    RaijinQuest.queue[id] = nil

    -- only return when other entries exist
    -- otherwise, continue and update questgivers
    for id, entry in pairs(this.queue) do
      return
    end
  end

  -- trigger questgiver update
  if tsize(this.queue) == 0 then
    this.updateQuestLog = true
    this.updateQuestGivers = true
  end
end)

local questlog_flip, questlog_flop = {}, {}
function RaijinQuest:UpdateQuestlog()
  -- initialize flip flop if not yet defined
  RaijinQuest.questlog_tmp = RaijinQuest.questlog_tmp or questlog_flip

  local _, numQuests = GetNumQuestLogEntries()
  local found = 0
  local change = nil

  -- iterate over all quests
  for qlogid=1,40 do
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(qlogid)
    local objectives = GetNumQuestLeaderBoards(qlogid)
    local watched, questid, state

    if title and not header then
      questid = RaijinQuestDatabase:GetQuestIDs(qlogid)
      questid = questid and tonumber(questid[1]) or title
      watched = IsQuestWatched(qlogid)
      state = watched and "track" or ""

      -- build state string
      if objectives then
        for i=1, objectives, 1 do
          local text, _, done = GetQuestLogLeaderBoard(i, qlogid)
          state = state .. i .. (done and "done" or "todo")
        end
      end

      -- add new quest to the questlog
      if not RaijinQuest.questlog[questid] then
        table.insert(RaijinQuest.queue, { title, questid, qlogid, "NEW" })
        RaijinQuest.questlog_tmp[questid] = {
          title = title,
          qlogid = qlogid,
          state = state,
        }
        change = true
      elseif RaijinQuest.questlog[questid].qlogid ~= qlogid then
        table.insert(RaijinQuest.queue, { title, questid, qlogid, "RELOAD" })
        RaijinQuest.questlog_tmp[questid] = RaijinQuest.questlog[questid]
        RaijinQuest.questlog_tmp[questid].qlogid = qlogid
        RaijinQuest.questlog_tmp[questid].state = state
        change = true
      elseif RaijinQuest.questlog[questid].state ~= state then
        table.insert(RaijinQuest.queue, { title, questid, qlogid, "RELOAD" })
        RaijinQuest.questlog_tmp[questid] = RaijinQuest.questlog[questid]
        RaijinQuest.questlog_tmp[questid].qlogid = qlogid
        RaijinQuest.questlog_tmp[questid].state = state
        change = true
      else
        RaijinQuest.questlog_tmp[questid] = RaijinQuest.questlog[questid]
      end

      found = found + 1
      if found >= numQuests then
        break
      end
    end
  end

  -- quest removal events
  for questid, data in pairs(RaijinQuest.questlog) do
    if not RaijinQuest.questlog_tmp[questid] then
      table.insert(RaijinQuest.queue, { data.title, questid, nil, "REMOVE" })
      change = true
    end
  end

  -- set questlog to current flip flop
  RaijinQuest.questlog = RaijinQuest.questlog_tmp

  -- switch tmp to the other flip flop
  if RaijinQuest.questlog_tmp == questlog_flip then
    RaijinQuest.questlog_tmp = questlog_flop
  else
    RaijinQuest.questlog_tmp = questlog_flip
  end

  -- clear next temporary questlog entries
  for k, v in pairs(RaijinQuest.questlog_tmp) do
    RaijinQuest.questlog_tmp[k] = nil
  end

  return change
end

function RaijinQuest:ResetAll()
  -- force reload all quests
  RaijinQuestMap:DeleteNode("PFQUEST")
  RaijinQuest.questlog = {}
  RaijinQuest.updateQuestLog = true
  RaijinQuest.updateQuestGivers = true
end

-- register popup dialog to copy urls
StaticPopupDialogs["PFQUEST_URLCOPY"] = {
  text = "|cff33ffccpf|cffffffffQuest " .. RaijinQuest_Loc["Online Search"],
  button1 = "Close",
  hasEditBox = 1,
  hasWideEditBox = 1,
  timeout = 0,
  exclusive = 1,
  whileDead = 1,
  hideOnEscape = 1,
  OnShow = function()
    local editBox = _G[this:GetName().."WideEditBox"]
    editBox:SetText(StaticPopupDialogs["PFQUEST_URLCOPY"].data)
    editBox:HighlightText()
  end,
  OnHide = function()
    _G[this:GetName().."WideEditBox"]:SetText("")
  end,
  EditBoxOnEnterPressed = function()
    this:GetParent():Hide()
  end,
  EditBoxOnEscapePressed = function()
    this:GetParent():Hide()
  end,
  EditBoxOnTextChanged = function()
    this:SetText(StaticPopupDialogs["PFQUEST_URLCOPY"].data)
    this:HighlightText()
  end,
}

function RaijinQuest:AddQuestLogIntegration()
  if RaijinQuest_config["questlogbuttons"] ==  "0" then return end

  local dockFrame = EQL3_QuestLogDetailScrollChildFrame or ShaguQuest_QuestLogDetailScrollChildFrame or QuestLogDetailScrollChildFrame
  local dockTitle = EQL3_QuestLogDescriptionTitle or ShaguQuest_QuestLogDescriptionTitle or RaijinQuestCompat.QuestLogDescriptionTitle

  dockTitle:SetHeight(dockTitle:GetHeight() + 30)
  dockTitle:SetJustifyV("BOTTOM")

  RaijinQuest.buttonOnline = RaijinQuest.buttonOnline or CreateFrame("Button", "RaijinQuestOnline", dockFrame)
  RaijinQuest.buttonOnline:SetWidth(18)
  RaijinQuest.buttonOnline:SetHeight(15)
  RaijinQuest.buttonOnline:SetPoint("TOPRIGHT", dockFrame, "TOPRIGHT", -12, -10)
  RaijinQuest.buttonOnline:SetScript("OnClick", function()
    if pfUI and pfUI.chat then
      pfUI.chat.urlcopy.text:SetText(RaijinQuest.dburl .. (this:GetID() or 0))
      pfUI.chat.urlcopy:Show()
    else
      StaticPopupDialogs["PFQUEST_URLCOPY"].data = RaijinQuest.dburl .. (this:GetID() or 0)
      local dialog = StaticPopup_Show("PFQUEST_URLCOPY")
      _G[dialog:GetName().."Button1"]:ClearAllPoints()
      _G[dialog:GetName().."Button1"]:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 16)
      _G[dialog:GetName().."WideEditBox"]:SetScript('OnTextChanged', StaticPopup_EditBoxOnTextChanged)
      dialog:SetWidth(420)
    end
  end)

  RaijinQuest.buttonOnline.txt = RaijinQuest.buttonOnline:CreateFontString("RaijinQuestIDButton", "HIGH", "GameFontWhite")
  RaijinQuest.buttonOnline.txt:SetAllPoints(RaijinQuest.buttonOnline)
  RaijinQuest.buttonOnline.txt:SetJustifyH("RIGHT")
  RaijinQuest.buttonOnline.txt:SetText("|cff000000[|cffaa2222?|cff000000]")

  RaijinQuest.buttonLanguage = RaijinQuest.buttonLanguage or CreateFrame("Button", "RaijinQuestLanguage", dockFrame)
  RaijinQuest.buttonLanguage:SetWidth(75)
  RaijinQuest.buttonLanguage:SetHeight(15)
  RaijinQuest.buttonLanguage:SetPoint("RIGHT", RaijinQuest.buttonOnline, "LEFT", 0, 0)

  RaijinQuest.buttonLanguage.txt = RaijinQuest.buttonLanguage:CreateFontString("RaijinQuestIDButton", "HIGH", "GameFontWhite")
  RaijinQuest.buttonLanguage.txt:SetAllPoints(RaijinQuest.buttonLanguage)
  RaijinQuest.buttonLanguage.txt:SetJustifyH("RIGHT")
  RaijinQuest.buttonLanguage.txt:SetText("|cff000000[|cff333333" .. RaijinQuest_Loc["Translate"] .. "|cff000000]")

  RaijinQuest.buttonLanguage:SetScript("OnClick", function()
    UIDropDownMenu_Initialize(self, function()
      local func = function() RaijinQuest_config.translate = this.value end
      local info = {}
      info.text = "|cffaaaaaa" .. RaijinQuest_Loc["Reset Language"]
      info.value = nil
      info.func = func
      UIDropDownMenu_AddButton(info);

      for loc, caption in pairs(RaijinQuestDB.locales) do
        local info = {}
        info.text = caption
        info.value = loc
        info.func = func
        UIDropDownMenu_AddButton(info);
      end
    end)
    ToggleDropDownMenu(1, nil, self, "cursor", 3, -3)
  end)

  RaijinQuest.buttonLanguage:SetScript("OnUpdate", function()
    local id = RaijinQuest.buttonOnline:GetID()
    local lang = RaijinQuest_config.translate

    if this.translate ~= RaijinQuest_config.translate then
      RaijinQuest.buttonLanguage.txt:SetText("|cff000000[|cff3333ff" .. (RaijinQuestDB.locales[RaijinQuest_config.translate] or "|cff333333" .. RaijinQuest_Loc["Translate"]) .. "|cff000000]")
      this.translate = RaijinQuest_config.translate
      QuestLog_UpdateQuestDetails(true)
      return
    end

    if id and RaijinQuestDB["quests"][lang] and RaijinQuestDB["quests"][lang][id] then
      local QuestLogQuestTitle = EQL3_QuestLogQuestTitle or RaijinQuestCompat.QuestLogQuestTitle
      local QuestLogObjectivesText = EQL3_QuestLogObjectivesText or RaijinQuestCompat.QuestLogObjectivesText
      local QuestLogQuestDescription = EQL3_QuestLogQuestDescription or RaijinQuestCompat.QuestLogQuestDescription
      local QuestLogDetailScrollFrame = EQL3_QuestLogDetailScrollFrame or QuestLogDetailScrollFrame

      QuestLogQuestTitle:SetText(RaijinQuestDatabase:FormatQuestText(RaijinQuestDB["quests"][lang][id]["T"]))
      QuestLogObjectivesText:SetText(RaijinQuestDatabase:FormatQuestText(RaijinQuestDB["quests"][lang][id]["O"]))
      QuestLogQuestDescription:SetText(RaijinQuestDatabase:FormatQuestText(RaijinQuestDB["quests"][lang][id]["D"]))
      QuestLogDetailScrollFrame:UpdateScrollChildRect()
    end
  end)

  RaijinQuest.buttonShow = RaijinQuest.buttonShow or CreateFrame("Button", "RaijinQuestShow", dockFrame, "UIPanelButtonTemplate")
  RaijinQuest.buttonShow:SetWidth(70)
  RaijinQuest.buttonShow:SetHeight(20)
  RaijinQuest.buttonShow:SetText(RaijinQuest_Loc["Show"])
  RaijinQuest.buttonShow:SetPoint("TOP", dockTitle, "TOP", -110, 0)
  RaijinQuest.buttonShow:SetScript("OnClick", function()
    local questIndex = GetQuestLogSelection()
    local questids = RaijinQuestDatabase:GetQuestIDs(questIndex)
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(questIndex)
    local id = questids and tonumber(questids[1])
    if header or not id then return end

    local maps, meta = {}, { ["addon"] = "PFQUEST", ["qlogid"] = questIndex }
    maps = RaijinQuestDatabase:SearchQuestID(id, meta, maps)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
  end)

  RaijinQuest.buttonHide = RaijinQuest.buttonHide or CreateFrame("Button", "RaijinQuestHide", dockFrame, "UIPanelButtonTemplate")
  RaijinQuest.buttonHide:SetWidth(70)
  RaijinQuest.buttonHide:SetHeight(20)
  RaijinQuest.buttonHide:SetText(RaijinQuest_Loc["Hide"])
  RaijinQuest.buttonHide:SetPoint("TOP", dockTitle, "TOP", -37, 0)
  RaijinQuest.buttonHide:SetScript("OnClick", function()
    local questIndex = GetQuestLogSelection()
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(questIndex)
    if header then return end

    RaijinQuestMap:DeleteNode("PFQUEST", title)
  end)

  RaijinQuest.buttonClean = RaijinQuest.buttonClean or CreateFrame("Button", "RaijinQuestClean", dockFrame, "UIPanelButtonTemplate")
  RaijinQuest.buttonClean:SetWidth(70)
  RaijinQuest.buttonClean:SetHeight(20)
  RaijinQuest.buttonClean:SetText(RaijinQuest_Loc["Clean"])
  RaijinQuest.buttonClean:SetPoint("TOP", dockTitle, "TOP", 37, 0)
  RaijinQuest.buttonClean:SetScript("OnClick", function()
    RaijinQuestMap:DeleteNode("PFQUEST")
  end)

  RaijinQuest.buttonReset = RaijinQuest.buttonReset or CreateFrame("Button", "RaijinQuestReset", dockFrame, "UIPanelButtonTemplate")
  RaijinQuest.buttonReset:SetWidth(70)
  RaijinQuest.buttonReset:SetHeight(20)
  RaijinQuest.buttonReset:SetText(RaijinQuest_Loc["Reset"])
  RaijinQuest.buttonReset:SetPoint("TOP", dockTitle, "TOP", 110, 0)
  RaijinQuest.buttonReset:SetScript("OnClick", function()
    RaijinQuest:ResetAll()
  end)

  -- use pfUI buttons in native mode
  if not pfUI.api.emulated then
    pfUI.api.SkinButton(RaijinQuest.buttonShow)
    pfUI.api.SkinButton(RaijinQuest.buttonHide)
    pfUI.api.SkinButton(RaijinQuest.buttonClean)
    pfUI.api.SkinButton(RaijinQuest.buttonReset)
  end
end

function RaijinQuest:AddWorldMapIntegration()
  if RaijinQuest_config["worldmapmenu"] ==  "0" then return end

  -- Quest Display Selection
  RaijinQuest.mapButton = CreateFrame("Frame", "RaijinQuestMapDropdown", WorldMapButton, "UIDropDownMenuTemplate")
  RaijinQuest.mapButton:ClearAllPoints()
  RaijinQuest.mapButton:SetPoint("TOPRIGHT" , 0, -10)
  RaijinQuest.mapButton:SetScript("OnShow", function()
    RaijinQuest.mapButton.current = tonumber(RaijinQuest_config["trackingmethod"])
    RaijinQuest.mapButton:UpdateMenu()
  end)

  RaijinQuest.mapButton.point = "TOPLEFT"
  RaijinQuest.mapButton.relativePoint = "BOTTOMLEFT"

  function RaijinQuest.mapButton:UpdateMenu()
    local function CreateEntries()
      local info = {}
      info.text = RaijinQuest_Loc["All Quests"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(RaijinQuest.mapButton, this:GetID(), 0)
        RaijinQuest_config["trackingmethod"] = this:GetID()
        RaijinQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = RaijinQuest_Loc["Tracked Quests"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(RaijinQuest.mapButton, this:GetID(), 0)
        RaijinQuest_config["trackingmethod"] = this:GetID()
        RaijinQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = RaijinQuest_Loc["Manual Selection"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(RaijinQuest.mapButton, this:GetID(), 0)
        RaijinQuest_config["trackingmethod"] = this:GetID()
        RaijinQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = RaijinQuest_Loc["Hide Quests"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(RaijinQuest.mapButton, this:GetID(), 0)
        RaijinQuest_config["trackingmethod"] = this:GetID()
        RaijinQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)
    end

    UIDropDownMenu_Initialize(RaijinQuest.mapButton, CreateEntries)
    if client >= 30300 then
      UIDropDownMenu_SetWidth(RaijinQuest.mapButton, 120)
      UIDropDownMenu_SetButtonWidth(RaijinQuest.mapButton, 125)
      UIDropDownMenu_JustifyText(RaijinQuest.mapButton, "RIGHT")
    else
      UIDropDownMenu_SetWidth(120, RaijinQuest.mapButton)
      UIDropDownMenu_SetButtonWidth(125, RaijinQuest.mapButton)
      UIDropDownMenu_JustifyText("RIGHT", RaijinQuest.mapButton)
    end
    UIDropDownMenu_SetSelectedID(RaijinQuest.mapButton, RaijinQuest.mapButton.current)
  end
end

-- [[ Hook UI Functions ]] --
-- Set certain events on quest watch
local rqHookRemoveQuestWatch = RemoveQuestWatch
RemoveQuestWatch = function(questIndex)
  local ret = rqHookRemoveQuestWatch(questIndex)

  if questIndex then
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(questIndex)
    RaijinQuestMap:DeleteNode("PFQUEST", title)
  end

  RaijinQuest.updateQuestLog = true
  RaijinQuest.updateQuestGivers = true

  return ret
end

-- Set certain events on quest unwatch
local rqHookAddQuestWatch = AddQuestWatch
AddQuestWatch = function(questIndex)
  local ret = rqHookAddQuestWatch(questIndex)
  RaijinQuest.updateQuestLog = true
  RaijinQuest.updateQuestGivers = true
  return ret
end

-- Save the abandoned questname to remove from history
local HookAbandonQuest = AbandonQuest
AbandonQuest = function()
  RaijinQuest.abandon = GetAbandonQuestName()
  HookAbandonQuest()
end

local function UpdateQuestLevel(button, id)
  local title, level, tag, header = compat.GetQuestLogTitle(id)
  if header or not title then return end
  button:SetText(" [" .. ( level or "??" ) .. ( tag and "+" or "") .. "] " .. title)
  if not QuestLogTitleButton_Resize then return end
  QuestLogTitleButton_Resize(button)
end

-- Update quest id button
local rqHookQuestLog_Update = QuestLog_Update
QuestLog_Update = function()
  rqHookQuestLog_Update()

  if RaijinQuest_config["questloglevel"] == "1" then
    if client >= 30300 then
      for i, button in pairs(QuestLogScrollFrame.buttons) do
        UpdateQuestLevel(button, button:GetID())
      end
    else
      for i=1, QUESTS_DISPLAYED, 1 do
        UpdateQuestLevel(_G["QuestLogTitle"..i], i + FauxScrollFrame_GetOffset(QuestLogListScrollFrame))
      end
    end
  end

  if RaijinQuest_config["questlogbuttons"] ==  "1" then
    local questids = RaijinQuestDatabase:GetQuestIDs(GetQuestLogSelection())
    if questids and questids[1] and tonumber(questids[1]) and RaijinQuest.questlog[questids[1]] then
      RaijinQuest.buttonOnline:SetID(questids[1])
      RaijinQuest.buttonOnline:Show()
      RaijinQuest.buttonLanguage:Show()
      -- enable buttons
      RaijinQuest.buttonShow:Enable()
      RaijinQuest.buttonHide:Enable()

      if RaijinQuest_config.showids == "1" then
        RaijinQuest.buttonOnline.txt:SetText("|cff000000[|cffaa2222id: " .. questids[1] .. "|cff000000]")
        RaijinQuest.buttonOnline:SetWidth(RaijinQuest.buttonOnline.txt:GetStringWidth())
      end
    else
      RaijinQuest.buttonOnline:Hide()
      RaijinQuest.buttonLanguage:Hide()
      -- disable buttons
      RaijinQuest.buttonShow:Disable()
      RaijinQuest.buttonHide:Disable()
    end
  end
end

-- attach the new function to the scroll frame
if QuestLogScrollFrame then
  QuestLogScrollFrame.update = QuestLog_Update
end

-- refresh language and url on quest selection
local rqHookQuestLogTitleButton_OnClick = QuestLogTitleButton_OnClick
QuestLogTitleButton_OnClick = function(self, button)
  rqHookQuestLogTitleButton_OnClick(self, button)
  QuestLog_Update()
end

if not GetQuestLink then -- Allow to send questlinks from questlog
  local rqHookQuestLogTitleButton_OnClick = QuestLogTitleButton_OnClick
  QuestLogTitleButton_OnClick = function(button)
    local scrollFrame = EQL3_QuestLogListScrollFrame or ShaguQuest_QuestLogListScrollFrame or QuestLogListScrollFrame
    local questIndex = this:GetID() + FauxScrollFrame_GetOffset(scrollFrame)
    local questName, questLevel = compat.GetQuestLogTitle(questIndex)
    local questids = RaijinQuestDatabase:GetQuestIDs(questIndex)
    local questid = questids and tonumber(questids[1]) or 0

    if IsShiftKeyDown() and not this.isHeader and ChatFrameEditBox:IsVisible() then
      RaijinQuestCompat.InsertQuestLink(questid, questName)
      QuestLog_SetSelection(questIndex)
      QuestLog_Update()
      return
    end

    rqHookQuestLogTitleButton_OnClick(button)
  end

  -- Patch ItemRef to display Questlinks
  local RaijinQuestHookSetItemRef = SetItemRef
  SetItemRef = function(link, text, button)
    local isQuest, _, id    = string.find(link, "quest:(%d+):.*")
    local isQuest2, _, _   = string.find(link, "quest2:.*")

    if isQuest or isQuest2 then
      if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
        ChatFrameEditBox:Insert(text)
        return
      end

      if ItemRefTooltip:IsShown() and ItemRefTooltip.rqQtext == text then
        HideUIPanel(ItemRefTooltip)
        return
      end

      ShowUIPanel(ItemRefTooltip)
      ItemRefTooltip:SetOwner(UIParent, "ANCHOR_PRESERVE")

      local hasTitle, _, questTitle = string.find(text, ".*|h%[(.*)%]|h.*")

      id = tonumber(id)

      if not id or id == 0 then
        for scanID, data in pairs(RaijinQuestDB["quests"]["loc"]) do
          if data.T == questTitle then
            id = scanID
            break
          end
        end
      end

      -- read and set title
      if id and id > 0 and RaijinQuestDB["quests"]["loc"][id] then
        local questlevel = tonumber(RaijinQuestDB["quests"]["data"][id]["lvl"])
        local color = RaijinQuestCompat.GetDifficultyColor(questlevel)
        ItemRefTooltip:AddLine(RaijinQuestDB["quests"]["loc"][id].T, color.r, color.g, color.b)
      elseif hasTitle then
        ItemRefTooltip:AddLine(questTitle, 1,1,0)
      end

      -- scan for active quests
      local queststate = RaijinQuest_history[id] and 2 or 0
      queststate = RaijinQuest.questlog[id] and 1 or queststate

      if queststate == 0 then
        ItemRefTooltip:AddLine(RaijinQuest_Loc["You don't have this quest."] .. "\n\n", 1, .5, .5)
      elseif queststate == 1 then
        ItemRefTooltip:AddLine(RaijinQuest_Loc["You are on this quest."] .. "\n\n", 1, 1, .5)
      elseif queststate == 2 then
        ItemRefTooltip:AddLine(RaijinQuest_Loc["You already did this quest."] .. "\n\n", .5, 1, .5)
      end

      -- add database entries if existing
      if RaijinQuestDB["quests"]["loc"][id] then
        if RaijinQuestDB["quests"]["loc"][id]["O"] then
          ItemRefTooltip:AddLine(RaijinQuestDatabase:FormatQuestText(RaijinQuestDB["quests"]["loc"][id]["O"]), 1,1,1,true)
        end

        if RaijinQuestDB["quests"]["loc"][id]["O"] and RaijinQuestDB["quests"]["loc"][id]["D"] then
          ItemRefTooltip:AddLine(" ", 0,0,0)
        end

        if RaijinQuestDB["quests"]["loc"][id]["D"] then
          ItemRefTooltip:AddLine(RaijinQuestDatabase:FormatQuestText(RaijinQuestDB["quests"]["loc"][id]["D"]), .8,.8,.8,true)
        end

        if RaijinQuestDB["quests"]["data"][id]["lvl"] or RaijinQuestDB["quests"]["data"][id]["min"] then
          ItemRefTooltip:AddLine(" ", 0,0,0)
        end

        if RaijinQuestDB["quests"]["data"][id]["min"] then
          local questlevel = tonumber(RaijinQuestDB["quests"]["data"][id]["min"])
          local color = RaijinQuestCompat.GetDifficultyColor(questlevel)
          ItemRefTooltip:AddLine("|cffffffff" .. RaijinQuest_Loc["Required Level"] .. ": |r" .. questlevel, color.r, color.g, color.b)
        end

        if RaijinQuestDB["quests"]["data"][id]["lvl"] then
          local questlevel = tonumber(RaijinQuestDB["quests"]["data"][id]["lvl"])
          local color = RaijinQuestCompat.GetDifficultyColor(questlevel)
          ItemRefTooltip:AddLine("|cffffffff" .. RaijinQuest_Loc["Quest Level"] .. ": |r" .. questlevel, color.r, color.g, color.b)
        end
      end

      ItemRefTooltip:Show()
    else
      RaijinQuestHookSetItemRef(link, text, button)
    end
    ItemRefTooltip.rqQtext = text
  end
else
  -- patch itemref to show known quest levels on tbc
  local RaijinQuestHookSetItemRef = SetItemRef
  SetItemRef = function(link, text, button)
    RaijinQuestHookSetItemRef(link, text, button)

    -- skip modifier clicks
    if IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown() then return end

    local quest, _, id = string.find(link, "quest:(%d+):.*")
    if not quest then return end
    id = tonumber(id)

    -- adjust text color to level color
    if id and id > 0 and RaijinQuestDB["quests"]["loc"][id] then
      local questlevel = tonumber(RaijinQuestDB["quests"]["data"][id]["lvl"])
      local color = RaijinQuestCompat.GetDifficultyColor(questlevel)
      ItemRefTooltipTextLeft1:SetTextColor(color.r, color.g, color.b)
    end

    -- add quest levels to tooltip
    if RaijinQuestDB["quests"]["loc"][id] then
      ItemRefTooltip:AddLine(" ")

      if RaijinQuestDB["quests"]["data"][id]["min"] then
        local questlevel = tonumber(RaijinQuestDB["quests"]["data"][id]["min"])
        local color = RaijinQuestCompat.GetDifficultyColor(questlevel)
        ItemRefTooltip:AddLine("|cffffffff" .. RaijinQuest_Loc["Required Level"] .. ": |r" .. questlevel, color.r, color.g, color.b)
      end

      if RaijinQuestDB["quests"]["data"][id]["lvl"] then
        local questlevel = tonumber(RaijinQuestDB["quests"]["data"][id]["lvl"])
        local color = RaijinQuestCompat.GetDifficultyColor(questlevel)
        ItemRefTooltip:AddLine("|cffffffff" .. RaijinQuest_Loc["Quest Level"] .. ": |r" .. questlevel, color.r, color.g, color.b)
      end
    end

    ItemRefTooltip:Show()
  end
end
