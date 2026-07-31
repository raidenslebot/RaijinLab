-- multi api compat
local compat = RaijinQuestCompat

-- default config
RaijinQuestBrowser_fav = {["units"] = {}, ["objects"] = {}, ["items"] = {}, ["quests"] = {}}

local tooltip_limit = 5
local search_limit = 512

-- add database shortcuts
local items = RaijinQuestDB["items"]["data"]
local units = RaijinQuestDB["units"]["data"]
local objects = RaijinQuestDB["objects"]["data"]
local refloot = RaijinQuestDB["refloot"]["data"]
local quests = RaijinQuestDB["quests"]["data"]
local zones = RaijinQuestDB["zones"]["loc"]

local function ShowTooltip()
  if not this.tooltips then return end
  GameTooltip_SetDefaultAnchor(GameTooltip, this)
  GameTooltip:ClearLines()
  for k, v in pairs(this.tooltips) do
    if k == 1 then
      GameTooltip:AddLine(v, 1, 1, 1)
    else
      GameTooltip:AddLine(v)
    end
  end
  GameTooltip:Show()
end

local function EnableTooltips(frame, tooltips)
  frame.tooltips = tooltips
  frame:SetScript("OnEnter", ShowTooltip)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function ResultButtonEnter()
  this.tex:SetTexture(1,1,1,.1)

  -- quest
  if this.btype == "quests" then
    RaijinQuestDatabase:ShowExtendedTooltip(this.id, GameTooltip, this, "ANCHOR_LEFT", -10, -5)

  -- item
  elseif this.btype == "items" then
    GameTooltip:SetOwner(this, "ANCHOR_LEFT", -10, -5)
    GameTooltip:SetHyperlink("item:" .. this.id .. RaijinQuestCompat.itemsuffix)
    GameTooltip:Show()

  -- units / objects
  else
    local id = this.id
    local name = this.name
    local maps = {}
    GameTooltip:SetOwner(this, "ANCHOR_LEFT", -10, -5)
    GameTooltip:SetText(name, .3, 1, .8)
    if this.btype == "units" then
      local unitData = units[id]

      if unitData and unitData.lvl then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(RaijinQuest_Loc["Level"], unitData.lvl, 1,1,.8, 1,1,1)
      end

      local reactionStringA = "|c00ff0000" .. RaijinQuest_Loc["Hostile"] .. "|r"
      local reactionStringH = "|c00ff0000" .. RaijinQuest_Loc["Hostile"] .. "|r"
      if unitData and unitData.fac then
        if unitData.fac == "AH" then
          reactionStringA = "|c0000ff00" .. RaijinQuest_Loc["Friendly"] .. "|r"
          reactionStringH = "|c0000ff00" .. RaijinQuest_Loc["Friendly"] .. "|r"
        elseif unitData.fac == "A" then
          reactionStringA = "|c0000ff00" .. RaijinQuest_Loc["Friendly"] .. "|r"
        elseif unitData.fac == "H" then
          reactionStringH = "|c0000ff00" .. RaijinQuest_Loc["Friendly"] .. "|r"
        end
      end
      GameTooltip:AddLine("\n" .. RaijinQuest_Loc["Reaction"], 1,1,.8)
      GameTooltip:AddDoubleLine(RaijinQuest_Loc["Alliance"], reactionStringA, 1,1,1, 0,0,0)
      GameTooltip:AddDoubleLine(RaijinQuest_Loc["Horde"], reactionStringH, 1,1,1, 0,0,0)
    end
    GameTooltip:AddLine("\n" .. RaijinQuest_Loc["Location"], 1,1,.8)
    if RaijinQuestDB[this.btype]["data"][id] and RaijinQuestDB[this.btype]["data"][id]["coords"] then
      for _, data in pairs(RaijinQuestDB[this.btype]["data"][id]["coords"]) do
        maps[data[3]] = maps[data[3]] or { count = 0 }
        maps[data[3]].count = maps[data[3]].count + 1
      end
    end

    local unknown = true
    for zone, obj in RaijinQuest:SortedPairs(maps, "count", nil) do
      GameTooltip:AddDoubleLine(( zone and RaijinQuestMap:GetMapNameByID(zone) or UNKNOWN), obj.count, 1,1,1, .3,1,.8)
      unknown = nil
    end

    if unknown then
      GameTooltip:AddLine(UNKNOWN, 1,.5,.5)
    end

    GameTooltip:Show()
  end
end

local function ResultButtonUpdate()
  this.refreshCount = this.refreshCount + 1

  if not this.itemColor then
    GameTooltip:SetHyperlink("item:" .. this.id .. RaijinQuestCompat.itemsuffix)
    GameTooltip:Hide()

    local _, _, itemQuality = GetItemInfo(this.id)
    if itemQuality then
      local r = ceil(ITEM_QUALITY_COLORS[itemQuality].r*255)
      local g = ceil(ITEM_QUALITY_COLORS[itemQuality].g*255)
      local b = ceil(ITEM_QUALITY_COLORS[itemQuality].b*255)
      this.itemColor = "|c" .. string.format("ff%02x%02x%02x", r, g, b)
    end
  end

  if this.itemColor then
    local custom = RaijinQuest_server["items"][this.id] and " [|cff33ffcc!|r]" or ""
    this.text:SetText(this.itemColor .."|Hitem:"..this.id..RaijinQuestCompat.itemsuffix.."|h[".. this.name.."]|h|r"..custom)
    this.text:SetWidth(this.text:GetStringWidth())
  end

  if this.refreshCount > 10 or this.itemColor then
    this:SetScript("OnUpdate", nil)
  end
end

local function ResultButtonClick()
  local meta = { ["addon"] = "PFDB" }

  if this.btype == "items" then
    local link = "item:"..this.id..RaijinQuestCompat.itemsuffix
    local text = ( this.itemColor or "|cffffffff" ) .."|H" .. link .. "|h["..this.name.."]|h|r"
    SetItemRef(link, text, arg1)
  elseif this.btype == "quests" then
    if IsShiftKeyDown() then
      RaijinQuestCompat.InsertQuestLink(this.id)
    elseif RaijinQuestBrowser.selectState then
      local maps = RaijinQuestDatabase:SearchQuest(this.name, meta)
      RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    else
      local maps = RaijinQuestDatabase:SearchQuestID(this.id, meta)
      RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    end
  elseif this.btype == "units" then
    if RaijinQuestBrowser.selectState then
      local maps = RaijinQuestDatabase:SearchMob(this.name, meta)
      RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    else
      local maps = RaijinQuestDatabase:SearchMobID(this.id, meta)
      RaijinQuestMap:UpdateNodes()
      RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    end
  elseif this.btype == "objects" then
    if RaijinQuestBrowser.selectState then
      local maps = RaijinQuestDatabase:SearchObject(this.name, meta)
      RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    else
      local maps = RaijinQuestDatabase:SearchObjectID(this.id, meta)
      RaijinQuestMap:UpdateNodes()
      RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    end
  end
end

local function ResultButtonClickFav()
  local parent = this:GetParent()
  if RaijinQuestBrowser_fav[parent.btype][parent.id] then
    RaijinQuestBrowser_fav[parent.btype][parent.id] = nil
    this.icon:SetVertexColor(1,1,1,.1)
  else
    RaijinQuestBrowser_fav[parent.btype][parent.id] = parent.name
    this.icon:SetVertexColor(1,1,1,1)
  end
end

local function ResultButtonLeave()
  if RaijinQuestBrowser.selectState then
    RaijinQuestBrowser.selectState = "clean"
  end

  if compat.mod(this:GetID(),2) == 1 then
    this.tex:SetTexture(1,1,1,.02)
  else
    this.tex:SetTexture(1,1,1,.04)
  end
  GameTooltip:Hide()
end

local function ResultButtonClickSpecial()
  local param = this:GetParent()[this.parameter]
  local meta = { ["addon"] = "PFDB" }
  local maps = {}
  if this.buttonType == "O" or this.buttonType == "U" then
    if this.selectState then
      maps = RaijinQuestDatabase:SearchItem(this:GetParent().name, meta)
    else
      maps = RaijinQuestDatabase:SearchItemID(param, meta, nil, {[this.buttonType]=true})
    end
  elseif this.buttonType == "V" then
    maps = RaijinQuestDatabase:SearchVendor(param, meta)
  end
  RaijinQuestMap:UpdateNodes()
  RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
end

local function ResultButtonEnterSpecial()
  local id = this:GetParent().id
  local count = 0
  local skip = false

  GameTooltip:SetOwner(RaijinQuestBrowser, "ANCHOR_CURSOR")

  -- unit
  if this.buttonType == "U" then
    if items[id]["U"] then
      GameTooltip:SetText(RaijinQuest_Loc["Looted from"], .3, 1, .8)
      for unitID, chance in pairs(items[id]["U"]) do
        count = count + 1
        if count > tooltip_limit then
          skip = true
        end
        if units[unitID] and not skip then
          local name = RaijinQuestDB.units.loc[unitID]
          local zone = nil
          if units[unitID].coords and units[unitID].coords[1] then
            zone = units[unitID].coords[1][3]
          end
          GameTooltip:AddDoubleLine(name, ( zone and RaijinQuestMap:GetMapNameByID(zone) or UNKNOWN), 1,1,1, .5,.5,.5)
        end
      end

      -- reference tables
      if items[id]["R"] then
        for ref, chance in pairs(items[id]["R"]) do
          if refloot[ref] and refloot[ref]["U"] then
            for unit in pairs(refloot[ref]["U"]) do
              count = count + 1
              if count > tooltip_limit then
                skip = true
              end
              if units[unit] and not skip then
                local name = RaijinQuestDB.units.loc[unit]
                local zone = nil
                if units[unit].coords and units[unit].coords[1] then
                  zone = units[unit].coords[1][3]
                end
                GameTooltip:AddDoubleLine(name, ( zone and RaijinQuestMap:GetMapNameByID(zone) or UNKNOWN), 1,1,1, .5,.5,.5)
              end
            end
          end
        end
      end
    end

  -- object
  elseif this.buttonType == "O" then
    if items[id]["O"] then
      GameTooltip:SetText(RaijinQuest_Loc["Looted from"], .3, 1, .8)
      for objectID, chance in pairs(items[id]["O"]) do
        count = count + 1
        if count > tooltip_limit then
          skip = true
        end
        if objects[objectID] and not skip then
          local name = RaijinQuestDB.objects.loc[objectID] or objectID
          local zone = nil
          if objects[objectID].coords and objects[objectID].coords[1] then
            zone = objects[objectID].coords[1][3]
          end
          GameTooltip:AddDoubleLine(name, ( zone and RaijinQuestMap:GetMapNameByID(zone) or UNKNOWN), 1,1,1, .5,.5,.5)
        end
      end

      -- reference tables
      if items[id]["R"] then
        for ref, chance in pairs(items[id]["R"]) do
          if refloot[ref] and refloot[ref]["O"] then
            for unit in pairs(refloot[ref]["O"]) do
              count = count + 1
              if count > tooltip_limit then
                skip = true
              end
              if objects[unit] and not skip then
                local name = RaijinQuestDB.objects.loc[unit]
                local zone = nil
                if objects[unit].coords and objects[unit].coords[1] then
                  zone = objects[unit].coords[1][3]
                end
                GameTooltip:AddDoubleLine(name, ( zone and RaijinQuestMap:GetMapNameByID(zone) or UNKNOWN), 1,1,1, .5,.5,.5)
              end
            end
          end
        end
      end
    end

  -- vendor
  elseif this.buttonType == "V" then
    if items[id]["V"] then
      GameTooltip:SetText(RaijinQuest_Loc["Sold by"], .3, 1, .8)
      for unitID, sellcount in pairs(items[id]["V"]) do
        count = count + 1
        if count > tooltip_limit then
          skip = true
        end
        if units[unitID] and not skip then
          local name = RaijinQuestDB.units.loc[unitID]
          if sellcount ~= 0 then name = name .. " (" .. sellcount .. ")" end
          local zone = units[unitID].coords and units[unitID].coords[1] and units[unitID].coords[1][3]
          GameTooltip:AddDoubleLine(name, ( zone and RaijinQuestMap:GetMapNameByID(zone) or UNKNOWN), 1,1,1, .5,.5,.5)
        end
      end
    end
  end

  if count > tooltip_limit then
    GameTooltip:AddLine("\n" .. RaijinQuest_Loc["and"] .. " " .. (count - tooltip_limit).." " .. RaijinQuest_Loc["others"],.8,.8,.8)
  end
  GameTooltip:Show()
end

local function ResultButtonLeaveSpecial()
  GameTooltip:Hide()
end

local function ResultButtonReload(self)
  self.idText:SetText("ID: " .. self.id)

  if RaijinQuest_config.showids == "1" then
    self.idText:Show()
  else
    self.idText:Hide()
  end

  self.itemColor = nil

  -- update faction
  if self.btype ~= "items" then
    self.factionA:Hide()
    self.factionH:Hide()

    local raceMask = RaijinQuestDatabase:GetRaceMaskByID(self.id, self.btype)
    if (bit.band(77, raceMask) > 0)  or (raceMask == 0 and self.btype == "quests") then
      self.factionA:Show()
    end
    if (bit.band(178, raceMask) > 0)  or (raceMask == 0 and self.btype == "quests") then
      self.factionH:Show()
    end
  end

  -- activate fav buttons if needed
  if RaijinQuestBrowser_fav and RaijinQuestBrowser_fav[self.btype] and RaijinQuestBrowser_fav[self.btype][self.id] then
    self.fav.icon:SetVertexColor(1,1,1,1)
  else
    self.fav.icon:SetVertexColor(1,1,1,.1)
  end

  -- actions by search type
  if self.btype == "quests" then
    self.name = RaijinQuestDB[self.btype]["loc"][self.id]["T"]
    self.text:SetText("|cffffcc00|Hquest:0:0:0:0|h[" .. self.name .. "]|h|r")
  elseif self.btype == "units" or self.btype == "objects" then
    local level = RaijinQuestDB[self.btype]["data"][self.id] and RaijinQuestDB[self.btype]["data"][self.id]["lvl"] or ""
    if level and level ~= "" then level = " (" .. level .. ")" end
    self.text:SetText(self.name .. "|cffaaaaaa" .. level)

    if RaijinQuestDB[self.btype]["data"][self.id] and RaijinQuestDB[self.btype]["data"][self.id]["coords"] then
      self.text:SetTextColor(1,1,1)
    else
      self.text:SetTextColor(.5,.5,.5)
    end
  elseif self.btype == "items" then
    for _, key in ipairs({"U","O","V"}) do
      if items[self.id] and items[self.id][key] then
        self[key]:Show()
      else
        self[key]:Hide()
      end
    end

    self.text:SetText("|cffff5555[?] |cffffffff" .. self.name)

    self.refreshCount = 0
    self:SetScript("OnUpdate", ResultButtonUpdate)
  end

  self.text:SetWidth(self.text:GetStringWidth())
  self:Show()
end

local function ResultButtonCreate(i, resultType)
  local f = CreateFrame("Button", nil, RaijinQuestBrowser.tabs[resultType].list)
  f:SetPoint("TOPLEFT", RaijinQuestBrowser.tabs[resultType].list, "TOPLEFT", 10, -i*30 + 5)
  f:SetPoint("BOTTOMRIGHT", RaijinQuestBrowser.tabs[resultType].list, "TOPRIGHT", 10, -i*30 - 15)
  f:Hide()
  f:SetID(i)

  f.btype = resultType
  f.rqResultButton = true

  f.tex = f:CreateTexture("BACKGROUND")
  f.tex:SetAllPoints(f)
  f.tex:SetTexture(1,1,1, ( compat.mod(i,2) == 1 and .02 or .04))

  -- text properties
  f.text = f:CreateFontString("Caption", "LOW", "GameFontWhite")
  f.text:SetFont(pfUI.font_default, pfUI_config.global.font_size, "OUTLINE")
  f.text:SetAllPoints(f)
  f.text:SetJustifyH("CENTER")
  f.idText = f:CreateFontString("ID", "LOW", "GameFontDisable")
  f.idText:SetPoint("LEFT", f, "LEFT", 30, 0)

  -- favourite button
  f.fav = CreateFrame("Button", nil, f)
  f.fav:SetHitRectInsets(-3,-3,-3,-3)
  f.fav:SetPoint("LEFT", 0, 0)
  f.fav:SetWidth(16)
  f.fav:SetHeight(16)
  f.fav.icon = f.fav:CreateTexture("OVERLAY")
  f.fav.icon:SetTexture(RaijinQuestConfig.path.."\\img\\fav")
  f.fav.icon:SetAllPoints(f.fav)

  -- faction icons
  if resultType ~= "items" then
    f.factionA = f:CreateTexture("OVERLAY")
    f.factionA:SetTexture(RaijinQuestConfig.path.."\\img\\icon_alliance")
    f.factionA:SetWidth(16)
    f.factionA:SetHeight(16)
    f.factionA:SetPoint("RIGHT", -5, 0)
    f.factionH = f:CreateTexture("OVERLAY")
    f.factionH:SetTexture(RaijinQuestConfig.path.."\\img\\icon_horde")
    f.factionH:SetWidth(16)
    f.factionH:SetHeight(16)
    f.factionH:SetPoint("RIGHT", -24, 0)
  end

  -- drop, loot, vendor buttons
  if resultType == "items" then
    local buttons = {
      ["U"] = { ["offset"] = -5,  ["icon"] = "icon_npc",    ["parameter"] = "id",   },
      ["O"] = { ["offset"] = -24, ["icon"] = "icon_object", ["parameter"] = "id",   },
      ["V"] = { ["offset"] = -43, ["icon"] = "icon_vendor", ["parameter"] = "name", },
    }

    for button, settings in pairs(buttons) do
      f[button] = CreateFrame("Button", nil, f)
      f[button]:SetHitRectInsets(-3,-3,-3,-3)
      f[button]:SetPoint("RIGHT", settings.offset, 0)
      f[button]:SetWidth(16)
      f[button]:SetHeight(16)

      f[button].buttonType = button
      f[button].parameter = settings.parameter

      f[button].icon = f[button]:CreateTexture("OVERLAY")
      f[button].icon:SetAllPoints(f[button])
      f[button].icon:SetTexture(RaijinQuestConfig.path.."\\img\\"..settings.icon)

      f[button]:SetScript("OnEnter", ResultButtonEnterSpecial)
      f[button]:SetScript("OnLeave", ResultButtonLeaveSpecial)
      f[button]:SetScript("OnClick", ResultButtonClickSpecial)
    end
  end

  -- bind functions
  f.Reload = ResultButtonReload
  f:SetScript("OnLeave", ResultButtonLeave)
  f:SetScript("OnEnter", ResultButtonEnter)
  f:SetScript("OnClick", ResultButtonClick)
  f.fav:SetScript("OnClick", ResultButtonClickFav)

  return f
end

local function SelectView(view)
  for id, frame in pairs(RaijinQuestBrowser.tabs) do
    pfUI.api.SetButtonFontColor(frame.button, 1,1,1,.7)
    frame:Hide()
  end
  pfUI.api.SetButtonFontColor(view.button, .2,1,.8,1)
  view.button:Hide()
  view.button:Show()
  view:Show()
end

-- sets the browser result values when they change
local function RefreshView(i, key, caption)
  RaijinQuestBrowser.tabs[key].list:Hide()
  RaijinQuestBrowser.tabs[key].list:SetHeight(i * 30 )
  RaijinQuestBrowser.tabs[key].list:Show()
  RaijinQuestBrowser.tabs[key].list:GetParent():SetScrollChild(RaijinQuestBrowser.tabs[key].list)
  RaijinQuestBrowser.tabs[key].list:GetParent():SetVerticalScroll(0)

  if not RaijinQuestBrowser.tabs[key].list.warn then
    RaijinQuestBrowser.tabs[key].list.warn = RaijinQuestBrowser.tabs[key].list:CreateFontString("Caption", "LOW", "GameFontWhite")
    RaijinQuestBrowser.tabs[key].list.warn:SetTextColor(1,.2,.2,1)
    RaijinQuestBrowser.tabs[key].list.warn:SetJustifyH("CENTER")
    RaijinQuestBrowser.tabs[key].list.warn:SetPoint("TOP", 5, -5)
    RaijinQuestBrowser.tabs[key].list.warn:SetText("!! |cffffffff" .. RaijinQuest_Loc["Too many entries. Results shown"] .. ": " .. search_limit .. "|r !!")
  end

  if i >= search_limit then
    RaijinQuestBrowser.tabs[key].list.warn:Show()
  else
    RaijinQuestBrowser.tabs[key].list.warn:Hide()
  end

  RaijinQuestBrowser.tabs[key].button:SetText(RaijinQuest_Loc[caption] .. " " .. "|cffaaaaaa(" .. (i >= search_limit and "*" or i) .. ")")
  for j=i+1, table.getn(RaijinQuestBrowser.tabs[key].buttons) do
    if RaijinQuestBrowser.tabs[key].buttons[j] then
      RaijinQuestBrowser.tabs[key].buttons[j]:Hide()
      RaijinQuestBrowser.tabs[key].buttons[j].id = nil
      RaijinQuestBrowser.tabs[key].buttons[j].name = nil
    end
  end
end

-- sets up all the browse windows and their activation buttons
local function CreateBrowseWindow(fname, name, parent, anchor, x, y)
  if not parent.tabs then parent.tabs = {} end
  parent.tabs[fname] = pfUI.api.CreateScrollFrame(name, parent)
  parent.tabs[fname]:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -65)
  parent.tabs[fname]:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 45)
  parent.tabs[fname]:Hide()
  parent.tabs[fname].buttons = { }

  parent.tabs[fname].backdrop = CreateFrame("Frame", name .. "Backdrop", parent.tabs[fname])
  parent.tabs[fname].backdrop:SetFrameLevel(1)
  parent.tabs[fname].backdrop:SetPoint("TOPLEFT", parent.tabs[fname], "TOPLEFT", -5, 5)
  parent.tabs[fname].backdrop:SetPoint("BOTTOMRIGHT", parent.tabs[fname], "BOTTOMRIGHT", 5, -5)
  pfUI.api.CreateBackdrop(parent.tabs[fname].backdrop, nil, true)

  parent.tabs[fname].button = CreateFrame("Button", name .. "Button", parent)
  parent.tabs[fname].button:SetPoint(anchor, x, y)
  parent.tabs[fname].button:SetWidth(153)
  parent.tabs[fname].button:SetHeight(30)
  parent.tabs[fname].button:SetScript("OnClick", function()
    SelectView(parent.tabs[fname])
  end)

  if fname == "units" then
    EnableTooltips(parent.tabs[fname].button, {
      RaijinQuest_Loc["Units"],
      RaijinQuest_Loc["Display related creatures and NPCs"],
    })
  elseif fname == "objects" then
    EnableTooltips(parent.tabs[fname].button, {
      RaijinQuest_Loc["Objects"],
      RaijinQuest_Loc["Display related objects like ores, herbs, chests, etc."],
    })
  elseif fname == "items" then
    EnableTooltips(parent.tabs[fname].button, {
      RaijinQuest_Loc["Items"],
      RaijinQuest_Loc["Display related items"],
    })
  elseif fname == "quests" then
    EnableTooltips(parent.tabs[fname].button, {
      RaijinQuest_Loc["Quests"],
      RaijinQuest_Loc["Display related quests"],
    })
  end

  pfUI.api.SkinButton(parent.tabs[fname].button)
  parent.tabs[fname].list = pfUI.api.CreateScrollChild(name .. "Scroll", parent.tabs[fname])
  parent.tabs[fname].list:SetWidth(600)
end

-- minimap icon
RaijinQuestBrowserIcon = CreateFrame('Button', "RaijinQuestBrowserIcon", Minimap)
RaijinQuestBrowserIcon:SetClampedToScreen(true)
RaijinQuestBrowserIcon:SetMovable(true)
RaijinQuestBrowserIcon:EnableMouse(true)
RaijinQuestBrowserIcon:RegisterForDrag('LeftButton')
RaijinQuestBrowserIcon:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
RaijinQuestBrowserIcon:SetScript("OnDragStart", function()
  if IsShiftKeyDown() then
    this:StartMoving()
  end
end)
RaijinQuestBrowserIcon:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
RaijinQuestBrowserIcon:SetScript("OnClick", function()
  if arg1 == "RightButton" then
    if RaijinQuestConfig:IsShown() then RaijinQuestConfig:Hide() else RaijinQuestConfig:Show() end
  else
    if RaijinQuestBrowser:IsShown() then RaijinQuestBrowser:Hide() else RaijinQuestBrowser:Show() end
  end
end)

RaijinQuestBrowserIcon:SetScript("OnEnter", function()
  GameTooltip:SetOwner(this, ANCHOR_BOTTOMLEFT)
  GameTooltip:SetText("RaijinQuest")
  GameTooltip:AddDoubleLine(RaijinQuest_Loc["Left-Click"], RaijinQuest_Loc["Open Browser"], 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine(RaijinQuest_Loc["Right-Click"], RaijinQuest_Loc["Open Configuration"], 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine(RaijinQuest_Loc["Shift-Click"], RaijinQuest_Loc["Move Button"], 1, 1, 1, 1, 1, 1)
  GameTooltip:Show()
end)

RaijinQuestBrowserIcon:SetScript("OnLeave", function()
  GameTooltip:Hide()
end)

RaijinQuestBrowserIcon:SetWidth(31)
RaijinQuestBrowserIcon:SetHeight(31)
RaijinQuestBrowserIcon:SetFrameLevel(9)
RaijinQuestBrowserIcon:SetHighlightTexture('Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight')
RaijinQuestBrowserIcon:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)

RaijinQuestBrowserIcon.overlay = RaijinQuestBrowserIcon:CreateTexture(nil, 'OVERLAY')
RaijinQuestBrowserIcon.overlay:SetWidth(53)
RaijinQuestBrowserIcon.overlay:SetHeight(53)
RaijinQuestBrowserIcon.overlay:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder')
RaijinQuestBrowserIcon.overlay:SetPoint('TOPLEFT', 0,0)

RaijinQuestBrowserIcon.icon = RaijinQuestBrowserIcon:CreateTexture(nil, 'BACKGROUND')
RaijinQuestBrowserIcon.icon:SetWidth(20)
RaijinQuestBrowserIcon.icon:SetHeight(20)
RaijinQuestBrowserIcon.icon:SetTexture(RaijinQuestConfig.path..'\\img\\logo')
RaijinQuestBrowserIcon.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
RaijinQuestBrowserIcon.icon:SetPoint('CENTER',1,1)

-- browser window
RaijinQuestBrowser = CreateFrame("Frame", "RaijinQuestBrowser", UIParent)
RaijinQuestBrowser:Hide()
RaijinQuestBrowser:SetWidth(640)
RaijinQuestBrowser:SetHeight(480)
RaijinQuestBrowser:SetPoint("CENTER", 0, 0)
RaijinQuestBrowser:SetFrameStrata("FULLSCREEN_DIALOG")
RaijinQuestBrowser:SetMovable(true)
RaijinQuestBrowser:EnableMouse(true)
RaijinQuestBrowser:RegisterEvent("PLAYER_ENTERING_WORLD")
RaijinQuestBrowser:SetScript("OnEvent", function()
  -- show all favorites on login if configured
  if RaijinQuest_config.favonlogin == "1" then
    -- search units
    for id, name in pairs(RaijinQuestBrowser_fav.units) do
      RaijinQuestDatabase:SearchMobID(id)
    end

    -- search objects
    for id, name in pairs(RaijinQuestBrowser_fav.objects) do
      RaijinQuestDatabase:SearchObjectID(id)
    end

    -- search items
    for id, name in pairs(RaijinQuestBrowser_fav.items) do
      RaijinQuestDatabase:SearchItemID(id)
    end

    -- search quests
    for id, name in pairs(RaijinQuestBrowser_fav.quests) do
      RaijinQuestDatabase:SearchQuestID(id)
    end
  end
end)
RaijinQuestBrowser:SetScript("OnMouseDown",function()
  this:StartMoving()
end)

RaijinQuestBrowser:SetScript("OnMouseUp",function()
  this:StopMovingOrSizing()
end)

RaijinQuestBrowser:SetScript("OnUpdate", function()
  -- multi-select handling
  if not this.selectState and IsControlKeyDown() and GetMouseFocus() and GetMouseFocus().rqResultButton then
    for id, frame in pairs(RaijinQuestBrowser.tabs) do
      for id, button in pairs(frame.buttons) do
        if button.name == GetMouseFocus().name then
          button.tex:SetTexture(.3,1,.8,.4)
        end
      end
    end
    this.selectState = "active"

  elseif this.selectState and (this.selectState == "clean" or not IsControlKeyDown()) then
    for id, frame in pairs(RaijinQuestBrowser.tabs) do
      for id, button in pairs(frame.buttons) do
        if compat.mod(button:GetID(),2) == 1 then
          button.tex:SetTexture(1,1,1,.02)
        else
          button.tex:SetTexture(1,1,1,.04)
        end
      end
    end
    this.selectState = nil
  end
end)

pfUI.api.CreateBackdrop(RaijinQuestBrowser, nil, true, 0.75)
table.insert(UISpecialFrames, "RaijinQuestBrowser")

RaijinQuestBrowser.title = RaijinQuestBrowser:CreateFontString("Status", "LOW", "GameFontNormal")
RaijinQuestBrowser.title:SetFontObject(GameFontWhite)
RaijinQuestBrowser.title:SetPoint("TOP", RaijinQuestBrowser, "TOP", 0, -8)
RaijinQuestBrowser.title:SetJustifyH("LEFT")
RaijinQuestBrowser.title:SetFont(pfUI.font_default, 14)
RaijinQuestBrowser.title:SetText("|cff33ffccpf|rQuest")

RaijinQuestBrowser.close = CreateFrame("Button", "RaijinQuestBrowserClose", RaijinQuestBrowser)
RaijinQuestBrowser.close:SetPoint("TOPRIGHT", -5, -5)
RaijinQuestBrowser.close:SetHeight(20)
RaijinQuestBrowser.close:SetWidth(20)
RaijinQuestBrowser.close.texture = RaijinQuestBrowser.close:CreateTexture("RaijinQuestionDialogCloseTex")
RaijinQuestBrowser.close.texture:SetTexture(RaijinQuestConfig.path.."\\compat\\close")
RaijinQuestBrowser.close.texture:ClearAllPoints()
RaijinQuestBrowser.close.texture:SetVertexColor(1,.25,.25,1)
RaijinQuestBrowser.close.texture:SetPoint("TOPLEFT", RaijinQuestBrowser.close, "TOPLEFT", 4, -4)
RaijinQuestBrowser.close.texture:SetPoint("BOTTOMRIGHT", RaijinQuestBrowser.close, "BOTTOMRIGHT", -4, 4)
RaijinQuestBrowser.close:SetScript("OnClick", function()
  this:GetParent():Hide()
end)
EnableTooltips(RaijinQuestBrowser.close, {
  RaijinQuest_Loc["Close"],
  RaijinQuest_Loc["Hide browser window"],
})
pfUI.api.SkinButton(RaijinQuestBrowser.close, 1, .5, .5)

RaijinQuestBrowser.journal = CreateFrame("Button", "RaijinQuestJournalOpen", RaijinQuestBrowser)
RaijinQuestBrowser.journal:SetPoint("TOPRIGHT", -30, -5)
RaijinQuestBrowser.journal:SetHeight(20)
RaijinQuestBrowser.journal:SetWidth(20)
RaijinQuestBrowser.journal.texture = RaijinQuestBrowser.journal:CreateTexture("RaijinQuestionDialogCloseTex")
RaijinQuestBrowser.journal.texture:SetTexture(RaijinQuestConfig.path.."\\img\\tracker_quests")
RaijinQuestBrowser.journal.texture:ClearAllPoints()
RaijinQuestBrowser.journal.texture:SetPoint("TOPLEFT", RaijinQuestBrowser.journal, "TOPLEFT", 2, -2)
RaijinQuestBrowser.journal.texture:SetPoint("BOTTOMRIGHT", RaijinQuestBrowser.journal, "BOTTOMRIGHT", -2, 2)
RaijinQuestBrowser.journal:SetScript("OnClick", function()
  if RaijinQuestJournal:IsShown() then RaijinQuestJournal:Hide() else RaijinQuestJournal:Show() end
end)
EnableTooltips(RaijinQuestBrowser.journal, {
  RaijinQuest_Loc["Journal"],
  RaijinQuest_Loc["Toggle completed quest browser"],
})
pfUI.api.SkinButton(RaijinQuestBrowser.journal)

RaijinQuestBrowser.clean = CreateFrame("Button", "RaijinQuestBrowserClean", RaijinQuestBrowser)
RaijinQuestBrowser.clean:SetPoint("TOPRIGHT", RaijinQuestBrowser, "TOPRIGHT", -5, -30)
RaijinQuestBrowser.clean:SetPoint("BOTTOMRIGHT", RaijinQuestBrowser, "TOPRIGHT", 0, -55)
RaijinQuestBrowser.clean:SetScript("OnClick", function()
  RaijinQuestMap:DeleteNode("PFDB")
  RaijinQuestMap:UpdateNodes()
end)
RaijinQuestBrowser.clean.text = RaijinQuestBrowser.clean:CreateFontString("Caption", "LOW", "GameFontWhite")
RaijinQuestBrowser.clean.text:SetAllPoints(RaijinQuestBrowser.clean)
RaijinQuestBrowser.clean.text:SetFont(pfUI.font_default, pfUI_config.global.font_size, "OUTLINE")
RaijinQuestBrowser.clean.text:SetText(RaijinQuest_Loc["Clean Map"])
local width = RaijinQuestBrowser.clean.text:GetStringWidth() > 90 and RaijinQuestBrowser.clean.text:GetStringWidth() + 20 or 90
RaijinQuestBrowser.clean:SetWidth(width)
EnableTooltips(RaijinQuestBrowser.clean, {
  RaijinQuest_Loc["Clean Map"],
  RaijinQuest_Loc["Remove all manually searched objects from the map"],
})
pfUI.api.SkinButton(RaijinQuestBrowser.clean)

CreateBrowseWindow("units", "RaijinQuestBrowserUnits", RaijinQuestBrowser, "BOTTOMLEFT", 5, 5)
CreateBrowseWindow("objects", "RaijinQuestBrowserObjects", RaijinQuestBrowser, "BOTTOMLEFT", 164, 5)
CreateBrowseWindow("items", "RaijinQuestBrowserItems", RaijinQuestBrowser, "BOTTOMRIGHT", -164, 5)
CreateBrowseWindow("quests", "RaijinQuestBrowserQuests", RaijinQuestBrowser, "BOTTOMRIGHT", -5, 5)

SelectView(RaijinQuestBrowser.tabs["units"])

RaijinQuestBrowser.input = CreateFrame("EditBox", "RaijinQuestBrowserSearch", RaijinQuestBrowser)
RaijinQuestBrowser.input:SetFont(pfUI.font_default, pfUI_config.global.font_size, "OUTLINE")
RaijinQuestBrowser.input:SetFontObject("GameFontDisable")
RaijinQuestBrowser.input:SetAutoFocus(false)
RaijinQuestBrowser.input:SetText(RaijinQuest_Loc["Search"])
RaijinQuestBrowser.input:SetJustifyH("LEFT")
RaijinQuestBrowser.input:SetPoint("TOPLEFT", RaijinQuestBrowser, "TOPLEFT", 5, -30)
RaijinQuestBrowser.input:SetPoint("BOTTOMRIGHT", RaijinQuestBrowser.clean, "BOTTOMLEFT", -5, 0)
RaijinQuestBrowser.input:SetTextInsets(24,12,4,4)

RaijinQuestBrowser.input.searchIcon = RaijinQuestBrowser.input:CreateTexture("$parentSearchIcon", "OVERLAY")
RaijinQuestBrowser.input.searchIcon:SetTexture(RaijinQuestConfig.path.."\\img\\tracker_search")
RaijinQuestBrowser.input.searchIcon:SetHeight(14)
RaijinQuestBrowser.input.searchIcon:SetWidth(14)
RaijinQuestBrowser.input.searchIcon:SetVertexColor(0.6, 0.6, 0.6)
RaijinQuestBrowser.input.searchIcon:SetPoint("LEFT", RaijinQuestBrowser.input, "LEFT", 6, 0)

RaijinQuestBrowser.input.clearButton = CreateFrame("Button", "$parentClearButton", RaijinQuestBrowser.input)
RaijinQuestBrowser.input.clearButton:Hide()
RaijinQuestBrowser.input.clearButton:SetHeight(17)
RaijinQuestBrowser.input.clearButton:SetWidth(17)
RaijinQuestBrowser.input.clearButton:SetPoint("RIGHT", RaijinQuestBrowser.input, "RIGHT", -3, 0)
RaijinQuestBrowser.input.clearButton.texture = RaijinQuestBrowser.input.clearButton:CreateTexture(nil, "ARTWORK")
RaijinQuestBrowser.input.clearButton.texture:SetTexture(RaijinQuestConfig.path.."\\img\\tracker_close")
RaijinQuestBrowser.input.clearButton.texture:SetHeight(17)
RaijinQuestBrowser.input.clearButton.texture:SetWidth(17)
RaijinQuestBrowser.input.clearButton.texture:SetAlpha(0.5)
RaijinQuestBrowser.input.clearButton.texture:SetPoint("TOPLEFT", RaijinQuestBrowser.input.clearButton, "TOPLEFT", 0, 0)
RaijinQuestBrowser.input.clearButton:SetScript("OnEnter", function()
  this.texture:SetAlpha(1.0)
end)
RaijinQuestBrowser.input.clearButton:SetScript("OnLeave", function()
  this.texture:SetAlpha(0.5)
end)
RaijinQuestBrowser.input.clearButton:SetScript("OnMouseDown", function()
  if this:IsEnabled() then
    this.texture:SetPoint("TOPLEFT", this, "TOPLEFT", 1, -1)
  end
end)
RaijinQuestBrowser.input.clearButton:SetScript("OnMouseUp", function()
  this.texture:SetPoint("TOPLEFT", this, "TOPLEFT", 0, 0)
end)
RaijinQuestBrowser.input.clearButton:SetScript("OnClick", function()
  PlaySound("igMainMenuOptionCheckBoxOn")
  RaijinQuestBrowser.input:SetText("")
  --[[
  If there is no focus, then the ClearFocus() method does not call the OnEditFocusLost script.
  In 1.12, there is no HasFocus() method, so there is no way to check for focus. therefore,
  for ease of implementation and to avoid double calling the OnEditFocusLost script, I use the
  SetFocus() method to accurately ensure that the OnEditFocusLost script is called.
  --]]
  RaijinQuestBrowser.input:SetFocus()
  RaijinQuestBrowser.input:ClearFocus()
end)

RaijinQuestBrowser.input:SetScript("OnEscapePressed", function() this:ClearFocus() end)
RaijinQuestBrowser.input:SetScript("OnEnterPressed", function() this:ClearFocus() end)
RaijinQuestBrowser.input:SetScript("OnEditFocusGained", function()
  this:HighlightText()
  this:SetFontObject("GameFontWhite")
  this.searchIcon:SetVertexColor(1.0, 1.0, 1.0)
  if this:GetText() == RaijinQuest_Loc["Search"] then this:SetText("") end
  this.clearButton:Show()
end)

RaijinQuestBrowser.input:SetScript("OnEditFocusLost", function()
  this:HighlightText(0, 0)
  this:SetFontObject("GameFontDisable")
  this.searchIcon:SetVertexColor(0.6, 0.6, 0.6)
  if this:GetText() == "" then
    this:SetText(RaijinQuest_Loc["Search"])
    this.clearButton:Hide()
  end
end)

-- This script updates all the search tabs when the search text changes
RaijinQuestBrowser.input:SetScript("OnTextChanged", function()
  local text = this:GetText()
  if (text == RaijinQuest_Loc["Search"]) then text = "" end

  local custom = string.find(text, "^custom:")
  text = string.gsub(text, "^custom:", "")

  for _, caption in ipairs({"Units","Objects","Items","Quests"}) do
    local searchType = strlower(caption)

    local data = (strlen(text) >= 3 or custom) and RaijinQuestDatabase:GetIDByName(text, searchType, true, custom) or RaijinQuestBrowser_fav[searchType]

    local i = 0
    for id, text in pairs(data) do
      i = i + 1

      if i >= search_limit then break end
      RaijinQuestBrowser.tabs[searchType].buttons[i] = RaijinQuestBrowser.tabs[searchType].buttons[i] or ResultButtonCreate(i, searchType)
      RaijinQuestBrowser.tabs[searchType].buttons[i].id = id
      RaijinQuestBrowser.tabs[searchType].buttons[i].name = text
      RaijinQuestBrowser.tabs[searchType].buttons[i]:Reload()
    end

    RefreshView(i, searchType, caption)
  end
end)

pfUI.api.CreateBackdrop(RaijinQuestBrowser.input, nil, true)
