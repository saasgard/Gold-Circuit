local ADDON, ns = ...

-- Standalone, movable list of gold world quests open on this character.
local Win = {}
ns.WQWindow = Win

local St = ns.Style
local WIDTH, ROW_H, MAX_ROWS = 440, 18, 22
local TOP = 66 -- first row, below the title bar, summary and column headers
local ICON_SUPER = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:13:13|t"
local ICON_WATCH = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t"
local SORTS = { "gold", "distance", "time", "zone" }
local SORT_LABEL = { gold = "Gold", distance = "Distance", time = "Time left", zone = "Zone" }
-- columns: x, width, justify
local COL = {
  icon = { 6, 16, "CENTER" }, name = { 24, 170 }, zone = { 198, 92 },
  dist = { 292, 46, "RIGHT" }, time = { 340, 40, "RIGHT" }, gold = { 382, 46, "RIGHT" },
}
local ACCENT = St.ACCENT

local function S() return ns.DB.settings.wqWin end

local function Flat(parent, layer, r, g, b, a)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND")
  t:SetColorTexture(r, g, b, a)
  return t
end

function Win:Create()
  if self.frame then return end
  local DB = ns.DB
  DB.settings.wqWin = DB.settings.wqWin or {}
  local s = S()
  if s.shown == nil then s.shown = false end
  s.sort = s.sort or "gold"

  local f = CreateFrame("Frame", "GoldCircuitWQFrame", UIParent, "BackdropTemplate")
  self.frame = f
  f:SetSize(WIDTH, 120)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(fr) if not s.locked then fr:StartMoving() end end)
  f:SetScript("OnDragStop", function(fr)
    fr:StopMovingOrSizing()
    local point, _, rel, x, y = fr:GetPoint()
    s.pos = { point, rel, x, y }
  end)
  if s.pos then f:SetPoint(s.pos[1], UIParent, s.pos[2], s.pos[3], s.pos[4])
  else f:SetPoint("RIGHT", UIParent, "RIGHT", -320, 0) end
  St.Window(f)
  local _, _, title = St.TitleBar(f, "Gold World Quests")
  self.title = title
  local close = St.Close(f, function() Win:Toggle(false) end)
  local scan = St.IconButton(f, "refresh", "Rescan the map for world quests", function() ns.WQ.Scan() end)
  scan:SetPoint("RIGHT", close, "LEFT", -4, 0)

  -- sort: dropdown
  local sort = St.Dropdown(f, 120, function(b)
    St.Menu(b, function(_, root)
      root:CreateTitle("Sort by")
      for _, k in ipairs(SORTS) do
        root:CreateRadio(SORT_LABEL[k], function() return s.sort == k end, function() s.sort = k; Win:Update() end)
      end
    end)
  end)
  sort:SetPoint("RIGHT", scan, "LEFT", -6, 0)
  self.sortButton = sort

  self.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.summary:SetPoint("TOPLEFT", 10, -33)
  self.summary:SetWidth(WIDTH - 20)
  self.summary:SetJustifyH("LEFT")
  self.summary:SetWordWrap(false)

  -- column headers
  for key, label in pairs({ name = "Quest", zone = "Zone", dist = "Distance", time = "Left", gold = "Gold" }) do
    local c = COL[key]
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", 8 + c[1], -50)
    fs:SetWidth(c[2])
    fs:SetJustifyH(c[3] or "LEFT")
    fs:SetText(label)
  end
  St.Line(f, 63)

  self.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.hint:SetPoint("BOTTOMLEFT", 10, 7)
  self.hint:SetWidth(WIDTH - 100)
  self.hint:SetJustifyH("LEFT")
  self.hint:SetWordWrap(false)
  self.hint:SetText(ns.WQ.CLICK_HINT)

  -- skipped quests: click for a menu to bring them back
  local sk = CreateFrame("Button", nil, f)
  sk:SetSize(80, 14)
  sk:SetPoint("BOTTOMRIGHT", -8, 5)
  sk.text = sk:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sk.text:SetAllPoints()
  sk.text:SetJustifyH("RIGHT")
  sk:SetScript("OnEnter", function(b) b.text:SetFontObject(GameFontHighlightSmall) end)
  sk:SetScript("OnLeave", function(b) b.text:SetFontObject(GameFontDisableSmall) end)
  sk:SetScript("OnClick", function(b)
    St.Menu(b, function(_, root)
      root:CreateTitle("Skipped world quests")
      for _, sq in ipairs(ns.WQ.Skipped()) do
        root:CreateButton((sq.title or sq.qid) .. (sq.permanent and "  |cffff8040(always)|r" or "  |cff888888(this session)|r"),
          function() ns.WQ.Unskip(sq.qid) end)
      end
      root:CreateDivider()
      root:CreateButton("Bring them all back", function() ns.WQ.ClearSkips() end)
    end)
  end)
  self.skipButton = sk

  self.rows = {}
  f:SetShown(s.shown)

  self:CreateNav()

  -- Refresh once a second while you move (distance sort and directions
  -- follow you); standing still, every 10 seconds for the timers.
  local elapsed, idle, lastY, lastX = 0, 0, nil, nil
  f:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 1 then return end
    idle = idle + elapsed
    elapsed = 0
    local y, x = ns.PlayerYX() -- nil in instances: refresh as before
    local moved = not y or y ~= lastY or x ~= lastX
    lastY, lastX = y, x
    if moved or idle >= 10 then
      idle = 0
      Win:Update()
    end
  end)
end

local function RowTooltip(self)
  local q = self.q
  if not q or q.header then return end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(q.title or ("World Quest " .. q.qid), 1, 0.82, 0)
  local qtype = ns.WQ.QuestType(q.qid)
  GameTooltip:AddDoubleLine(q.zone or "?", qtype or "", 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
  local objs = ns.WQ.Objectives(q.qid)
  if #objs > 0 then
    GameTooltip:AddLine(" ")
    for _, o in ipairs(objs) do
      if o.done then GameTooltip:AddLine("- " .. o.text, 0.5, 0.5, 0.5, true)
      else GameTooltip:AddLine("- " .. o.text, 1, 1, 1, true) end
    end
  elseif q.qid > 0 then
    GameTooltip:AddLine("Objectives loading... hover again in a moment.", 0.6, 0.6, 0.6)
  end
  GameTooltip:AddLine(" ")
  if q.isSA then
    GameTooltip:AddDoubleLine("Unlock", q.unlocked and "|cff33ff66unlocked - go do it|r" or
      string.format("%d/%d world quests in %s", q.have, q.need, q.zone or "?"), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("World quests open there", q.openInZone, 0.7, 0.7, 0.7, 1, 1, 1)
    if not q.exact then GameTooltip:AddLine("Progress counted by the addon (the game didn't report it).", 0.6, 0.6, 0.6, true) end
  else
    GameTooltip:AddDoubleLine("Gold", ns.Money(q.gold), 0.7, 0.7, 0.7, 1, 1, 1)
    if q.base and q.gold > q.base then
      GameTooltip:AddDoubleLine("  listed + War Mode", ns.Money(q.base) .. " + " .. ns.Money(q.gold - q.base), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
    end
    if q.saZone then
      GameTooltip:AddLine("Counts toward the Special Assignment in " .. q.zone .. ".", 1, 0.82, 0, true)
    end
  end
  if q.expires then GameTooltip:AddDoubleLine("Time left", ns.Duration(q.expires - time()), 0.7, 0.7, 0.7, 1, 1, 1) end
  GameTooltip:AddDoubleLine("Distance", q.dist and ns.WQ.FormatDistance(q.dist) or "different area", 0.7, 0.7, 0.7, 1, 1, 1)
  local state = ns.WQ.IsSuperTracked(q.qid) and "|cff33ff66active waypoint|r" or (ns.WQ.IsWatched(q.qid) and "tracked" or "not tracked")
  GameTooltip:AddDoubleLine("Status", state, 0.7, 0.7, 0.7, 1, 1, 1)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(ns.WQ.CLICK_HINT, 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function CreateRow(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(WIDTH - 16, ROW_H)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.bg = Flat(b, "BACKGROUND", 1, 1, 1, St.STRIPE_A)
  b.bg:SetAllPoints()
  b.hl = Flat(b, "HIGHLIGHT", unpack(St.HOVER))
  b.hl:SetAllPoints()
  b.accent = Flat(b, "ARTWORK", ACCENT[1], ACCENT[2], ACCENT[3], 1)
  b.accent:SetPoint("TOPLEFT")
  b.accent:SetPoint("BOTTOMLEFT")
  b.accent:SetWidth(2)
  local function FS(key)
    local c = COL[key]
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", c[1], 0)
    fs:SetWidth(c[2])
    fs:SetJustifyH(c[3] or "LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  b.icon, b.name, b.zone, b.dist, b.time, b.gold = FS("icon"), FS("name"), FS("zone"), FS("dist"), FS("time"), FS("gold")
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.label:SetPoint("LEFT", 8, 0)
  b:SetScript("OnClick", function(self, button)
    if self.qid then ns.WQ.OnClick(self.qid, button, self) end
  end)
  b:SetScript("OnEnter", RowTooltip)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

-- One row: a section header ("Special Assignments") or a quest.
local function FillRow(b, q, odd, nearest)
  local isHeader = q.header ~= nil
  for _, k in ipairs({ "icon", "name", "zone", "dist", "time", "gold" }) do b[k]:SetShown(not isHeader) end
  b.label:SetShown(isHeader)
  b:EnableMouse(not isHeader)
  b.qid, b.q = (not isHeader) and q.qid or nil, q
  if isHeader then
    b.label:SetText(St.SECTION_TEXT .. q.header .. "|r  |cff777777" .. (q.note or "") .. "|r")
    b.bg:SetColorTexture(St.SectionColors())
    b.accent:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    b.accent:Show()
    return
  end
  local now = time()
  local super, watched = ns.WQ.IsSuperTracked(q.qid), ns.WQ.IsWatched(q.qid)
  b.bg:SetColorTexture(1, 1, 1, odd and St.STRIPE_A or 0)
  b.accent:SetShown(super or watched)
  local ac = super and St.ACTIVE or ACCENT
  b.accent:SetColorTexture(ac[1], ac[2], ac[3], 1)
  b.icon:SetText(super and ICON_SUPER or (watched and ICON_WATCH or ""))
  b.dist:SetText(ns.WQ.FormatDistance(q.dist))
  local left = q.expires and (q.expires - now) or nil
  b.time:SetText(left and ((left < 4 * 3600 and "|cffff5555" or "|cffaaaaaa") .. ns.Duration(left) .. "|r") or "")
  if q.isSA then
    b.name:SetText(q.short ~= "" and q.short or "Special Assignment")
    b.zone:SetText("|cff888888" .. (q.zone or "?") .. "|r")
    b.gold:SetText(q.unlocked and "|cff66dd77ready|r" or ("|cffc9b27a" .. q.have .. "/" .. q.need .. "|r"))
  else
    b.name:SetText((nearest and "|cff33ff66»|r " or "") .. (q.title or ("WQ " .. q.qid)))
    b.zone:SetText("|cff888888" .. (q.zone or "?") .. "|r" .. (q.saZone and " |cffffd100SA|r" or ""))
    b.gold:SetText(ns.Money(q.gold))
  end
end

function Win:Update()
  local f = self.frame
  if not f or not f:IsShown() then return end
  local s = S()
  self.sortButton.text:SetText("|cff888888Sort:|r " .. (SORT_LABEL[s.sort] or "Gold"))

  local c = ns.GetChar()
  local list, total = ns.WQ.Remaining(c)
  local now = time()
  local pc, px, py = ns.WQ.PlayerWorldPos()
  local saList = ns.WQ.SpecialAssignments(c)
  local saZones = ns.WQ.SAZones(c, saList)
  for _, q in ipairs(list) do
    q.dist = ns.WQ.Distance(q.qid, pc, px, py)
    q.saZone = saZones[(tostring(q.zone or ""):lower():gsub("^the%s+", ""))] and true or false
  end
  if s.sort == "distance" then
    -- nearest first; quests in another area (or with no position) go last, by gold
    table.sort(list, function(a, b)
      if a.dist and b.dist then return a.dist < b.dist end
      if a.dist or b.dist then return a.dist ~= nil end
      return a.gold > b.gold
    end)
  elseif s.sort == "time" then
    table.sort(list, function(a, b) return (a.expires or math.huge) < (b.expires or math.huge) end)
  elseif s.sort == "zone" then
    table.sort(list, function(a, b)
      if (a.zone or "") ~= (b.zone or "") then return (a.zone or "") < (b.zone or "") end
      return a.gold > b.gold
    end)
  end -- "gold" is the default order from Remaining()

  local scanned = ns.DB.wqScanned and (ns.Duration(now - ns.DB.wqScanned) .. " ago") or "pending"
  local note = ""
  local wm = c.warmode or 0
  if wm > 0 then note = string.format("  ·  |cffff8040+%d%% War Mode|r", wm) end
  if s.sort == "distance" and not pc then note = note .. "  ·  |cffff5555your position is unavailable here|r" end
  self.summary:SetText(string.format("|cffffffff%d|r open  ·  %s  ·  |cff888888scanned %s|r%s", #list, ns.Money(total), scanned, note))

  -- The gold world quests first; Special Assignments below them (they're
  -- only worth it when their zone's world quests pay or are quick)
  local rows = {}
  local sas = {}
  for _, sa in ipairs(saList) do
    if not sa.done then
      sa.isSA = true
      sa.dist = ns.WQ.Distance(sa.qid, pc, px, py)
      sas[#sas + 1] = sa
    end
  end
  if #sas > 0 and #list > 0 then rows[#rows + 1] = { header = "World Quests", note = #list .. " · " .. ns.Money(total) } end
  local firstWQ = #rows + 1
  for _, q in ipairs(list) do rows[#rows + 1] = q end
  if #sas > 0 then
    rows[#rows + 1] = { header = "Special Assignments", note = "unlock with 3 world quests in their zone" }
    for _, sa in ipairs(sas) do rows[#rows + 1] = sa end
  end

  local shown = math.min(#rows, MAX_ROWS)
  local odd = false
  for i = 1, shown do
    local q = rows[i]
    local b = self.rows[i] or CreateRow(f)
    self.rows[i] = b
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 8, -(TOP + (i - 1) * ROW_H))
    if q.header then odd = false else odd = not odd end
    FillRow(b, q, odd, s.sort == "distance" and i == firstWQ and q.dist ~= nil)
    b:Show()
  end
  for i = shown + 1, #self.rows do self.rows[i]:Hide(); self.rows[i].qid = nil end

  local extra = 0
  if #rows > MAX_ROWS then
    extra = ROW_H
    self.more = self.more or f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.more:SetPoint("TOPLEFT", 12, -(TOP + MAX_ROWS * ROW_H + 2))
    self.more:SetText(string.format("+%d more — raise the minimum gold in Setup", #rows - MAX_ROWS))
    self.more:Show()
  elseif self.more then
    self.more:Hide()
  end
  if #rows == 0 then
    self.empty = self.empty or f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.empty:SetPoint("TOPLEFT", 12, -(TOP + 4))
    local lvl = c.level or 0
    self.empty:SetText((not ns.DB.settings.wq.enabled) and "World quest tracking is off (Setup tab)."
      or (lvl < ns.MIN_LEVEL and ("World quests start at level " .. ns.MIN_LEVEL .. "."))
      or "No gold world quests open on this character.")
    self.empty:Show()
    extra = extra + ROW_H
  elseif self.empty then
    self.empty:Hide()
  end
  local nSkip = #ns.WQ.Skipped()
  self.skipButton.text:SetText(nSkip > 0 and (nSkip .. " skipped") or "")
  self.skipButton:SetShown(nSkip > 0)
  local navY = TOP + shown * ROW_H + extra + 4
  local navH = self:UpdateNav(navY)
  f:SetHeight(navY + navH + 22)
end

------------------------------------------------------------------------
-- Navigation panel
------------------------------------------------------------------------
local GOLD, GREY, GREEN, RED = "|cffffd100", "|cff888888", "|cff33ff66", "|cffff5555"

function Win:CreateNav()
  local f = self.frame
  self.navSep = f:CreateTexture(nil, "ARTWORK")
  self.navSep:SetColorTexture(St.GOLD[1], St.GOLD[2], St.GOLD[3], St.LINE_A)
  self.navSep:SetHeight(1)
  local function FS(justify)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  self.navFS = FS
  self.navTitle = FS()  -- "To: Ongoing Stoppage (Voidstorm)"
  self.navSub = FS()    -- "~1m 25s · saves 2m vs flying"
  self.navRows = {}     -- one per step: { text, dist }

  -- hover area for the full plan
  local hover = CreateFrame("Frame", nil, f)
  hover:EnableMouse(true)
  hover:SetScript("OnEnter", function(h) Win:NavTooltip(h) end)
  hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.navHover = hover

  -- plain button: pin the portal entrance
  local pin = St.Button(f, 76, "Pin portal", function()
    if Win.hintPoint then
      if OpenWorldMap and Win.hintPoint.map then OpenWorldMap(Win.hintPoint.map) end
    elseif Win.pinPortal then
      ns.Travel.SetPortalPin(Win.pinPortal)
    end
  end)
  pin:Hide()
  self.pinButton = pin

  -- secure button: casts the suggested hearthstone / teleport.
  -- Parented to UIParent (not this window) so the window can still move and
  -- resize in combat; it is detached and hidden whenever combat starts.
  local use = St.Button(UIParent, 76, "Use", nil, "SecureActionButtonTemplate", "GoldCircuitTravelButton")
  use:RegisterForClicks("AnyUp", "AnyDown")
  use:SetAttribute("type", "macro")
  use:SetFrameStrata(f:GetFrameStrata())
  use:Hide()
  use:HookScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:AddLine(b.label or "Use", 1, 0.82, 0)
    GameTooltip:AddLine("Casts it for you.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  use:HookScript("OnLeave", function() GameTooltip:Hide() end)
  self.useButton = use
  f:HookScript("OnHide", function()
    if not (InCombatLockdown and InCombatLockdown()) then use:Hide(); use:ClearAllPoints() end
  end)
end

local function MacroFor(t)
  if t.kind == "spell" then return "/cast " .. (t.name or "") end
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(t.itemID)
  return "/use " .. (name or ("item:" .. t.itemID))
end

function Win:SetUse(tele, anchorY)
  local b = self.useButton
  if InCombatLockdown and InCombatLockdown() then return end -- can't touch secure frames now
  if not tele then
    b:Hide()
    b:ClearAllPoints()
    return
  end
  b:SetAttribute("macrotext", MacroFor(tele))
  b.label = tele.label
  b:ClearAllPoints()
  b:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -8, -anchorY)
  b:SetFrameLevel(self.frame:GetFrameLevel() + 10)
  b:Show()
end

function Win:OnCombat(inCombat)
  if inCombat then
    -- PLAYER_REGEN_DISABLED fires just before lockdown: last chance to detach
    self.useButton:Hide()
    self.useButton:ClearAllPoints()
  else
    self:Update()
  end
end

local function NavRow(self, i)
  local r = self.navRows[i]
  if not r then
    r = { text = self.navFS("LEFT"), dist = self.navFS("RIGHT") }
    self.navRows[i] = r
  end
  return r
end

-- Returns the height used.
function Win:UpdateNav(y)
  local ROW = 15
  -- Navigation turned off in Setup: no directions panel at all
  local on = ns.DB.settings.travel.enabled
  self.navSep:SetShown(on)
  self.navTitle:SetShown(on)
  self.navSub:SetShown(on)
  self.navHover:SetShown(on)
  if not on then
    self.pinButton:Hide()
    for _, r in ipairs(self.navRows) do r.text:Hide(); r.dist:Hide() end
    self.plan, self.goal, self.hint, self.pinPortal, self.hintPoint = nil, nil, nil, nil, nil
    self:SetUse(nil)
    return 0
  end
  self.navSep:ClearAllPoints()
  self.navSep:SetPoint("TOPLEFT", 8, -y)
  self.navSep:SetPoint("TOPRIGHT", -8, -y)
  self.navTitle:ClearAllPoints()
  self.navTitle:SetPoint("TOPLEFT", 10, -(y + 8))
  self.navTitle:SetWidth(WIDTH - 104)
  self.navSub:ClearAllPoints()
  self.navSub:SetPoint("TOPLEFT", 10, -(y + 23))
  self.navSub:SetWidth(WIDTH - 104)
  self.pinButton:ClearAllPoints()
  self.pinButton:SetPoint("TOPRIGHT", -8, -(y + 5))

  local goal = ns.Travel.Goal()
  local start = ns.Travel.Sample()
  local plan, err = ns.Travel.Plan(goal, start)
  local hint = ns.Travel.GameHint(goal)
  self.plan, self.goal, self.hint = plan, goal, hint
  self.pinPortal, self.hintPoint = nil, nil
  local useTele
  local title, sub = "", ""
  local rows = {} -- { text, dist (yards or nil), color }

  local function HintRows()
    local d = start and ns.Travel.Dist(start, hint)
    rows[#rows + 1] = { text = hint.text or "Follow the quest marker", dist = d, first = true }
    rows[#rows + 1] = { text = string.format("%sat %s (%.0f, %.0f)|r", GREY, hint.zone or "?",
      (hint.mx or 0) * 100, (hint.my or 0) * 100), plain = true }
    self.hintPoint = hint
  end

  if goal then
    title = GOLD .. "To:|r " .. goal.label .. GREY .. " (" .. (goal.zone or "?") .. ")|r"
  end

  if not goal then
    title = GOLD .. "Navigation|r"
    rows[1] = { text = GREY .. "Click a world quest to track it,|r", plain = true }
    rows[2] = { text = GREY .. "or set a map pin, to get directions here.|r", plain = true }
  elseif (not plan or not plan.reachable) and hint then
    -- no teleport or known route: follow the game's own route
    sub = GREEN .. "Follow the game's route|r"
    HintRows()
  elseif not plan then
    sub = RED .. (err or "Your position isn't available here.") .. "|r"
  elseif not plan.reachable then
    sub = RED .. "No known way there yet.|r"
    rows[1] = { text = GREY .. "Take a portal or teleport there once to learn it.|r", plain = true }
  else
    sub = GREY .. "~" .. ns.Travel.FormatTime(plan.total) .. "|r"
    local first = plan.steps[1]
    local onlyFlying = first and first.kind == "fly" and #plan.steps == 1
    if not first then
      rows[1] = { text = GREEN .. "You're there.|r", plain = true }
    elseif onlyFlying and hint then
      -- e.g. a cave entrance: the game's step is the better instruction
      HintRows()
    elseif onlyFlying then
      rows[1] = { text = "Fly directly", dist = first.dist, first = true }
    else
      if plan.direct and plan.direct > plan.total then
        sub = sub .. GREY .. "  ·  saves " .. ns.Travel.FormatTime(plan.direct - plan.total) .. " vs flying|r"
      end
      for _, ds in ipairs(ns.Travel.DisplaySteps(plan)) do
        rows[#rows + 1] = { text = ds.text, dist = ds.dist, first = #rows == 0, numbered = true }
      end
    end
    if first and first.kind == "tele" then
      useTele = first.tele
    elseif first and first.kind == "fly" and plan.steps[2] and plan.steps[2].kind == "portal" then
      self.pinPortal = plan.steps[2].portal
    elseif first and first.kind == "portal" then
      self.pinPortal = first.portal
    end
  end

  self.navTitle:SetText(title)
  self.navSub:SetText(sub)
  local top = y + (sub ~= "" and 39 or 25)
  local n = 0
  for i, r in ipairs(rows) do
    n = i
    local fsr = NavRow(self, i)
    local label = r.text
    if r.numbered then label = i .. ". " .. label end
    if r.first and not r.plain then label = GREEN .. label .. "|r" end
    fsr.text:ClearAllPoints()
    fsr.text:SetPoint("TOPLEFT", 10, -(top + (i - 1) * ROW))
    fsr.text:SetWidth(WIDTH - 86)
    fsr.text:SetText(label)
    fsr.text:Show()
    fsr.dist:ClearAllPoints()
    fsr.dist:SetPoint("TOPRIGHT", -10, -(top + (i - 1) * ROW))
    fsr.dist:SetWidth(66)
    fsr.dist:SetText(r.dist and (GREY .. ns.WQ.FormatDistance(r.dist) .. "|r") or "")
    fsr.dist:Show()
  end
  for i = n + 1, #self.navRows do self.navRows[i].text:Hide(); self.navRows[i].dist:Hide() end

  local height = (top - y) + n * ROW + 2
  self.navHover:ClearAllPoints()
  self.navHover:SetPoint("TOPLEFT", 8, -(y + 2))
  self.navHover:SetSize(WIDTH - 100, height - 2)

  self.pinButton:SetText(self.hintPoint and "Show map" or "Pin portal")
  self.pinButton:SetShown((self.pinPortal ~= nil or self.hintPoint ~= nil) and not useTele)
  self:SetUse(useTele, y + 5)
  return height
end

function Win:NavTooltip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:AddLine("Navigation", 1, 0.82, 0)
  local plan, goal = self.plan, self.goal
  if goal then GameTooltip:AddDoubleLine("Target", goal.label, 0.7, 0.7, 0.7, 1, 1, 1) end
  if plan and plan.reachable then
    for i, ds in ipairs(ns.Travel.DisplaySteps(plan)) do
      GameTooltip:AddDoubleLine(i .. ". " .. ds.text, ns.Travel.FormatTime(ds.time or 0), 1, 1, 1, 0.8, 0.8, 0.8)
    end
    GameTooltip:AddDoubleLine("Total", ns.Travel.FormatTime(plan.total), 1, 0.82, 0, 1, 0.82, 0)
    if plan.direct then GameTooltip:AddDoubleLine("Flying directly", ns.Travel.FormatTime(plan.direct), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7) end
  end
  if self.hint then
    local h = self.hint
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("The game's quest marker says:", 1, 0.82, 0)
    GameTooltip:AddLine(string.format("%s (%s %.0f, %.0f)", h.text or "next waypoint", h.zone or "?",
      (h.mx or 0) * 100, (h.my or 0) * 100), 1, 1, 1, true)
    if not self.hintPoint then
      GameTooltip:AddLine("A faster teleport or learned route is suggested instead.", 0.6, 0.6, 0.6, true)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Known travel on this character:", 1, 0.82, 0)
  local c = ns.GetChar()
  if not c.hearth then GameTooltip:AddLine("Hearthstone: use it once to learn where it goes", 0.6, 0.6, 0.6) end
  for _, t in ipairs(ns.Travel.Teleports()) do
    GameTooltip:AddDoubleLine(t.label, t.ready and "ready" or (t.note or "not ready"), 1, 1, 1,
      t.ready and 0.2 or 1, t.ready and 1 or 0.4, t.ready and 0.4 or 0.4)
  end
  GameTooltip:AddDoubleLine("Learned portal links", #ns.DB.travel.portals, 1, 1, 1, 1, 1, 1)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(string.format("Assumes %d yd/s flying and %ds loading screens (Setup).",
    ns.DB.settings.travel.speed or 50, ns.DB.settings.travel.loading or 15), 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

function Win:Toggle(force)
  if not self.frame then return end
  local s = S()
  if force == nil then s.shown = not self.frame:IsShown() else s.shown = force and true or false end
  self.frame:SetShown(s.shown)
  if s.shown then
    self:Update()
    ns.WQ.QueueScan(0.5)
  end
end
