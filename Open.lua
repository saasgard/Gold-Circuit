local ADDON, ns = ...

--[[
  Pop-up for opening caches and bags.

  Lists every openable item in your bags (the game marks them "has loot"),
  the Gold Circuit weekly caches first. Each row is a secure button: a
  click uses that item, one per click (the game allows no "open all").
  It pops up when something openable lands in your bags (Setup can turn
  that off), closes itself when nothing is left, and can be opened with
  /gc open or the dashboard's Caches button.

  Secure buttons can't be shown, moved or hidden in combat, so the rows
  are parented to UIParent and the whole pop-up hides when combat starts;
  it comes back afterwards.
]]

local Op = {}
ns.Opener = Op

local St = ns.Style
local WIDTH, ROW, MAX_ROWS = 300, 22, 14
local GREY, GOLD = "|cff888888", "|cffffd100"

local function S() return ns.DB.settings.opener end
local function InCombat() return InCombatLockdown and InCombatLockdown() end

-- Backpack, the bags and the reagent bag.
local function Bags()
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  local t = {}
  for b = 0, last do t[#t + 1] = b end
  return t
end

-- Openable items in your bags, one entry per item (stacks and copies
-- added up): { itemID, bag, slot, count, icon, name, quality, act }.
function Op.Scan()
  local list, byID = {}, {}
  if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return list end
  local ignore = S().ignore
  for _, bag in ipairs(Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      local id = info and info.hasLoot and info.itemID
      if id and not ignore[id] then
        local e = byID[id]
        if e then
          e.count = e.count + (info.stackCount or 1)
        else
          local name = info.itemName or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
          e = { itemID = id, bag = bag, slot = slot, count = info.stackCount or 1, icon = info.iconFileID,
            name = name, quality = info.quality, act = ns.ActivityForCacheID(id) or ns.ActivityForCache(name) }
          byID[id] = e
          list[#list + 1] = e
        end
      end
    end
  end
  -- Gold Circuit's own caches first, then by name
  table.sort(list, function(a, b)
    if (a.act ~= nil) ~= (b.act ~= nil) then return a.act ~= nil end
    return a.name < b.name
  end)
  return list
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
function Op:Create()
  if self.frame then return end
  local s = S()
  local f = St.MovableWindow({
    name = "GoldCircuitOpenFrame", title = "Open caches & bags", w = WIDTH, h = 80,
    strata = "DIALOG", -- above the dashboard (it can be opened from there)
    posTable = s, posKey = "pos", default = { "CENTER", "CENTER", 0, 160 },
    onClose = function() Op:Close() end, escape = true,
  })
  self.frame = f

  self.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.more:SetJustifyH("LEFT")
  self.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetPoint("BOTTOMLEFT", 10, 7)
  self.hint:SetWidth(WIDTH - 20)
  self.hint:SetJustifyH("LEFT")
  self.hint:SetText("Click: open one   Right-click: never show this item")

  f:Hide()
  f:HookScript("OnHide", function()
    if not InCombat() then Op:HideRows(0) end
    if ns.Refresh then ns.Refresh() end -- the dashboard's Caches button
  end)
  f:HookScript("OnShow", function() if ns.Refresh then ns.Refresh() end end)
  self.rows = {}

  -- don't pop up for what's already in the bags at login
  C_Timer.After(5, function() Op.ready = true; Op.OnBagsChanged() end)
end

local function RowTooltip(r)
  if not r.bag then return end
  GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
  GameTooltip:SetBagItem(r.bag, r.slot)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click: open one   Right-click: never show this item here", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

function Op:Row(i)
  local r = self.rows[i]
  if r then return r end
  r = CreateFrame("Button", "GoldCircuitOpenRow" .. i, UIParent, "SecureActionButtonTemplate")
  r:SetSize(WIDTH - 16, ROW)
  r:RegisterForClicks("AnyUp", "AnyDown")
  r:SetAttribute("type1", "item") -- left-click uses the item; right-click does nothing secure
  r:Hide()
  local bg = r:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, i % 2 == 0 and St.STRIPE_A or 0)
  local hl = r:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(St.HOVER[1], St.HOVER[2], St.HOVER[3], St.HOVER[4])
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(18, 18)
  r.icon:SetPoint("LEFT", 3, 0)
  r.open = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  r.open:SetPoint("RIGHT", -6, 0)
  r.open:SetText(GOLD .. "Open|r")
  r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.count:SetPoint("RIGHT", r.open, "LEFT", -10, 0)
  r.count:SetJustifyH("RIGHT")
  r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
  r.name:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
  r.name:SetJustifyH("LEFT")
  r.name:SetWordWrap(false)
  r:SetScript("OnEnter", RowTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:HookScript("OnClick", function(b, button, down)
    if button == "RightButton" and not down and b.itemID then Op:Ignore(b.itemID, b.itemName) end
  end)
  self.rows[i] = r
  return r
end

-- Hides rows from n + 1 on (out of combat only).
function Op:HideRows(n)
  for i = n + 1, #(self.rows or {}) do
    local r = self.rows[i]
    r:Hide()
    r:ClearAllPoints()
    r.bag, r.slot, r.itemID = nil, nil, nil
  end
end

local function QualityHex(q)
  if q and C_Item and C_Item.GetItemQualityColor then
    local _, _, _, hex = C_Item.GetItemQualityColor(q)
    if hex then return "|c" .. hex end
  end
  return "|cffffffff"
end

-- list: an Op.Scan() result just made (saves scanning the bags twice)
function Op:Update(list)
  local f = self.frame
  if not f or InCombat() then return end
  list = list or Op.Scan()
  self.count = #list
  if not f:IsShown() then return end
  if #list == 0 then self:Close(); return end
  local y = St.TITLE_H + 6
  local shown = math.min(#list, MAX_ROWS)
  for i = 1, shown do
    local e, r = list[i], self:Row(i)
    r:SetAttribute("item1", e.bag .. " " .. e.slot)
    r.bag, r.slot, r.itemID, r.itemName = e.bag, e.slot, e.itemID, e.name
    r.icon:SetTexture(e.icon or 134400)
    r.name:SetText(QualityHex(e.quality) .. e.name .. "|r" .. (e.act and (GREY .. "  " .. e.act.name .. "|r") or ""))
    r.count:SetText(e.count > 1 and ("x" .. e.count) or "")
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -y)
    r:SetFrameStrata(f:GetFrameStrata())
    r:SetFrameLevel(f:GetFrameLevel() + 10)
    r:Show()
    y = y + ROW
  end
  self:HideRows(shown)
  if #list > shown then
    self.more:ClearAllPoints()
    self.more:SetPoint("TOPLEFT", 12, -(y + 3))
    self.more:SetText("+" .. (#list - shown) .. " more (shown as you open these)")
    self.more:Show()
    y = y + 16
  else
    self.more:Hide()
  end
  f:SetHeight(y + 26)
end

function Op:Show(list)
  if not self.frame or InCombat() then return end
  self.frame:Show()
  self:Update(list)
end

function Op:Close()
  if self.frame then self.frame:Hide() end
end

-- /gc open and the dashboard button.
function Op:Toggle()
  if not self.frame then return end
  if self.frame:IsShown() then self:Close(); return end
  if InCombat() then ns.Print("Can't open the caches pop-up in combat.") return end
  if #Op.Scan() == 0 then ns.Print("Nothing to open in your bags.") return end
  self:Show()
end

function Op:Ignore(itemID, name)
  S().ignore[itemID] = name or true
  ns.Print(string.format("%s won't be shown in the caches pop-up. Setup > Windows brings it back.", name or ("item " .. itemID)))
  self:Update()
end

function Op:ClearIgnored()
  wipe(S().ignore)
  self:Update()
  ns.Refresh()
end

function Op.IgnoredCount()
  local n = 0
  for _ in pairs(S().ignore) do n = n + 1 end
  return n
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local lastTotal

-- BAG_UPDATE_DELAYED: pops up when more openable items arrived than were
-- there before.
function Op.OnBagsChanged()
  if not (Op.frame and ns.DB) then return end
  if InCombat() then Op.pending = true; return end
  Op.pending = nil
  local list = Op.Scan()
  local total = 0
  for _, e in ipairs(list) do total = total + e.count end
  local grew = Op.ready and lastTotal and total > lastTotal
  if Op.ready then lastTotal = total end
  local before = Op.count
  if grew and S().auto and not Op.frame:IsShown() then
    Op:Show(list)
  else
    Op:Update(list)
  end
  -- the dashboard's "Caches (n)" button; most bag changes (loot, vendoring)
  -- don't change it, so no full refresh for those
  if Op.count ~= before and ns.Refresh then ns.Refresh() end
end

function Op:OnCombat(inCombat)
  if not self.frame then return end
  if inCombat then
    -- PLAYER_REGEN_DISABLED fires just before lockdown: last chance
    if self.frame:IsShown() then self.reopen = true end
    self:HideRows(0)
    self.frame:Hide()
  else
    local reopen = self.reopen
    self.reopen = nil
    if reopen and #Op.Scan() > 0 then self:Show() end
    if self.pending then Op.OnBagsChanged() end
  end
end
