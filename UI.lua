local ADDON, ns = ...
local UI = {}
ns.UI = UI

local W, H = 900, 540
local CW = W - 50
local MINI_W = 300 -- compact tracker

local ICON_DONE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t"
local ICON_TODO = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14|t"
local ICON_LOG  = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14|t"
local GOLD, GREY, GREEN, RED, YELLOW = "|cffffd100", "|cff888888", "|cff33ff66", "|cffff5555", "|cffffee55"

------------------------------------------------------------------------
-- Tiny render pool: font strings, textures and tooltip hot-spots that are
-- recycled every redraw.
------------------------------------------------------------------------
local St = ns.Style

local function NewPool(parent)
  return { parent = parent, fs = {}, nfs = 0, tx = {}, ntx = 0, hb = {}, nhb = 0, ar = {}, nar = 0 }
end

local function Begin(p)
  for i = 1, p.nfs do p.fs[i]:Hide() end
  for i = 1, p.ntx do p.tx[i]:Hide() end
  for i = 1, p.nhb do p.hb[i]:Hide() end
  for i = 1, p.nar do p.ar[i]:Hide() end
  p.nfs, p.ntx, p.nhb, p.nar = 0, 0, 0, 0
end

-- dropdown arrow
local function Arrow(p, x, y)
  p.nar = p.nar + 1
  local a = p.ar[p.nar]
  if not a then
    a = St.Arrow(p.parent)
    p.ar[p.nar] = a
  end
  a:ClearAllPoints()
  a:SetPoint("TOPLEFT", p.parent, "TOPLEFT", x, -y)
  a:Show()
end

local function T(p, x, y, text, w, justify, font)
  p.nfs = p.nfs + 1
  local fs = p.fs[p.nfs]
  if not fs then
    fs = p.parent:CreateFontString(nil, "OVERLAY")
    fs:SetWordWrap(false)
    p.fs[p.nfs] = fs
  end
  fs:SetFontObject(font or GameFontHighlightSmall)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", p.parent, "TOPLEFT", x, -y)
  fs:SetWidth(w or 0)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetText(text or "")
  fs:Show()
  return fs
end

local function R(p, x, y, w, h, r, g, b, a)
  p.ntx = p.ntx + 1
  local t = p.tx[p.ntx]
  if not t then
    t = p.parent:CreateTexture(nil, "BACKGROUND")
    p.tx[p.ntx] = t
  end
  t:ClearAllPoints()
  t:SetPoint("TOPLEFT", p.parent, "TOPLEFT", x, -y)
  t:SetSize(math.max(1, w), math.max(1, h))
  t:SetColorTexture(r, g, b, a or 1)
  t:Show()
  return t
end

local function Hot(p, x, y, w, h, fn, click)
  p.nhb = p.nhb + 1
  local b = p.hb[p.nhb]
  if not b then
    b = CreateFrame("Frame", nil, p.parent)
    b:EnableMouse(true)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(unpack(St.HOVER))
    b:SetScript("OnMouseUp", function(self, button) if self.click then self.click(button, self) end end)
    b:SetScript("OnEnter", function(self)
      if self.hl then self.hl:SetShown(self.click ~= nil) end
      if self.fn then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        self.fn(GameTooltip)
        GameTooltip:Show()
      end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.hb[p.nhb] = b
  end
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", p.parent, "TOPLEFT", x, -y)
  b:SetSize(w, h)
  b.fn, b.click = fn, click
  b:Show()
end

-- Section header: tinted bar with an accent edge (same as the other windows).
local function Header(p, y, text, sub, width)
  local w = width or CW
  local r, g, b, a = St.SectionColors()
  R(p, 0, y, w, 20, r, g, b, a)
  R(p, 0, y, 2, 20, St.ACCENT[1], St.ACCENT[2], St.ACCENT[3], 1)
  local fs = T(p, 10, y + 4, St.SECTION_TEXT .. text .. "|r", nil, nil, GameFontNormal)
  if sub then T(p, 18 + fs:GetStringWidth(), y + 5, GREY .. sub .. "|r", w - 30 - fs:GetStringWidth()) end
  return y + 24
end

-- Every other row, faintly.
local function Stripe(p, x, y, w, h, odd)
  if odd then R(p, x, y, w, h, 1, 1, 1, St.STRIPE_A) end
end

-- Clickable "Label: value v" chip that opens a dropdown menu.
local function Chip(p, x, y, label, value, build)
  local fs = T(p, x + 6, y + 3, GREY .. label .. ":|r " .. value)
  local w = fs:GetStringWidth() + 26
  Arrow(p, x + w - 15, y + 4)
  R(p, x, y, w, 18, 1, 1, 1, 0.07)
  Hot(p, x, y, w, 18, nil, function(_, owner)
    St.Menu(owner, function(_, root) build(root) end)
  end)
  return x + w + 6
end

local function SourceColor(src)
  local c = ns.SOURCE_COLORS[src] or ns.SOURCE_COLORS.Other
  return c[1], c[2], c[3]
end

local function ResetIn(c)
  return ns.Duration((c and c.weekReset or ns.NextReset()) - time())
end

-- Right-click menu for an activity on a character: mark done / not done,
-- extra options for backlog weeklies and events.
function UI.ActivityMenu(owner, key, a)
  if not a then return end
  local c = ns.GetChar(key)
  St.Menu(owner, function(_, root)
    local d, count = ns.ActStatus(c, a)
    root:CreateTitle(a.name .. "  |cff888888" .. (key:match("^([^-]+)") or key) .. "|r")
    if d < count then
      root:CreateButton(count > 1 and string.format("Mark all done (%d/%d)", count, count) or "Mark done",
        function() ns.SetDone(key, a, count) end)
      if count > 1 then
        root:CreateButton(string.format("Mark one done (%d/%d)", d + 1, count), function() ns.SetDone(key, a, d + 1) end)
      end
    end
    if d > 0 then root:CreateButton("Mark not done", function() ns.SetDone(key, a, 0) end) end
    local w = c.weekly[a.key]
    if w and w.manual then
      root:CreateButton("|cff888888Back to automatic detection|r", function()
        w.manual = nil; w.done = 0
        if key == ns.charKey then ns.SnapshotCompletion() end
        ns.Refresh()
      end)
    end
    if a.backlog then
      root:CreateCheckbox(string.format("%d up this week (skipped a week)", a.backlog),
        function() return (ns.Weekly(c, a.key).avail or 0) >= a.backlog end,
        function() local ww = ns.Weekly(c, a.key); ww.avail = (ww.avail or 0) >= a.backlog and nil or a.backlog; ns.Refresh() end)
    end
    if a.schedule then
      local s = ns.ActSet(a)
      root:CreateCheckbox("Remind me 5 min before it starts",
        function() return (s.remind or 0) > 0 end,
        function() s.remind = (s.remind or 0) > 0 and 0 or 5; ns.Refresh() end)
      root:CreateButton("Open the map (Events tab)", function() if ToggleWorldMap then ToggleWorldMap() end end)
    end
    if key == ns.charKey and a.kind ~= "crafting" and a.key ~= "special" then
      root:CreateDivider()
      root:CreateButton("Directions", function() ns.Pickups.Navigate(a) end)
    end
    root:CreateDivider()
    root:CreateButton("|cff888888Stop tracking " .. a.name .. "|r", function() ns.ActSet(a).enabled = false; ns.Refresh() end)
  end, true)
end

-- What clicking a route entry does (Route tab and compact tracker).
function UI.ClickStep(st, button, owner)
  if button == "RightButton" then
    if st.a then UI.ActivityMenu(owner, ns.charKey, st.a)
    elseif st.isWQGroup then ns.WQWindow:Toggle(true) end
    return
  end
  if st.isWQGroup then
    ns.WQWindow:Toggle(true)
  elseif st.a and st.a.key == "special" then
    -- track the first open Special Assignment, the overview is in the World Quest Tracker
    if st.sa and not (ns.WQ.IsSuperTracked(st.sa.qid) or ns.WQ.IsWatched(st.sa.qid)) then ns.WQ.Track(st.sa.qid) end
    ns.WQWindow:Toggle(true)
  elseif st.a and st.a.kind == "crafting" then
    if not UI.frame:IsShown() then UI:Toggle() end
    UI:SelectTab("Orders")
  elseif st.a then
    ns.Pickups.Navigate(st.a)
  end
end

-- Short status for an entry: "in log", "2/3 WQ", "37m", "3 orders"...
function UI.StepStatus(st)
  if st.isWQGroup then
    return st.urgentCount > 0 and (RED .. st.urgentCount .. " expiring|r") or (GREY .. st.count .. " open|r")
  end
  if st.a and st.a.key == "special" then
    local n = st.saOpen and #st.saOpen or 0
    if n == 0 then return GREY .. "none up|r" end
    return (st.saReady > 0 and (GREEN .. st.saReady .. " ready|r" .. GREY .. "/|r") or "") .. YELLOW .. n .. " up|r"
  end
  if st.nextIn then
    return st.eventActive and (GREEN .. "now|r") or ((st.nextIn < 600 and YELLOW or GREY) .. ns.Duration(st.nextIn) .. "|r")
  end
  if st.eventRunning ~= nil and not st.inLog then
    return st.eventRunning and (GREEN .. "running|r") or (GREY .. "not running|r")
  end
  if st.ordersN then return GREY .. st.ordersN .. (st.ordersN == 1 and " order" or " orders") .. "|r" end
  if st.inLog then return GREY .. "in log|r" end
  return ""
end

-- Tooltip for the single "World Quests" route entry.
function UI.WQGroupTooltip(tt, s)
  tt:AddLine("Gold World Quests", 1, 0.82, 0)
  tt:AddDoubleLine(s.count .. " open on this character", ns.Money(s.gold), 0.8, 0.8, 0.8, 1, 1, 1)
  tt:AddLine(" ")
  local now = time()
  for i, q in ipairs(s.list or {}) do
    if i > 8 then
      tt:AddLine(string.format("+%d more", #s.list - 8), 0.6, 0.6, 0.6)
      break
    end
    local left = q.expires and (q.expires - now)
    local urgent = left and left < 4 * 3600
    tt:AddDoubleLine(string.format("%s  |cff888888%s%s|r", q.title or q.qid, q.zone or "?",
      left and ("  · " .. (urgent and "|cffff5555" or "") .. ns.Duration(left)) or ""),
      ns.Money(q.gold), 1, 1, 1, 1, 1, 1)
  end
  tt:AddLine(" ")
  tt:AddLine("Click to open the World Quest Tracker", 0.6, 0.6, 0.6)
end

------------------------------------------------------------------------
-- Main frame
------------------------------------------------------------------------
local TABS = { "Route", "Alts", "Orders", "Cashflow", "Setup" }

function UI:Init()
  if self.frame then return end
  local DB = ns.DB

  local f = CreateFrame("Frame", "GoldCircuitFrame", UIParent, "BackdropTemplate")
  self.frame = f
  f:SetSize(W, H)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(s)
    s:StopMovingOrSizing()
    local point, _, rel, x, y = s:GetPoint()
    DB.settings.framePos = { point, rel, x, y }
  end)
  local pos = DB.settings.framePos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER") end
  St.Window(f)
  f:Hide()
  tinsert(UISpecialFrames, "GoldCircuitFrame")

  St.TitleBar(f, "Gold Circuit")
  local close = St.Close(f)

  self.headerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.headerText:SetPoint("RIGHT", close, "LEFT", -6, 0)
  self.headerText:SetJustifyH("RIGHT")

  -- flat tabs, the selected one lit up
  self.tabButtons = {}
  local x = 8
  for _, name in ipairs(TABS) do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(96, 24)
    b:SetPoint("TOPLEFT", x, -(St.TITLE_H + 6))
    x = x + 100
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.edge = b:CreateTexture(nil, "ARTWORK")
    b.edge:SetPoint("BOTTOMLEFT")
    b.edge:SetPoint("BOTTOMRIGHT")
    b.edge:SetHeight(2)
    b.edge:SetColorTexture(St.ACCENT[1], St.ACCENT[2], St.ACCENT[3], 1)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(name)
    b:SetScript("OnEnter", function(s) if UI.tab ~= name then s.bg:SetColorTexture(1, 1, 1, 0.10) end end)
    b:SetScript("OnLeave", function() UI:StyleTabs() end)
    b:SetScript("OnClick", function() UI:SelectTab(name) end)
    self.tabButtons[name] = b
  end
  St.Line(f, St.TITLE_H + 31)

  local scroll = CreateFrame("ScrollFrame", nil, f)
  scroll:SetPoint("TOPLEFT", 12, -(St.TITLE_H + 38))
  scroll:SetPoint("BOTTOMRIGHT", -28, 12)
  self.scroll = scroll
  self.scrollBar = St.ScrollBar(f, scroll)

  self.panels, self.pools = {}, {}
  for _, name in ipairs(TABS) do
    local panel = CreateFrame("Frame", nil, scroll)
    panel:SetSize(CW, 10)
    panel:Hide()
    self.panels[name] = panel
    self.pools[name] = NewPool(panel)
  end

  local wqBtn = St.Button(f, 140, "World Quest Tracker", function() ns.WQWindow:Toggle() end)
  wqBtn:SetPoint("TOPRIGHT", -10, -(St.TITLE_H + 8))

  self:CreateMini()
  if ns.WQWindow then ns.WQWindow:Create() end
  self:CreateMinimapButton()
  self:SelectTab(DB.settings.lastTab or "Route")
end

function UI:SelectTab(name)
  if not self.panels[name] then name = "Route" end
  ns.DB.settings.lastTab = name
  self.tab = name
  for n, panel in pairs(self.panels) do panel:SetShown(n == name) end
  self:StyleTabs()
  self.scroll:SetScrollChild(self.panels[name])
  self.scroll:SetVerticalScroll(0)
  self:Update()
end

function UI:StyleTabs()
  for n, b in pairs(self.tabButtons) do
    local on = n == self.tab
    b.bg:SetColorTexture(St.GOLD[1], St.GOLD[2], St.GOLD[3], on and 0.18 or 0.04)
    b.edge:SetShown(on)
    b.text:SetTextColor(on and 1 or 0.75, on and 1 or 0.65, on and 1 or 0.4)
  end
end

function UI:Toggle()
  if not self.frame then return end
  self.frame:SetShown(not self.frame:IsShown())
  if self.frame:IsShown() then
    self:Update()
    if ns.WQ then ns.WQ.QueueScan(0.5) end
  end
end

function UI:Update()
  if not self.frame then return end
  -- routes are worked out once for this whole refresh (all windows)
  ns.BeginRefresh()
  self:UpdateAll()
  ns.EndRefresh()
end

function UI:UpdateAll()
  self:UpdateMini()
  if ns.WQWindow then ns.WQWindow:Update() end
  if not self.frame:IsShown() then return end

  -- header summary across all characters
  local earned, left = 0, 0
  for key, c in pairs(ns.DB.chars) do
    earned = earned + ns.WeekIncome(c) - ns.WeekSpend(c)
  end
  for _, q in ipairs(ns.AltQueue()) do left = left + q.gold end
  self.headerText:SetText(string.format("Army net this week: %s   |   Left on the table: %s   |   Reset in %s",
    ns.Money(earned), ns.Money(left), ResetIn(ns.GetChar())))

  local tab = self.tab
  local p = self.pools[tab]
  local h
  if tab == "Route" then h = self:RenderRoute(p)
  elseif tab == "Alts" then h = self:RenderAlts(p)
  elseif tab == "Cashflow" then h = self:RenderCashflow(p)
  elseif tab == "Orders" then h = self:RenderOrders(p)
  elseif tab == "Setup" then h = self:RenderSetup(p) end
  self.panels[tab]:SetHeight(math.max(10, h or 10))
  -- the scroll range updates once the panel's new height is laid out
  if self.scrollBar then C_Timer.After(0, self.scrollBar.Update) end
end

------------------------------------------------------------------------
-- Route tab: the current character
------------------------------------------------------------------------
function UI:RenderRoute(p)
  Begin(p)
  local key = ns.charKey
  local r = ns.BuildRoute(key)
  local c = r.char
  local y = 4

  T(p, 4, y, ns.ColorName(key, c) .. GREY .. "  level " .. (c.level or "?") .. "|r", nil, nil, GameFontNormalLarge)
  y = y + 26
  T(p, 4, y, string.format("Earned this week: %s     Spent: %s     Left to earn: %s  in ~%d min     Session: %s",
    ns.Money(ns.WeekIncome(c)), ns.Money(ns.WeekSpend(c)), ns.Money(r.gold), r.mins, ns.Money(ns.session.net)))
  y = y + 24

  if #r.steps == 0 then
    y = Header(p, y, "Route")
    T(p, 10, y, (c.level or 0) < ns.MIN_LEVEL
      and (GREY .. "Nothing to track below level " .. ns.MIN_LEVEL .. " (this character is " .. (c.level or "?") .. ").|r")
      or (GREEN .. "Everything tracked is done on this character. Log the next alt!|r"), nil, nil, GameFontNormal)
    y = y + 24
  else
    y = Header(p, y, "Optimised route  (grouped by zone, best gold/minute first)")
    T(p, 36, y, GREY .. "Activity|r"); T(p, 330, y, GREY .. "Status|r")
    T(p, 470, y, GREY .. "Est. gold|r", 100, "RIGHT"); T(p, 580, y, GREY .. "Time|r", 60, "RIGHT")
    T(p, 650, y, GREY .. "Gold/min|r", 90, "RIGHT")
    y = y + 18
    local lastZone
    for i, s in ipairs(r.steps) do
      if s.zone ~= lastZone then
        y = y + 2
        -- zone stop: a lighter sub-header under the section
        local zr, zg, zb, za = St.SectionColors()
        R(p, 0, y, CW, 18, zr, zg, zb, za * 0.5)
        T(p, 8, y + 3, GOLD .. s.zone .. "|r" .. GREY .. string.format("   %s/min for this stop", ns.Money(s.zoneGPM)) .. "|r")
        y = y + 20
        lastZone = s.zone
      end
      local status
      Stripe(p, 0, y - 2, CW, 18, i % 2 == 0)
      if s.isWQGroup then
        status = YELLOW .. s.count .. " open|r" ..
          (s.urgentCount > 0 and (RED .. "  · " .. s.urgentCount .. " expiring|r") or "")
      elseif s.a and s.a.key == "special" then
        status = UI.StepStatus(s) .. GREY .. "  (list below)|r"
      elseif s.nextIn then
        status = s.eventActive and (GREEN .. "active now|r") or (GREY .. "next in |r" .. (s.nextIn < 600 and YELLOW or "") .. ns.Duration(s.nextIn) .. "|r")
      elseif s.count > 1 then
        status = string.format("%s %d/%d", s.inLog and ICON_LOG or ICON_TODO, s.done, s.count)
      else
        status = s.inLog and (ICON_LOG .. " in quest log") or (ICON_TODO .. " not started")
      end
      T(p, 14, y, i .. ".", 20, "RIGHT")
      T(p, 40, y, s.name .. ((s.a and s.a.minLevel) and (GREY .. "  " .. s.a.minLevel .. "+|r") or ""), 280)
      T(p, 330, y, status, 140)
      T(p, 470, y, ns.Money(s.gold) .. (s.learned and "" or GREY .. "*|r"), 100, "RIGHT")
      T(p, 580, y, s.mins .. " min", 60, "RIGHT")
      T(p, 650, y, ns.Money(s.gold / math.max(1, s.mins)), 90, "RIGHT")
      local a = s.a
      Hot(p, 0, y - 2, CW, 18, function(tt)
        if s.isWQGroup then UI.WQGroupTooltip(tt, s); return end
        tt:AddLine(a.name, 1, 0.82, 0)
        if a.desc then tt:AddLine(a.desc, 1, 1, 1, true) end
        tt:AddDoubleLine("Zone", ns.ZoneFor(a), 0.7, 0.7, 0.7, 1, 1, 1)
        if s.pickup and not s.inLog then
          local pk = s.pickup
          tt:AddDoubleLine("Pick up at", string.format("%s (%s %.0f, %.0f)", pk.label or pk.zone or "?", pk.zone or "?", pk.mx * 100, pk.my * 100),
            0.7, 0.7, 0.7, 1, 1, 1)
          tt:AddDoubleLine("Location from", ns.Pickups.SourceText(pk), 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
        end
        if s.spot and not s.inLog then
          tt:AddDoubleLine("Now", string.format("%s (%s)", s.spot.name or "?", s.spot.zone or "?"), 0.7, 0.7, 0.7, 1, 1, 1)
          tt:AddDoubleLine("Location from", "the map's Events tab", 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
        end
        if s.a and s.a.kind ~= "crafting" and s.a.key ~= "special" then
          tt:AddLine(s.inLog and "Click to track it." or (s.pickup and "Click for directions to pick it up." or "Pickup location not known yet."), 0.6, 0.6, 0.6)
        end
        if s.saOpen then
          tt:AddLine(" ")
          for _, sa in ipairs(s.saOpen) do
            tt:AddDoubleLine(sa.short ~= "" and sa.short or "Special Assignment",
              (sa.unlocked and "|cff33ff66ready|r" or string.format("%d/%d WQs", sa.have, sa.need)) .. "  |cff888888" .. (sa.zone or "?") .. "|r",
              1, 1, 1, 1, 1, 1)
          end
          tt:AddLine("Click to track the first one; the World Quest Tracker lists them all.", 0.6, 0.6, 0.6, true)
        end
        if s.nextIn then
          tt:AddDoubleLine("Event", s.eventActive and "active now" or ("starts in " .. ns.Duration(s.nextIn)),
            0.7, 0.7, 0.7, s.eventActive and 0.3 or 1, 1, s.eventActive and 0.4 or 1)
          tt:AddDoubleLine("Status from", s.sched and "the map's Events tab" or "the addon's own checks", 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
          if s.sched and s.sched.hasReminder then tt:AddLine("Game reminder is set for the next one.", 0.6, 0.9, 0.6) end
          local rm = ns.ActSet(a).remind or 0
          tt:AddDoubleLine("Addon reminder", rm > 0 and (rm .. " min before") or "off", 0.7, 0.7, 0.7, 1, 1, 1)
        end
        tt:AddDoubleLine("Per completion", ns.Money(s.unitGold) .. (s.learned and " (your average)" or " (estimate)"), 0.7, 0.7, 0.7, 1, 1, 1)
        tt:AddLine(" ")
        tt:AddLine("Right-click: mark done / not done and more", 0.6, 0.6, 0.6)
      end, function(btn, owner) UI.ClickStep(s, btn, owner) end)
      y = y + 18
    end
    local scanned = ns.DB.wqScanned and (ns.Duration(time() - ns.DB.wqScanned) .. " ago") or "not yet"
    T(p, 4, y + 2, GREY .. "Left-click: go there  ·  Right-click: mark done and more  ·  * estimate until you've opened its cache  ·  WQs scanned " .. scanned .. "|r")
    y = y + 22
  end

  -- Special Assignments: each one with its unlock progress
  local saList = {}
  for _, s in ipairs(r.steps) do if s.saOpen then saList = s.saOpen end end
  if #saList > 0 then
    y = Header(p, y + 4, "Special Assignments", #saList .. " up · unlock with 3 world quests in their zone")
    local now = time()
    for _, sa in ipairs(saList) do
      local left = sa.expires and (sa.expires - now)
      T(p, 14, y, sa.unlocked and ICON_DONE or ICON_LOG, 20)
      T(p, 40, y, sa.short ~= "" and sa.short or "Special Assignment", 280)
      T(p, 330, y, sa.unlocked and (GREEN .. "ready to do|r") or
        (YELLOW .. sa.have .. "/" .. sa.need .. " world quests|r" .. GREY .. (sa.exact and "" or " ~") .. "|r"), 140)
      T(p, 470, y, GREY .. (sa.zone or "?") .. "|r", 180)
      T(p, 650, y, left and ((left < 4 * 3600 and RED or GREY) .. ns.Duration(left) .. " left|r") or "", 90, "RIGHT")
      local q = sa
      Hot(p, 0, y - 2, CW, 18, function(tt)
        tt:AddLine(q.title or "Special Assignment", 1, 0.82, 0)
        tt:AddDoubleLine("World quests open in " .. (q.zone or "?"), q.openInZone, 0.7, 0.7, 0.7, 1, 1, 1)
        if not q.exact then tt:AddLine("Progress counted by the addon (the game didn't report it).", 0.6, 0.6, 0.6, true) end
        tt:AddLine(ns.WQ.CLICK_HINT, 0.6, 0.6, 0.6, true)
      end, function(btn, owner) ns.WQ.OnClick(q.qid, btn, owner) end)
      y = y + 18
    end
  end

  if #r.done > 0 then
    y = Header(p, y + 4, "Done this week")
    for _, s in ipairs(r.done) do
      T(p, 14, y, ICON_DONE, 20)
      T(p, 40, y, GREY .. s.name .. (s.count > 1 and string.format(" (%d/%d)", s.done, s.count) or "") .. "|r", 280)
      local w = r.char.weekly[s.key]
      T(p, 330, y, (w and w.manual) and (GREY .. "marked by you|r") or "", 130)
      T(p, 470, y, s.earned > 0 and ns.Money(s.earned) or GREY .. "—|r", 100, "RIGHT")
      local st = s
      Hot(p, 0, y - 2, CW, 18, function(tt)
        tt:AddLine(st.name, 1, 0.82, 0)
        tt:AddLine("Right-click to mark it not done.", 0.6, 0.6, 0.6)
      end, function(btn, owner) if btn == "RightButton" then UI.ActivityMenu(owner, ns.charKey, st.a) end end)
      y = y + 18
    end
  end

  -- Alt queue
  y = Header(p, y + 6, "Next best alts to log")
  local shown = 0
  for _, q in ipairs(ns.AltQueue()) do
    if q.key ~= key and q.gold > 0 then
      shown = shown + 1
      T(p, 14, y, shown .. ".", 20, "RIGHT")
      T(p, 40, y, ns.ColorName(q.key, q.c) .. GREY .. "  (" .. (q.key:match("%-(.+)$") or "") .. ")|r", 280)
      T(p, 330, y, q.left .. " tasks left", 130)
      T(p, 470, y, ns.Money(q.gold), 100, "RIGHT")
      T(p, 580, y, q.mins .. " min", 60, "RIGHT")
      y = y + 18
      if shown >= 8 then break end
    end
  end
  if shown == 0 then
    T(p, 14, y, GREY .. "No other alts with work left (log each alt once so it gets tracked).|r")
    y = y + 18
  end
  return y + 10
end

------------------------------------------------------------------------
-- Alts tab: the army overview grid
------------------------------------------------------------------------
function UI:RenderAlts(p)
  Begin(p)
  local acts = {}
  for _, a in ipairs(ns.ACTIVITIES) do
    if ns.ActSet(a).enabled then acts[#acts + 1] = a end
  end
  local x0 = 190
  local wqW = ns.DB.settings.wq.enabled and 64 or 0
  local colW = math.max(30, math.min(46, math.floor((CW - x0 - wqW - 260) / math.max(1, #acts))))
  local y = 4
  local queue = ns.AltQueue()

  T(p, 4, y, GOLD .. "Character|r", 150)
  T(p, 150, y, GOLD .. "Lvl|r", 34, "CENTER")
  for i, a in ipairs(acts) do
    T(p, x0 + (i - 1) * colW, y, GOLD .. a.short .. "|r", colW, "CENTER")
  end
  local xw = x0 + #acts * colW
  if wqW > 0 then T(p, xw, y, GOLD .. "WQs|r", wqW, "CENTER") end
  local xr = xw + wqW + 6
  T(p, xr, y, GOLD .. "Net wk|r", 76, "RIGHT")
  T(p, xr + 80, y, GOLD .. "Left (est)|r", 80, "RIGHT")
  T(p, xr + 164, y, GOLD .. "On hand|r", 84, "RIGHT")
  y = y + 20

  local totLeft, totHand, totNet = 0, 0, 0
  for row, q in ipairs(queue) do
    local c = q.c
    Stripe(p, 0, y - 2, CW, 18, row % 2 == 0)
    if q.key == ns.charKey then R(p, 0, y - 2, CW, 18, St.GOLD[1], St.GOLD[2], St.GOLD[3], St.SECTION_A) end
    -- world quests / Special Assignments are known for an alt once it has
    -- been logged in since they were tracked per character
    local known = not ns.WQ.IsEstimate(c)
    local EST = known and "" or (GREY .. "~|r")
    T(p, 4, y, ns.ColorName(q.key, c), 145)
    T(p, 150, y, tostring(c.level or "?"), 34, "CENTER")
    for i, a in ipairs(acts) do
      local cell
      local applies = ns.Applies(c, a)
      local d, count, inLog = 0, 0, false
      if not applies then
        cell = GREY .. ((a.minLevel and (c.level or 0) < a.minLevel) and (a.minLevel .. "+") or "n/a") .. "|r"
      else
        d, count, inLog = ns.ActStatus(c, a)
        if count == 0 then cell = GREY .. "-|r"
        elseif d >= count then cell = ICON_DONE
        elseif count > 1 then cell = (d > 0 and YELLOW or RED) .. d .. "/" .. count .. "|r"
        elseif inLog then cell = ICON_LOG
        else cell = ICON_TODO end
        -- Special Assignments on an alt not logged in since they're tracked
        -- per character: estimated from the map
        if a.key == "special" then cell = cell .. EST end
      end
      T(p, x0 + (i - 1) * colW, y, cell, colW, "CENTER")
      if applies then
        local key, act, dd, cc = q.key, a, d, count
        Hot(p, x0 + (i - 1) * colW, y - 2, colW, 18, function(tt)
          tt:AddLine(act.name, 1, 0.82, 0)
          tt:AddDoubleLine(ns.ColorName(key, c), cc == 0 and "none up" or (dd >= cc and "done" or (dd .. "/" .. cc)), 1, 1, 1, 1, 1, 1)
          if act.key == "special" and not known then
            tt:AddLine("~ Estimate from the Special Assignments on the map now. Log in on this character once to see its own.", 0.8, 0.8, 0.8, true)
          end
          tt:AddLine("Right-click to mark done / not done.", 0.6, 0.6, 0.6)
        end, function(btn, owner) if btn == "RightButton" then UI.ActivityMenu(owner, key, act) end end)
      end
    end
    if wqW > 0 then
      T(p, xw, y, (q.wqN > 0 and (YELLOW .. q.wqN .. "|r " .. ns.Money(q.wqGold)) or ICON_DONE) .. EST, wqW, "CENTER")
      Hot(p, xw, y - 2, wqW, 18, function(tt)
        tt:AddLine("Gold world quests", 1, 0.82, 0)
        tt:AddDoubleLine(ns.ColorName(q.key, c), q.wqN .. " open · " .. ns.Money(q.wqGold), 1, 1, 1, 1, 1, 1)
        if not known then
          tt:AddLine("~ Estimate from the world quests up now. Log in on this character once to see its own.", 0.8, 0.8, 0.8, true)
        elseif q.key ~= ns.charKey then
          tt:AddLine((c.level or 0) >= 90
            and "The ones open when you last played it, plus new ones another level-90 character found since (not expired yet)."
            or "The ones open when you last played it that haven't expired yet (new ones show when you log in).", 0.7, 0.7, 0.7, true)
        end
      end)
    end
    local net = ns.WeekIncome(c) - ns.WeekSpend(c)
    T(p, xr, y, (net < 0 and RED or "") .. ns.Money(net), 76, "RIGHT")
    T(p, xr + 80, y, (q.gold > 0 and (EST .. ns.Money(q.gold)) or (GREEN .. "done|r")), 80, "RIGHT")
    -- 0 gold on an alt is almost always the old logout bug: shown as unknown
    T(p, xr + 164, y, ((c.money or 0) == 0 and q.key ~= ns.charKey) and (GREY .. "?|r") or ns.Money(c.money or 0), 84, "RIGHT")
    totLeft, totHand, totNet = totLeft + q.gold, totHand + (c.money or 0), totNet + net

    local key = q.key
    Hot(p, 0, y - 2, 190, 18, function(tt)
      tt:AddLine(ns.ColorName(key, c) .. "  " .. key)
      tt:AddDoubleLine("Last seen", c.lastSeen and date("%a %d %b %H:%M", c.lastSeen) or "?", 0.7, 0.7, 0.7, 1, 1, 1)
      tt:AddDoubleLine("Earned this week", ns.Money(ns.WeekIncome(c)), 0.7, 0.7, 0.7, 1, 1, 1)
      tt:AddDoubleLine("Spent this week", ns.Money(ns.WeekSpend(c)), 0.7, 0.7, 0.7, 1, 1, 1)
      tt:AddDoubleLine("All-time tracked net", ns.Money((c.allIn or 0) - (c.allOut or 0)), 0.7, 0.7, 0.7, 1, 1, 1)
      if c.crafting and (c.crafting.count or 0) > 0 then
        tt:AddDoubleLine("Crafting orders", c.crafting.count .. " for " .. ns.Money(c.crafting.gold), 0.7, 0.7, 0.7, 1, 1, 1)
      end
      if q.route and #q.route.steps > 0 then
        tt:AddLine(" ")
        tt:AddLine("Route:", 1, 0.82, 0)
        for i, s in ipairs(q.route.steps) do
          tt:AddDoubleLine(i .. ". " .. s.name .. "  |cff888888" .. s.zone .. "|r", ns.Money(s.gold), 1, 1, 1, 1, 1, 1)
        end
      end
    end)
    y = y + 18
  end

  y = y + 4
  R(p, 0, y, CW, 1, St.GOLD[1], St.GOLD[2], St.GOLD[3], St.LINE_A)
  y = y + 6
  T(p, 4, y, GOLD .. "Army total (" .. #queue .. " characters)|r", 300)
  T(p, xr, y, ns.Money(totNet), 76, "RIGHT")
  T(p, xr + 80, y, ns.Money(totLeft), 80, "RIGHT")
  T(p, xr + 164, y, ns.Money(totHand), 84, "RIGHT")
  y = y + 18
  if (ns.DB.warband or 0) > 0 then
    T(p, 4, y, GREY .. "Warband bank|r", 300)
    T(p, xr + 164, y, ns.Money(ns.DB.warband), 84, "RIGHT")
    y = y + 18
    T(p, 4, y, GOLD .. "Total wealth|r", 300)
    T(p, xr + 164, y, ns.Money(totHand + ns.DB.warband), 84, "RIGHT")
    y = y + 18
  end
  y = y + 8
  T(p, 4, y, ICON_DONE .. " done   " .. ICON_LOG .. " picked up   " .. ICON_TODO .. " not started   " ..
    GREY .. "90+ needs level 90  ·  Hover a name for its route, right-click a cell to mark it.  Below level " ..
    (ns.DB.settings.minLevel or 0) .. " hidden (Setup).|r")
  return y + 24
end

------------------------------------------------------------------------
-- Orders tab: crafting orders worth doing, per character
------------------------------------------------------------------------
local VERDICT = {
  profit = { "", nil },
  price = { YELLOW .. "mats unpriced|r", nil },
  recipe = { YELLOW .. "no recipe|r", nil },
  loss = { GREY .. "not worth it|r", nil },
}

function UI:RenderOrders(p)
  Begin(p)
  local y = 4
  local src = ns.Prices.Source()
  local os = ns.DB.settings.orders
  if src == "TSM" then
    T(p, 4, y, "Prices: " .. GREEN .. "TradeSkillMaster|r" .. GREY .. "  (" .. (os.tsmPrice or "") .. ")   ·   minimum profit " .. ns.Money((os.minProfit or 0) * 10000) .. " (Setup)|r")
  elseif src == "Auctionator" then
    T(p, 4, y, "Prices: " .. GREEN .. "Auctionator|r" .. GREY .. "  (last scan)   ·   minimum profit " .. ns.Money((os.minProfit or 0) * 10000) .. " (Setup)|r")
  else
    T(p, 4, y, RED .. "No price addon found.|r " .. GREY .. "Install Auctionator or TradeSkillMaster so reagent costs can be priced.|r")
  end
  y = y + 22

  -- characters with order data, current one first, then by profit
  local chars = {}
  for key, c in pairs(ns.DB.chars) do
    if c.craftOrders and next(c.craftOrders) then
      local n, gold, scanned = ns.Orders.Summary(c)
      chars[#chars + 1] = { key = key, c = c, n = n, gold = gold, scanned = scanned }
    end
  end
  table.sort(chars, function(a, b)
    if (a.key == ns.charKey) ~= (b.key == ns.charKey) then return a.key == ns.charKey end
    return a.gold > b.gold
  end)

  if #chars == 0 then
    T(p, 10, y, GREY .. "No orders scanned yet.|r", nil, nil, GameFontNormal)
    y = y + 20
    T(p, 10, y, GREY .. "Open a profession's Crafting Orders at its work table (Patron, Public and Personal tabs) on each crafter;|r")
    y = y + 16
    T(p, 10, y, GREY .. "the orders are read and priced automatically. New patron orders appear every day or so.|r")
    return y + 24
  end

  local now = time()
  for _, ch in ipairs(chars) do
    local ago = ch.scanned and ns.Duration(now - ch.scanned) .. " ago" or "never"
    local stale = ch.scanned and now - ch.scanned > 24 * 3600
    y = Header(p, y + 2, "")
    T(p, 8, y - 20, ns.ColorName(ch.key, ch.c) .. GREY .. "  ·  scanned " .. ago .. (stale and (RED .. " (stale - open the table again)|r") or "") .. "|r", nil, nil, GameFontNormal)
    T(p, CW - 260, y - 19, ch.n > 0 and (GREEN .. ch.n .. " worth doing|r" .. GREY .. "  ·  |r" .. ns.Money(ch.gold) .. GREY .. " profit|r") or (GREY .. "nothing worth doing|r"), 252, "RIGHT")

    T(p, 14, y, GREY .. "Order|r"); T(p, 262, y, GREY .. "Type|r")
    T(p, 320, y, GREY .. "Commission|r", 80, "RIGHT"); T(p, 404, y, GREY .. "Your mats|r", 80, "RIGHT")
    T(p, 488, y, GREY .. "Rewards|r", 80, "RIGHT"); T(p, 572, y, GREY .. "Profit|r", 90, "RIGHT")
    T(p, 666, y, GREY .. "Expires|r", 70, "RIGHT")
    y = y + 16

    local list = ns.Orders.List(ch.c)
    local hiddenLoss, shownLoss = 0, 0
    for _, e in ipairs(list) do
      if e.verdict == "loss" and shownLoss >= 3 then
        hiddenLoss = hiddenLoss + 1
      else
        if e.verdict == "loss" then shownLoss = shownLoss + 1 end
        local dim = e.verdict ~= "profit"
        local name = (dim and GREY or "") .. e.name .. (dim and "|r" or "")
        T(p, 14, y, name .. GREY .. "  " .. (e.prof or "") .. "|r", 244)
        T(p, 262, y, (dim and GREY or "") .. e.typeName .. (dim and "|r" or ""), 56)
        T(p, 320, y, ns.Money(e.tip - e.cut), 80, "RIGHT")
        T(p, 404, y, e.missingPrices and (YELLOW .. "?|r") or (e.cost > 0 and ns.Money(e.cost) or GREY .. "provided|r"), 80, "RIGHT")
        T(p, 488, y, e.rewardValue > 0 and ns.Money(e.rewardValue) or (#e.rewards > 0 and GREY .. "items|r" or GREY .. "-|r"), 80, "RIGHT")
        local verdictText = VERDICT[e.verdict][1]
        if e.verdict == "profit" then
          T(p, 572, y, GREEN .. ns.Money(e.profit) .. "|r", 90, "RIGHT")
        elseif e.verdict == "loss" then
          T(p, 572, y, RED .. ns.Money(e.profit) .. "|r", 90, "RIGHT")
        else
          T(p, 572, y, verdictText, 90, "RIGHT")
        end
        T(p, 666, y, e.expires and (GREY .. ns.Duration(e.expires - now) .. "|r") or "", 70, "RIGHT")
        Hot(p, 0, y - 2, CW, 16, function(tt) UI.OrderTooltip(tt, e) end)
        y = y + 16
      end
    end
    if hiddenLoss > 0 then
      T(p, 14, y, GREY .. "+" .. hiddenLoss .. " more not worth doing|r")
      y = y + 16
    end
    y = y + 6
  end
  T(p, 4, y + 4, GREY .. "Mats are priced at the cheapest quality you could use; check the order's minimum quality before crafting.|r")
  return y + 26
end

function UI.OrderTooltip(tt, e)
  tt:AddLine(e.name, 1, 0.82, 0)
  tt:AddDoubleLine(e.typeName .. " order" .. (e.customer and e.customer ~= "" and (" from " .. e.customer) or ""), e.prof or "", 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
  if not e.known then tt:AddLine("You don't know this recipe on this character.", 1, 0.4, 0.4, true) end
  if e.minQuality and e.minQuality > 1 then tt:AddLine("Minimum quality: " .. e.minQuality, 1, 0.8, 0.3) end
  tt:AddLine(" ")
  tt:AddDoubleLine("Commission", ns.Money(e.tip), 0.8, 0.8, 0.8, 1, 1, 1)
  if e.cut > 0 then tt:AddDoubleLine("Consortium cut", "-" .. ns.Money(e.cut), 0.8, 0.8, 0.8, 1, 0.5, 0.5) end
  for _, r in ipairs(e.rewards or {}) do
    tt:AddDoubleLine("Reward: " .. r.text, r.value and ns.Money(r.value) or "|cff888888no price|r", 0.8, 0.8, 0.8, 1, 1, 1)
  end
  if #(e.mats or {}) == 0 then
    tt:AddDoubleLine("Mats", "all provided", 0.8, 0.8, 0.8, 0.5, 1, 0.5)
  end
  for _, m in ipairs(e.mats or {}) do
    local name = m.itemID and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(m.itemID) or ("item " .. tostring(m.itemID))
    tt:AddDoubleLine(string.format("%dx %s", m.qty, name), m.price and ("-" .. ns.Money(m.price * m.qty)) or "|cffffee55no price|r",
      0.8, 0.8, 0.8, 1, 0.5, 0.5)
  end
  tt:AddLine(" ")
  if e.missingPrices then
    tt:AddLine("Some reagents have no auction price, so profit can't be worked out.", 1, 0.9, 0.3, true)
  else
    tt:AddDoubleLine("Profit", ns.Money(e.profit), 1, 0.82, 0, e.profit >= 0 and 0.3 or 1, e.profit >= 0 and 1 or 0.4, 0.4)
  end
end

------------------------------------------------------------------------
-- Cashflow tab: filter by period, character, source and income/spending
------------------------------------------------------------------------
local WEEK = 604800
local PERIODS = {
  { "week", "This week" }, { "today", "Today" }, { "session", "This session" },
  { "7d", "Last 7 days" }, { "30d", "Last 30 days" }, { "all", "Everything logged" },
}
local DIRS = { { "all", "Income & spending" }, { "in", "Income only" }, { "out", "Spending only" } }

local function Pick(list, v)
  for _, e in ipairs(list) do if e[1] == v then return e[2] end end
  return list[1][2]
end

local function PeriodStart(period)
  local now = time()
  if period == "week" then return (ns.GetChar().weekReset or ns.NextReset()) - WEEK end
  if period == "today" then
    local d = date("*t", now)
    d.hour, d.min, d.sec = 0, 0, 0
    return time(d)
  end
  if period == "session" then return ns.session.start end
  if period == "7d" then return now - 7 * 86400 end
  if period == "30d" then return now - 30 * 86400 end
  return 0
end

function UI:RenderCashflow(p)
  Begin(p)
  local DB = ns.DB
  local f = DB.settings.cashflow
  local y = 4

  -- filter chips
  local x = 4
  x = Chip(p, x, y, "Period", Pick(PERIODS, f.period), function(root)
    for _, e in ipairs(PERIODS) do
      root:CreateRadio(e[2], function() return f.period == e[1] end, function() f.period = e[1]; ns.Refresh() end)
    end
  end)
  if f.char ~= "all" and not DB.chars[f.char] then f.char = "all" end
  local charName = f.char == "all" and "All characters" or ns.ColorName(f.char, DB.chars[f.char])
  x = Chip(p, x, y, "Character", charName, function(root)
    root:CreateRadio("All characters", function() return f.char == "all" end, function() f.char = "all"; ns.Refresh() end)
    local keys = {}
    for k in pairs(DB.chars) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      root:CreateRadio(ns.ColorName(k, DB.chars[k]) .. "  |cff888888" .. (k:match("%-(.+)$") or "") .. "|r",
        function() return f.char == k end, function() f.char = k; ns.Refresh() end)
    end
  end)
  x = Chip(p, x, y, "Source", f.src == "all" and "All" or f.src, function(root)
    root:CreateRadio("All sources", function() return f.src == "all" end, function() f.src = "all"; ns.Refresh() end)
    for _, s in ipairs(ns.SOURCES) do
      root:CreateRadio(s, function() return f.src == s end, function() f.src = s; ns.Refresh() end)
    end
  end)
  x = Chip(p, x, y, "Show", Pick(DIRS, f.dir), function(root)
    for _, e in ipairs(DIRS) do
      root:CreateRadio(e[2], function() return f.dir == e[1] end, function() f.dir = e[1]; ns.Refresh() end)
    end
  end)
  local filtered = f.char ~= "all" or f.src ~= "all" or f.dir ~= "all" or f.period ~= "week"
  if filtered then
    T(p, x + 4, y + 3, RED .. "Clear filters|r")
    Hot(p, x, y, 84, 18, nil, function() f.period, f.char, f.src, f.dir = "week", "all", "all", "all"; ns.Refresh() end)
  end
  y = y + 28

  -- matching ledger entries (newest first)
  local start = PeriodStart(f.period)
  local inBy, outBy, totIn, totOut = {}, {}, 0, 0
  local perChar, list = {}, {}
  local L = DB.ledger
  for i = #L, 1, -1 do
    local e = L[i]
    if e.t < start then break end
    local ok = (f.char == "all" or e.c == f.char) and (f.src == "all" or e.s == f.src)
      and not (f.dir == "in" and e.a <= 0) and not (f.dir == "out" and e.a >= 0)
    if ok then
      list[#list + 1] = e
      -- transfers between your own characters/banks aren't income or spending
      if e.s ~= "Transfer" or f.src == "Transfer" then
        local pc = perChar[e.c]
        if not pc then pc = { key = e.c, i = 0, o = 0, weekly = 0 }; perChar[e.c] = pc end
        if e.a > 0 then
          inBy[e.s] = (inBy[e.s] or 0) + e.a
          totIn, pc.i = totIn + e.a, pc.i + e.a
          if e.k then pc.weekly = pc.weekly + e.a end
        else
          outBy[e.s] = (outBy[e.s] or 0) - e.a
          totOut, pc.o = totOut - e.a, pc.o - e.a
        end
      end
    end
  end

  local net = totIn - totOut
  T(p, 4, y, string.format("%s%s:   income %s   spent %s   net %s", Pick(PERIODS, f.period),
    f.char ~= "all" and (" on " .. charName) or "", ns.Money(totIn), ns.Money(totOut),
    (net >= 0 and GREEN or RED) .. ns.Money(net) .. "|r"), nil, nil, GameFontNormal)
  y = y + 22
  local hours = math.max(1 / 60, (time() - ns.session.start) / 3600)
  T(p, 4, y, GREY .. string.format("This session on %s: %s net (%s per hour)   ·   Gold moved between your own characters, warband and guild bank is left out.",
    ns.ColorName(ns.charKey, ns.GetChar()) .. GREY, ns.Money(ns.session.net), ns.Money(ns.session.net / hours)) .. "|r")
  y = y + 24

  -- by source, with bars; click one to filter on it
  local function Bars(label, by, total, yy)
    yy = Header(p, yy, label, f.src == "all" and "click a source to filter" or nil)
    local maxV = 0
    for _, v in pairs(by) do maxV = math.max(maxV, v) end
    local any = false
    for _, src in ipairs(ns.SOURCES) do
      local v = by[src]
      if v and v > 0 then
        any = true
        local r, g, b = SourceColor(src)
        T(p, 10, yy, src, 120)
        R(p, 140, yy, math.floor(500 * v / math.max(1, maxV)), 12, r, g, b, 0.8)
        T(p, 650, yy, ns.Money(v), 100, "RIGHT")
        T(p, 760, yy, GREY .. string.format("%d%%", math.floor(100 * v / math.max(1, total) + 0.5)) .. "|r", 50, "RIGHT")
        local s = src
        Hot(p, 0, yy - 2, CW, 16, nil, function() f.src = (f.src == s) and "all" or s; ns.Refresh() end)
        yy = yy + 18
      end
    end
    if not any then T(p, 10, yy, GREY .. "Nothing recorded for this filter.|r"); yy = yy + 18 end
    return yy
  end
  if f.dir ~= "out" then y = Bars("Income by source", inBy, totIn, y) end
  if f.dir ~= "in" then y = Bars("Spending by source", outBy, totOut, y + 6) end

  -- per character; click one to filter on it
  local chars = {}
  for _, pc in pairs(perChar) do chars[#chars + 1] = pc end
  table.sort(chars, function(a, b) return (a.i - a.o) > (b.i - b.o) end)
  if f.char == "all" or #chars > 0 then
    y = Header(p, y + 6, "Per character", f.char == "all" and "click a character to filter" or nil)
    T(p, 10, y, GREY .. "Character|r", 200); T(p, 330, y, GREY .. "Income|r", 100, "RIGHT")
    T(p, 440, y, GREY .. "Spent|r", 100, "RIGHT"); T(p, 550, y, GREY .. "Net|r", 100, "RIGHT")
    T(p, 660, y, GREY .. "From weeklies|r", 120, "RIGHT")
    y = y + 18
    for _, e in ipairs(chars) do
      local c = DB.chars[e.key]
      T(p, 10, y, ns.ColorName(e.key, c), 200)
      T(p, 330, y, ns.Money(e.i), 100, "RIGHT")
      T(p, 440, y, ns.Money(e.o), 100, "RIGHT")
      T(p, 550, y, (e.i - e.o >= 0 and GREEN or RED) .. ns.Money(e.i - e.o) .. "|r", 100, "RIGHT")
      T(p, 660, y, ns.Money(e.weekly), 120, "RIGHT")
      local k = e.key
      Hot(p, 0, y - 2, CW, 18, nil, function() f.char = (f.char == k) and "all" or k; ns.Refresh() end)
      y = y + 18
    end
    if #chars == 0 then T(p, 10, y, GREY .. "No activity for this filter.|r"); y = y + 18 end
  end

  -- previous weeks (totals per character are all that's kept)
  local stamps = {}
  for s in pairs(DB.history) do stamps[#stamps + 1] = s end
  table.sort(stamps, function(a, b) return a > b end)
  if #stamps > 0 and f.src == "all" and f.dir == "all" then
    y = Header(p, y + 6, "Previous weeks", f.char ~= "all" and ("for " .. charName) or nil)
    local maxNet, nets = 1, {}
    for _, s in ipairs(stamps) do
      local i, o = 0, 0
      for k, v in pairs(DB.history[s]) do
        if f.char == "all" or k == f.char then i = i + v.i; o = o + v.o end
      end
      nets[s] = { i = i, o = o }
      maxNet = math.max(maxNet, math.abs(i - o))
    end
    for _, s in ipairs(stamps) do
      local n = nets[s]
      local wnet = n.i - n.o
      T(p, 10, y, "Week ending " .. date("%d %b %Y", s), 160)
      R(p, 180, y, math.floor(400 * math.abs(wnet) / maxNet), 12, wnet >= 0 and 0.3 or 0.9, wnet >= 0 and 0.8 or 0.3, 0.3, 0.8)
      T(p, 590, y, ns.Money(n.i), 90, "RIGHT")
      T(p, 690, y, (wnet >= 0 and GREEN or RED) .. ns.Money(wnet) .. "|r", 110, "RIGHT")
      y = y + 18
    end
  end

  -- transactions
  local SHOW = 80
  y = Header(p, y + 6, "Transactions", #list .. " matching" ..(#list > SHOW and (", newest " .. SHOW .. " shown") or ""))
  for i, e in ipairs(list) do
    if i > SHOW then break end
    local r, g, b = SourceColor(e.s)
    Stripe(p, 0, y - 2, CW, 16, i % 2 == 0)
    T(p, 10, y, GREY .. date("%a %d %b %H:%M", e.t) .. "|r", 100)
    T(p, 115, y, ns.ColorName(e.c, DB.chars[e.c]), 100)
    R(p, 220, y + 2, 8, 8, r, g, b, 1)
    T(p, 234, y, e.s, 100)
    T(p, 340, y, GREY .. (e.d or (e.k and ns.ACT_BY_KEY[e.k] and ns.ACT_BY_KEY[e.k].name) or "") .. "|r", 330)
    T(p, 680, y, (e.a >= 0 and GREEN .. "+" or RED) .. ns.Money(e.a) .. "|r", 120, "RIGHT")
    y = y + 16
  end
  if #list == 0 then T(p, 10, y, GREY .. "No transactions for this filter.|r"); y = y + 18 end
  if #L > 0 and L[1].t > start and f.period == "all" then
    T(p, 10, y + 4, GREY .. "The log keeps your last 4,000 transactions.|r")
    y = y + 20
  end
  return y + 10
end

------------------------------------------------------------------------
-- Setup tab: widgets are created once; their labels and the live info
-- text are drawn every refresh from a layout list.
------------------------------------------------------------------------
local function MakeEdit(parent, w, onSave)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(w, 18)
  e:SetAutoFocus(false)
  e:SetNumeric(true)
  e:SetMaxLetters(7)
  local function save(self)
    local v = tonumber(self:GetText())
    if v then onSave(v) end
    self:ClearFocus()
    ns.Refresh()
  end
  e:SetScript("OnEnterPressed", save)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ns.Refresh() end)
  e:SetScript("OnEditFocusLost", function(self)
    local v = tonumber(self:GetText())
    if v then onSave(v) end
  end)
  return e
end

-- (hooked, so the button's own hover look keeps working)
local function Tip(owner, text)
  owner:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  owner:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

StaticPopupDialogs["GOLDCIRCUIT_FORGET_TRAVEL"] = {
  text = "Forget every learned hearthstone, teleport and portal link?\nThey're learned again as you travel.",
  button1 = YES, button2 = NO,
  OnAccept = function() ns.Travel.Forget() end,
  timeout = 0, whileDead = true, hideOnEscape = true,
}

function UI:BuildSetupWidgets(panel)
  local L, edits, checks = {}, {}, {}
  self.setupLayout, self.setupEdits, self.setupChecks = L, edits, checks
  local DB = ns.DB
  local y = 4
  local COL2 = 430

  local function Hdr(text, sub) L[#L + 1] = { header = text, sub = sub, y = y }; y = y + 28 end
  local function Text(x, yy, text, w, tip) L[#L + 1] = { x = x, y = yy, text = text, w = w, tip = tip } end
  local function Edit(x, yy, w, get, set)
    local e = MakeEdit(panel, w, set)
    e:SetPoint("TOPLEFT", x, -yy)
    edits[#edits + 1] = { edit = e, get = get }
  end
  local function Check(x, yy, label, get, set)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", x, -(yy - 3))
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false); ns.Refresh() end)
    cb.get = get
    checks[#checks + 1] = cb
    if label then Text(x + 26, yy + 2, label) end
  end
  local function Btn(x, yy, w, text, onClick, tip)
    local b = St.Button(panel, w, text, onClick)
    b:SetPoint("TOPLEFT", x, -(yy - 1))
    if tip then Tip(b, tip) end
    return b
  end
  -- label on the left, number box at x=330, grey note after it
  local function Row(label, w, get, set, note)
    Text(14, y + 3, label)
    Edit(330, y, w, get, set)
    if note then Text(342 + w, y + 3, GREY .. note .. "|r", CW - 350 - w) end
    y = y + 24
  end

  -- Activities
  Hdr("Activities", "untick what you don't do  ·  hover a name for details")
  Text(34, y, GREY .. "Activity|r"); Text(300, y, GREY .. "Gold|r"); Text(372, y, GREY .. "Minutes|r")
  Text(436, y, GREY .. "Per week|r"); Text(510, y, GREY .. "Gold per completion used|r")
  y = y + 18
  for _, a in ipairs(ns.ACTIVITIES) do
    local function s() return ns.ActSet(a) end
    Check(6, y, nil, function() return s().enabled end, function(v) s().enabled = v end)
    Text(34, y + 3, function() return a.name .. (a.minLevel and (GREY .. "  " .. a.minLevel .. "+|r") or "") end, 250, function(tt)
      tt:AddLine(a.name, 1, 0.82, 0)
      if a.desc then tt:AddLine(a.desc, 1, 1, 1, true) end
      if a.minLevel then tt:AddLine("Needs level " .. a.minLevel .. ".", 1, 0.6, 0.3) end
      tt:AddLine(" ")
      if a.patterns and #a.patterns > 0 then tt:AddLine("Matches quests named: " .. table.concat(a.patterns, ", "), 0.8, 0.8, 0.8, true) end
      local n = 0
      for qid, title in pairs(DB.questIDs[a.key] or {}) do
        n = n + 1
        tt:AddDoubleLine(qid, tostring(title), 1, 1, 1, 0.7, 0.7, 0.7)
      end
      if a.kind == "crafting" then tt:AddLine("Counted per crafting profession: each is done after one order this week, or when its table has nothing profitable left.", 0.8, 0.8, 0.8, true)
      elseif n == 0 then tt:AddLine("No quest IDs learned yet.", 1, 0.4, 0.4)
      else tt:AddLine("Set one manually: /gc learn " .. a.key .. " <questID>", 0.6, 0.6, 0.6) end
    end)
    Edit(300, y, 56, function() return s().gold or 0 end, function(v)
      if v ~= s().gold then s().gold, s().override = v, true end
    end)
    Edit(372, y, 40, function() return s().minutes or 0 end, function(v)
      v = math.max(1, v)
      if v ~= s().minutes then s().minutes, s().minutesSet = v, true end
    end)
    if a.key == "special" then
      Text(436, y + 3, GREY .. "from map|r")
    elseif a.kind == "crafting" then
      Text(436, y + 3, GREY .. "per prof.|r")
    elseif a.families then
      Text(436, y + 3, GREY .. "alternate|r")
    else
      Edit(444, y, 30, function() return s().count or 1 end, function(v) s().count = math.max(1, math.min(10, v)) end)
    end
    Text(510, y + 3, function()
      local est, learned = ns.EstGold(a)
      return ns.Money(est) .. GREY .. "  " .. (learned and "your average" or (s().override and "your value" or "default")) .. "|r"
    end, 160)
    Btn(676, y, 72, "Use avg", function() s().override = nil; ns.Refresh() end,
      "Use your real average gold for this activity (once tracked) instead of the typed value.")
    if a.kind ~= "crafting" then
      Btn(752, y, 80, "Forget IDs", function() SlashCmdList.GOLDCIRCUIT("forget " .. a.key) end,
        "Clear the learned quest IDs for this activity and never learn them again. Use it if a wrong quest was matched.")
    end
    y = y + 24
  end

  -- Windows
  y = y + 6
  Hdr("Windows")
  Check(6, y, "Compact tracker (what's left on this character)", function() return DB.settings.mini.shown end,
    function(v) DB.settings.mini.shown = v end)
  Check(COL2, y, "Lock its position", function() return DB.settings.mini.locked end, function(v) DB.settings.mini.locked = v end)
  y = y + 24
  Check(6, y, "World quest tracker window", function() return DB.settings.wqWin and DB.settings.wqWin.shown end,
    function(v) ns.WQWindow:Toggle(v) end)
  Check(COL2, y, "Lock its position", function() return DB.settings.wqWin and DB.settings.wqWin.locked end,
    function(v) DB.settings.wqWin.locked = v end)
  y = y + 24
  Check(6, y, "Minimap button", function() return not DB.settings.minimap.hide end,
    function(v) DB.settings.minimap.hide = not v; UI:UpdateMinimap() end)
  Check(COL2, y, "Chat messages (off: only /gc replies and warnings)", function() return DB.settings.announce end,
    function(v) DB.settings.announce = v end)
  y = y + 26
  Row("Hide characters below level", 34, function() return DB.settings.minLevel or 0 end,
    function(v) DB.settings.minLevel = v end, "in the Alts grid and the alt queue")

  -- World quests
  y = y + 6
  Hdr("World quests")
  Check(6, y, "Track gold world quests", function() return DB.settings.wq.enabled end,
    function(v) DB.settings.wq.enabled = v; if v then ns.WQ.QueueScan(0.5) end end)
  Text(COL2, y + 2, function()
    local n, g = ns.WQ.Count()
    local maps = 0
    for _ in pairs(DB.wqMaps or {}) do maps = maps + 1 end
    return GREY .. string.format("%d up now (%s) across %d zones", n, ns.Money(g), maps) .. "|r"
  end, 400)
  y = y + 26
  Row("Minimum gold per world quest", 50, function() return DB.settings.wq.minGold or 0 end,
    function(v) DB.settings.wq.minGold = v end, "smaller ones aren't listed")
  Row("Minutes per world quest", 34, function() return DB.settings.wq.minutes or 4 end,
    function(v) DB.settings.wq.minutes = math.max(1, v) end, "used for gold per minute")
  Text(14, y + 3, function() return "Skipped world quests: " .. #ns.WQ.Skipped() end)
  Btn(330, y, 120, "Bring them back", function() ns.WQ.ClearSkips() end,
    "Unskip every world quest you skipped. Skip one by right-clicking it in the World Quest Tracker.")
  y = y + 24
  Text(14, y + 3, GREY .. "Coiled Isle quests need level 90, the rest 80.  Zone missing? Stand in it and type /gc wqhere.|r", CW - 20)
  y = y + 20

  -- Events
  y = y + 6
  Hdr("Events", "Aqir")
  local aqir = ns.ACT_BY_KEY.aqir
  Row("Remind me before it starts (minutes, 0 = off)", 34, function() return ns.ActSet(aqir).remind or 0 end,
    function(v) ns.ActSet(aqir).remind = math.max(0, math.min(60, v)) end, "only while Aqir is ticked above and not done this week")
  Check(6, y, "Play a sound with the reminder", function() return DB.settings.remindSound end, function(v) DB.settings.remindSound = v end)
  y = y + 26
  Text(14, y + 3, function()
    if not C_EventScheduler then return GREY .. "The map's Events tab isn't available on this client; the addon uses its own checks.|r" end
    local sc = ns.WQ.SchedFor(aqir)
    return GREY .. (sc and "Running / next start / reward claimed come from the map's Events tab." or
      "Waiting for the map's Events tab to list Aqir (it lists events on the continent you're on).") ..
      "  Game reminders are set on the map's Events tab itself.|r"
  end, CW - 20)
  y = y + 20

  -- Navigation
  y = y + 6
  Hdr("Navigation", "directions at the bottom of the World Quest Tracker")
  local tv = DB.settings.travel
  Check(6, y, "Directions (fastest way there with hearthstone, teleports and portals)", function() return tv.enabled end,
    function(v) tv.enabled = v end)
  y = y + 26
  Row("Flying speed (yards/second)", 40, function() return tv.speed end, function(v) tv.speed = math.max(5, v) end,
    "skyriding averages roughly 50-70")
  Row("Loading screen (seconds)", 40, function() return tv.loading end, function(v) tv.loading = math.max(0, v) end)
  Row("Only suggest a teleport if it saves (seconds)", 40, function() return tv.minSaving end,
    function(v) tv.minSaving = math.max(0, v) end, "so your Hearthstone isn't spent to save a few seconds")
  Text(14, y + 3, function()
    local nTele = 0
    for _ in pairs(DB.travel.tele) do nTele = nTele + 1 end
    return string.format("Learned: %d portal links, %d teleports", #DB.travel.portals, nTele) .. GREY .. "  (/gc travel lists them)|r"
  end)
  Btn(330, y, 120, "Forget travel", function() StaticPopup_Show("GOLDCIRCUIT_FORGET_TRAVEL") end,
    "Forget every learned hearthstone, teleport and portal link. They're learned again as you travel.")
  y = y + 24

  -- Crafting orders
  y = y + 6
  Hdr("Crafting orders")
  local ord = DB.settings.orders
  Row("Minimum profit per order (gold)", 50, function() return ord.minProfit or 0 end, function(v) ord.minProfit = v end)
  Text(14, y + 3, "Reagent prices from")
  local order = { "auto", "tsm", "auctionator" }
  self.priceSourceButton = Btn(330, y, 140, "", function()
    for i, k in ipairs(order) do
      if k == (ord.priceSource or "auto") then ord.priceSource = order[i % #order + 1]; break end
    end
    ns.Refresh()
  end, "Click to switch: Auto (TSM if loaded, else Auctionator), TradeSkillMaster or Auctionator.")
  Text(480, y + 3, function()
    local using = ns.Prices.Source()
    return using and (GREY .. "using " .. using .. "|r") or (RED .. "no price addon loaded|r")
  end)
  y = y + 32
  Text(4, y, GREY .. "All slash commands: /gc help|r")
  self.setupHeight = y + 24
end

function UI:RenderSetup(p)
  Begin(p)
  if not self.setupLayout then self:BuildSetupWidgets(p.parent) end
  for _, l in ipairs(self.setupLayout) do
    if l.header then
      Header(p, l.y, l.header, l.sub)
    else
      T(p, l.x, l.y, type(l.text) == "function" and l.text() or l.text, l.w)
      if l.tip then Hot(p, l.x - 2, l.y - 3, l.w or 200, 18, l.tip) end
    end
  end
  for _, e in ipairs(self.setupEdits) do
    if not e.edit:HasFocus() then e.edit:SetText(tostring(e.get() or 0)) end
  end
  for _, cb in ipairs(self.setupChecks) do cb:SetChecked(cb.get() and true or false) end
  local names = { auto = "Auto", tsm = "TradeSkillMaster", auctionator = "Auctionator" }
  self.priceSourceButton:SetText(names[ns.DB.settings.orders.priceSource or "auto"] or "Auto")
  return self.setupHeight
end

------------------------------------------------------------------------
-- Compact tracker
------------------------------------------------------------------------
function UI:CreateMini()
  local DB = ns.DB
  local m = CreateFrame("Frame", "GoldCircuitMini", UIParent, "BackdropTemplate")
  self.mini = m
  m:SetSize(MINI_W, 60)
  m:SetFrameStrata("MEDIUM")
  m:SetClampedToScreen(true)
  m:SetMovable(true)
  m:EnableMouse(true)
  m:RegisterForDrag("LeftButton")
  m:SetScript("OnDragStart", function(s) if not DB.settings.mini.locked then s:StartMoving() end end)
  m:SetScript("OnDragStop", function(s)
    s:StopMovingOrSizing()
    local point, _, rel, x, y = s:GetPoint()
    DB.settings.miniPos = { point, rel, x, y }
  end)
  m:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then UI:Toggle() end end)
  local pos = DB.settings.miniPos
  if pos then m:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else m:SetPoint("RIGHT", UIParent, "RIGHT", -40, 120) end
  St.Window(m)
  St.TitleBar(m, "Gold Circuit")
  local close = St.Close(m, function() DB.settings.mini.shown = false; UI:UpdateMini() end)
  m.sub = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  m.sub:SetPoint("RIGHT", close, "LEFT", -6, 0)
  m.sub:SetJustifyH("RIGHT")
  self.miniPool = NewPool(m)
end

function UI:ToggleMini()
  local s = ns.DB.settings.mini
  s.shown = not s.shown
  self:UpdateMini()
end

-- Compact tracker rows use the same columns as the World Quest window:
-- icon, name, status, gold.
function UI:UpdateMini()
  local m = self.mini
  if not m then return end
  if not ns.DB.settings.mini.shown then m:Hide() return end
  m:Show()
  local MW = MINI_W
  local IN = 8              -- inner margin
  local RW = MW - 2 * IN    -- row width
  local ROW = 18
  local p = self.miniPool
  Begin(p)
  local r = ns.BuildRoute(ns.charKey)
  local total = #r.steps + #r.done
  -- Special Assignments get their own section at the bottom
  local saStep
  local steps = {}
  for _, st in ipairs(r.steps) do
    if st.a and st.a.key == "special" then saStep = st else steps[#steps + 1] = st end
  end
  m.sub:SetText(GREY .. #r.done .. "/" .. total .. " done  ·  reset " .. ResetIn(r.char) .. "|r")
  local y = St.TITLE_H + 6

  local function Row(i, icon, name, status, gold, step)
    Stripe(p, IN, y, RW, ROW, i % 2 == 0)
    T(p, IN + 2, y + 3, icon, 16, "CENTER")
    T(p, IN + 22, y + 3, name, 144)
    T(p, IN + 166, y + 3, status, 62, "RIGHT")
    T(p, IN + 230, y + 3, gold, RW - 232, "RIGHT")
    if step then
      Hot(p, IN, y, RW, ROW, function(tt) UI.StepTooltip(tt, step) end, function(btn, owner) UI.ClickStep(step, btn, owner) end)
    end
    y = y + ROW
  end

  if #r.steps == 0 then
    local low = (r.char.level or 0) < ns.MIN_LEVEL
    T(p, IN + 2, y + 3, low and (GREY .. "Level " .. (r.char.level or "?") .. ": weeklies start at " .. ns.MIN_LEVEL .. "|r")
      or (GREEN .. "All done here - next alt!|r"), RW - 4)
    y = y + ROW
    for _, e in ipairs(ns.AltQueue()) do
      if e.key ~= ns.charKey and e.gold > 0 then
        Row(1, YELLOW .. "»|r", GREY .. "Next: |r" .. ns.ColorName(e.key, e.c), "", ns.Money(e.gold))
        break
      end
    end
  else
    for i, st in ipairs(steps) do
      if i > 10 then T(p, IN + 2, y + 3, GREY .. "+" .. (#steps - 10) .. " more (dashboard)|r"); y = y + ROW; break end
      local icon, name
      if st.isWQGroup then
        icon, name = YELLOW .. "»|r", "World Quests"
      else
        icon = st.inLog and ICON_LOG or ICON_TODO
        name = st.a and st.a.kind == "crafting" and "Crafting Orders" or st.name
        if st.count > 1 then name = name .. string.format(" %d/%d", st.done, st.count) end
      end
      Row(i, icon, name, UI.StepStatus(st), ns.Money(st.gold), st)
    end
    if saStep then
      -- section header, like the ones in the World Quest window
      y = y + 4
      local sr, sg, sb, sa = St.SectionColors()
      R(p, IN, y, RW, ROW, sr, sg, sb, sa)
      R(p, IN, y, 2, ROW, St.ACCENT[1], St.ACCENT[2], St.ACCENT[3], 1)
      T(p, IN + 8, y + 3, St.SECTION_TEXT .. "Special Assignments|r", 150, nil, GameFontNormalSmall)
      T(p, IN + 160, y + 3, UI.StepStatus(saStep), RW - 162, "RIGHT")
      local step = saStep
      Hot(p, IN, y, RW, ROW, function(tt) UI.StepTooltip(tt, step) end, function(btn, owner) UI.ClickStep(step, btn, owner) end)
      y = y + ROW
    end
    -- footer: what's left
    y = y + 4
    R(p, IN, y, RW, 1, St.GOLD[1], St.GOLD[2], St.GOLD[3], St.LINE_A)
    y = y + 4
    T(p, IN + 2, y + 2, GREY .. "Left  ~" .. r.mins .. " min|r", 150)
    T(p, IN + 150, y + 2, ns.Money(r.gold), RW - 152, "RIGHT")
    y = y + 16
  end
  m:SetHeight(y + 6)
end

-- Compact tooltip for a tracker row.
function UI.StepTooltip(tt, st)
  if st.isWQGroup then UI.WQGroupTooltip(tt, st); return end
  tt:AddLine(st.a and st.a.kind == "crafting" and "Crafting Orders" or st.name, 1, 0.82, 0)
  if st.a and st.a.key == "special" then
    local now = time()
    for _, sa in ipairs(st.saOpen or {}) do
      tt:AddDoubleLine((sa.short ~= "" and sa.short or "Special Assignment") .. "  |cff888888" .. (sa.zone or "?") .. "|r",
        (sa.unlocked and "|cff33ff66ready|r" or string.format("%d/%d WQs", sa.have, sa.need)) ..
        (sa.expires and ("  |cff888888" .. ns.Duration(sa.expires - now) .. "|r") or ""), 1, 1, 1, 1, 1, 1)
    end
    if st.done > 0 then tt:AddLine(st.done .. " done this week", 0.6, 0.9, 0.6) end
    tt:AddLine(" ")
    tt:AddLine("Click: track the first one and open the World Quest Tracker", 0.6, 0.6, 0.6, true)
    tt:AddLine("Right-click: mark done and more", 0.6, 0.6, 0.6)
    return
  end
  if st.a and st.a.kind == "crafting" then
    for _, p in ipairs(st.profs or {}) do
      local state = p.done and "|cff33ff66done|r"
        or (p.scanned and (p.n .. " profitable · " .. ns.Money(p.profit)) or "|cff888888not checked yet|r")
      tt:AddDoubleLine(p.name, state, 1, 1, 1, 1, 1, 1)
    end
    if st.ordersN then tt:AddLine(st.ordersN .. " profitable orders, " .. ns.Money(st.gold) .. " profit", 1, 1, 1) end
    tt:AddLine("Click to open the Orders tab.", 0.6, 0.6, 0.6)
    return
  end
  if st.nextIn then
    tt:AddLine(st.eventActive and "Event active now" or ("Next event in " .. ns.Duration(st.nextIn)), 1, 1, 1)
  end
  if st.pickup and not st.inLog then
    tt:AddLine("Pick up at " .. (st.pickup.label or st.pickup.zone or "?"), 1, 1, 1)
  end
  tt:AddDoubleLine("Estimated gold", ns.Money(st.gold), 0.7, 0.7, 0.7, 1, 1, 1)
  tt:AddLine(" ")
  tt:AddLine(st.inLog and "Click: track it" or "Click: directions", 0.6, 0.6, 0.6)
  tt:AddLine("Right-click: mark done and more", 0.6, 0.6, 0.6)
end

------------------------------------------------------------------------
-- Minimap button + summary tooltip
------------------------------------------------------------------------
function UI:ShowSummaryTooltip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:AddLine("Gold Circuit", 1, 0.82, 0)
  local r = ns.BuildRoute(ns.charKey)
  GameTooltip:AddDoubleLine("This character left", ns.Money(r.gold), 0.8, 0.8, 0.8, 1, 1, 1)
  local total, chars = 0, 0
  for _, q in ipairs(ns.AltQueue()) do total = total + q.gold; if q.gold > 0 then chars = chars + 1 end end
  GameTooltip:AddDoubleLine("Army left (" .. chars .. " alts)", ns.Money(total), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Reset in", ResetIn(r.char), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddLine(" ")
  local n, g = ns.WQ.Remaining(ns.GetChar())
  GameTooltip:AddDoubleLine("Gold world quests open", #n .. " · " .. ns.Money(g), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Left-click: dashboard   Right-click: compact tracker", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Shift-click: world quest tracker", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

function UI:CreateMinimapButton()
  local b = CreateFrame("Button", "GoldCircuitMinimapButton", Minimap)
  self.minimapButton = b
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)
  bg:SetTexture(St.ICON)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  b:SetScript("OnClick", function(_, button)
    if IsShiftKeyDown() then ns.WQWindow:Toggle()
    elseif button == "RightButton" then UI:ToggleMini()
    else UI:Toggle() end
  end)
  b:SetScript("OnEnter", function(self) UI:ShowSummaryTooltip(self) end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      ns.DB.settings.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
      UI:UpdateMinimap()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  self:UpdateMinimap()
end

function UI:UpdateMinimap()
  local b = self.minimapButton
  if not b then return end
  local s = ns.DB.settings.minimap
  b:SetShown(not s.hide)
  local angle = math.rad(s.angle or 215)
  local radius = (Minimap:GetWidth() / 2) + 10
  b:ClearAllPoints()
  b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end
