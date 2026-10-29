local ADDON, ns = ...
_G.GoldCircuit = ns

local WEEK = 604800
local LEDGER_MAX = 4000
local HISTORY_WEEKS = 16

local ev = CreateFrame("Frame")
ns.eventFrame = ev
local DB

------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------
-- Chat lines. With "Chat messages" off in Setup, only replies to /gc
-- commands (ns.inCommand) and warnings (ns.Warn) still show.
function ns.Print(...)
  if not ns.inCommand and DB and DB.settings.announce == false then return end
  print("|cffffd100Gold Circuit|r:", ...)
end

-- Something you asked for that couldn't be done: always shown.
function ns.Warn(...)
  print("|cffffd100Gold Circuit|r:", ...)
end

local function lower(s) return s and s:lower() or "" end

-- Every gold amount the addon shows: whole gold with thousands separators
-- and a gold "g" (12,345g); under 1g, silver (45s).
function ns.Money(copper)
  copper = math.floor(copper or 0)
  local neg = copper < 0
  if neg then copper = -copper end
  local g = math.floor(copper / 10000)
  if g == 0 and copper >= 100 then
    return string.format("%s%d|cffc7c7cfs|r", neg and "-" or "", math.floor(copper / 100))
  end
  local s = BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)
  return (neg and "-" or "") .. s .. "|cffffd100g|r"
end

function ns.Duration(sec)
  sec = math.max(0, math.floor(sec or 0))
  local d = math.floor(sec / 86400)
  local h = math.floor(sec % 86400 / 3600)
  local m = math.floor(sec % 3600 / 60)
  if d > 0 then return string.format("%dd %dh", d, h) end
  if h > 0 then return string.format("%dh %dm", h, m) end
  return string.format("%dm", m)
end

-- Cheap "has the player moved?" position (no tables made): world y, x and
-- instance, or nil where it isn't available (instances, secret values).
function ns.PlayerYX()
  if not UnitPosition then return end
  local y, x, _, inst = UnitPosition("player")
  if not y or (issecretvalue and (issecretvalue(y) or issecretvalue(x))) then return end
  return y, x, inst
end

function ns.CharKey()
  local name = UnitName("player") or "Unknown"
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
    or (GetRealmName() or ""):gsub("%s", "")
  return name .. "-" .. realm
end

function ns.ColorName(key, c)
  local name = key:match("^([^-]+)") or key
  local cc = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
  if cc and cc.colorStr then return "|c" .. cc.colorStr .. name .. "|r" end
  return name
end

function ns.IsMyChar(name)
  if not name or not DB then return false end
  if not name:find("-") then
    name = name .. "-" .. ((ns.charKey or ""):match("%-(.+)$") or "")
  end
  name = lower(name):gsub("%s", "")
  for k in pairs(DB.chars) do
    if lower(k) == name then return true end
  end
  return false
end

function ns.NextReset()
  local s = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
    and C_DateAndTime.GetSecondsUntilWeeklyReset()
  if not s or s <= 0 then s = WEEK end
  -- round to the minute so the stamp is stable between calls
  return math.floor((time() + s) / 60 + 0.5) * 60
end

------------------------------------------------------------------------
-- Database
------------------------------------------------------------------------
local DEFAULTS = {
  version = 1,
  chars = {},
  ledger = {},
  questIDs = {},   -- [actKey] = { [questID] = title }
  blocked = {},    -- [questID] = true (forgotten / never re-learn)
  zones = {},      -- [actKey] = learned zone name
  learned = {},    -- [actKey] = { cS, cN, qS, qN } (cache/quest gold averages)
  history = {},    -- [weekResetStamp] = { [charKey] = { i = in, o = out } }
  warband = 0,
  wq = {},           -- [questID] = { title, zone, map, gold, expires } shared across chars
  wqExtraMaps = {},  -- [mapID] = name, added with /gc wqhere
  wqSkip = {},       -- [questID] = title, world quests skipped for good
  eventPOIIDs = {},  -- [areaPoiID] = actKey, events recognised in the map's Events tab
  travel = { tele = {}, portals = {} }, -- learned teleports / portal links (Travel.lua)
  settings = {
    act = {},
    travel = { enabled = true, speed = 50, loading = 15, overhead = 5, minSaving = 20 },
    orders = { priceSource = "auto", minProfit = 50, tsmPrice = "first(DBMinBuyout, DBMarket)" },
    wq = { enabled = true, minGold = 100, minutes = 4 },
    minimap = { angle = 215, hide = false },
    mini = { shown = true, locked = false },
    cashflow = { period = "week", char = "all", src = "all", dir = "all" },
    minLevel = 80,
    announce = true,
    remindSound = true,
  },
}

local function CopyDefaults(src, dst)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

function ns.ActSet(a)
  local s = DB.settings.act[a.key]
  if not s then s = {}; DB.settings.act[a.key] = s end
  if s.enabled == nil then s.enabled = (a.enabled ~= false) end
  -- the built-in estimate, unless you typed your own in Setup
  if s.gold == nil or not s.override then s.gold = a.gold or 0 end
  if s.minutes == nil or not s.minutesSet then s.minutes = a.minutes or 15 end -- unless typed in Setup
  if s.count == nil then s.count = a.count or 1 end
  if s.remind == nil then s.remind = a.remind or 0 end
  return s
end

-- Most completions one week can ever hold (caps turn-in counting).
function ns.ActCap(a)
  if a.key == "special" then return 3 end
  return math.max(ns.ActSet(a).count or 1, a.backlog or 1)
end

-- Completions available this week on a character. Usually the setting,
-- but a skipped week leaves an extra Apex weekly up (backlog), seen either
-- at the weekly reset or from two of them being in the quest log.
function ns.ActCount(c, a)
  local n = ns.ActSet(a).count or 1
  local w = c.weekly and c.weekly[a.key]
  if a.backlog then
    if w and w.avail then n = math.max(n, w.avail) end
    local inLog = c.inLogN and c.inLogN[a.key] or 0
    if inLog > 0 then n = math.max(n, math.min(a.backlog, inLog + (w and w.done or 0))) end
  end
  if w and w.done > n then n = w.done end
  return n
end

-- Remembers the week an activity was last done (for the backlog check).
function ns.NoteDone(c, key)
  c.lastDoneWeek = c.lastDoneWeek or {}
  c.lastDoneWeek[key] = c.weekReset
end

function ns.GetChar(key)
  key = key or ns.charKey or ns.CharKey()
  local c = DB.chars[key]
  if not c then
    c = { weekly = {}, wIn = {}, wOut = {}, crafting = { count = 0, gold = 0 },
          allIn = 0, allOut = 0, inLog = {} }
    DB.chars[key] = c
  end
  c.weekly = c.weekly or {}
  c.wIn = c.wIn or {}
  c.wOut = c.wOut or {}
  c.crafting = c.crafting or { count = 0, gold = 0 }
  c.inLog = c.inLog or {}
  c.allIn = c.allIn or 0
  c.allOut = c.allOut or 0
  return c
end

function ns.Weekly(c, key)
  local w = c.weekly[key]
  if not w then w = { done = 0, gold = 0 }; c.weekly[key] = w end
  return w
end

local function Sum(t)
  local n = 0
  for _, v in pairs(t) do n = n + v end
  return n
end
ns.Sum = Sum

local function Archive(c, key)
  local stamp = c.weekReset
  if not stamp then return end
  local i, o = Sum(c.wIn), Sum(c.wOut)
  if i == 0 and o == 0 then return end
  DB.history[stamp] = DB.history[stamp] or {}
  DB.history[stamp][key] = { i = i, o = o }
  -- prune
  local stamps = {}
  for s in pairs(DB.history) do stamps[#stamps + 1] = s end
  table.sort(stamps)
  while #stamps > HISTORY_WEEKS do
    DB.history[table.remove(stamps, 1)] = nil
  end
end

-- Rolls a character over to the new week if its reset time has passed.
function ns.CheckReset(c, key)
  local now = time()
  if not c.weekReset then
    c.weekReset = ns.NextReset()
    return
  end
  if now >= c.weekReset then
    Archive(c, key)
    c.weekly, c.wIn, c.wOut = {}, {}, {}
    c.crafting = { count = 0, gold = 0 }
    c.inLog = {}
    while c.weekReset <= now do c.weekReset = c.weekReset + WEEK end
    -- a whole week without doing it: last week's is still waiting
    for _, a in ipairs(ns.ACTIVITIES) do
      local last = a.backlog and c.lastDoneWeek and c.lastDoneWeek[a.key]
      if last and c.weekReset - last >= 2 * WEEK - 3600 then ns.Weekly(c, a.key).avail = a.backlog end
    end
  end
end

function ns.CheckAllResets()
  for key, c in pairs(DB.chars) do ns.CheckReset(c, key) end
end

------------------------------------------------------------------------
-- Activity matching / quest learning
------------------------------------------------------------------------
local titles = {}

local function TitleFor(qid)
  local t = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(qid)
  if t and t ~= "" then titles[qid] = t; return t end
  return titles[qid]
end

function ns.MatchTitle(title)
  if not title or title == "" then return end
  local lt = lower(title)
  for _, a in ipairs(ns.ACTIVITIES) do
    for _, p in ipairs(a.patterns or {}) do
      if lt:find(lower(p), 1, true) then return a end
    end
  end
end

-- Only by known quest ID (no title guessing).
function ns.ActivityForID(qid)
  for _, a in ipairs(ns.ACTIVITIES) do
    local ids = DB.questIDs[a.key]
    if ids and ids[qid] then return a end
  end
end

local function IsCampaign(qid)
  if not qid then return false end
  if C_CampaignInfo and C_CampaignInfo.IsCampaignQuest then
    local ok, v = pcall(C_CampaignInfo.IsCampaignQuest, qid)
    if ok and v then return true end
  end
  if C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo then
    local idx = C_QuestLog.GetLogIndexForQuestID(qid)
    local info = idx and C_QuestLog.GetInfo(idx)
    if info and info.campaignID and info.campaignID > 0 then return true end
  end
  return false
end
ns.IsCampaign = IsCampaign

function ns.ActivityForQuest(qid, title)
  for _, a in ipairs(ns.ACTIVITIES) do
    local ids = DB.questIDs[a.key]
    if ids and ids[qid] then return a end
  end
  if DB.blocked[qid] then return end
  if IsCampaign(qid) then return end -- story quests like "The Aqir Swarm"
  return ns.MatchTitle(title)
end

function ns.ActivityForCacheID(itemID)
  if not itemID then return end
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.cacheIDs and a.cacheIDs[itemID] then return a end
  end
end

function ns.ActivityForCache(itemName)
  if not itemName then return end
  local ln = lower(itemName)
  for _, a in ipairs(ns.ACTIVITIES) do
    for _, cn in ipairs(a.caches or {}) do
      if ln:find(lower(cn), 1, true) then return a end
    end
  end
end

local function IsGenericContainer(itemName)
  local ln = lower(itemName)
  for _, w in ipairs(ns.GENERIC_CONTAINER_WORDS) do
    if ln:find(lower(w), 1, true) then return true end
  end
end

local function IsDailyInLog(qid)
  if not (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo) then return false end
  local idx = C_QuestLog.GetLogIndexForQuestID(qid)
  local info = idx and C_QuestLog.GetInfo(idx)
  local daily = Enum and Enum.QuestFrequency and Enum.QuestFrequency.Daily
  return info and daily and info.frequency == daily
end

function ns.Learn(a, qid, title)
  if not a or not qid or DB.blocked[qid] then return end
  DB.questIDs[a.key] = DB.questIDs[a.key] or {}
  if DB.questIDs[a.key][qid] then return end
  DB.questIDs[a.key][qid] = title or ("Quest " .. qid)
  if DB.settings.announce then
    ns.Print(string.format("learned |cffffd100%s|r = quest %d (%s). Wrong? /gc forget %s",
      a.name, qid, title or "?", a.key))
  end
end

-- Scan the quest log: learn IDs and note which weeklies are picked up.
function ns.ScanQuestLog()
  if not C_QuestLog.GetNumQuestLogEntries then return end
  local c = ns.GetChar()
  wipe(c.inLog)
  c.inLogQid, c.inLogN = {}, {}
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID and info.questID > 0 then
      titles[info.questID] = info.title
      local a = ns.ActivityForQuest(info.questID, info.title)
      if a then
        if not IsDailyInLog(info.questID) then ns.Learn(a, info.questID, info.title) end
        c.inLog[a.key] = true
        c.inLogQid[a.key] = info.questID
        c.inLogN[a.key] = (c.inLogN[a.key] or 0) + 1
      end
    end
  end
end

-- Uses learned IDs to detect completions made before the addon was
-- installed, on other PCs, or while the addon was disabled.
function ns.SnapshotCompletion()
  if not C_QuestLog.IsQuestFlaggedCompleted then return end
  local c = ns.GetChar()
  for _, a in ipairs(ns.ACTIVITIES) do
    local ids = DB.questIDs[a.key]
    -- Special Assignments rotate and stay flagged completed after they're
    -- gone; they're counted from the map instead (WQ.SpecialAssignments).
    if ids and a.key ~= "special" then
      local n = 0
      for qid in pairs(ids) do
        if C_QuestLog.IsQuestFlaggedCompleted(qid) and not ns.IgnoredPre90(c, qid) then n = n + 1 end
      end
      if n > 0 then
        local w = ns.Weekly(c, a.key)
        if not w.manual then
          w.done = math.max(w.done, math.min(n, ns.ActCap(a)))
          ns.NoteDone(c, a.key)
        end
      end
    end
  end
  -- map events: a learned hidden weekly flag (see LearnEventFlags)
  for key, flags in pairs(DB.eventFlags or {}) do
    local a = ns.ACT_BY_KEY[key]
    if a then
      for id in pairs(flags) do
        if C_QuestLog.IsQuestFlaggedCompleted(id) then ns.MarkEventDone(a, "weekly flag " .. id); break end
      end
    end
  end
  c.crafting.count = c.crafting.count or 0
  local wc = ns.Weekly(c, "crafting")
  if not wc.manual then wc.done = (c.crafting.count > 0) and 1 or 0 end
  ns.UpdateFamilies(c)
end

------------------------------------------------------------------------
-- Quest kinds that take turns (Apex Cache: the "Midnight:" weeklies and
-- Trailing Xal'atath). Each kind resets every second week, the two a week
-- apart. When this character completed each kind is remembered
-- (c.famDone[actKey][kind] = time); which weeks a kind resets is learned
-- from its completed flag clearing, or staying, over a weekly reset
-- (DB.famPhase[actKey][kind] = a reset time of that kind).
------------------------------------------------------------------------
function ns.Families(a)
  local list = {}
  for fam in pairs(a.families) do list[#list + 1] = fam end
  table.sort(list)
  table.insert(list, 1, "main")
  return list
end

local function FamilyOf(a, qid)
  for fam, ids in pairs(a.families) do
    if ids[qid] then return fam end
  end
  return "main"
end

-- A reset time of this kind, if known (the other kind resets the week in between).
local function Phase(a, fam)
  local ph = DB.famPhase and DB.famPhase[a.key]
  if not ph then return end
  if ph[fam] then return ph[fam] end
  for _, s in pairs(ph) do return s + WEEK end
end

-- Is this kind done for its current two weeks on a character?
function ns.FamilyDone(c, a, fam)
  local t = c.famDone and c.famDone[a.key] and c.famDone[a.key][fam]
  if not t then return false end
  local thisWeek = (c.weekReset or ns.NextReset()) - WEEK -- the last weekly reset
  local p = Phase(a, fam)
  if not p then return t >= thisWeek end -- reset weeks not learned yet: this week only
  local weeks = math.floor((thisWeek - p) / WEEK + 0.5)
  local last = (weeks % 2 == 0) and thisWeek or (thisWeek - WEEK)
  return t >= last
end

-- From the completed flags on the character you're on.
function ns.UpdateFamilies(c)
  local now = time()
  local thisWeek = (c.weekReset or ns.NextReset()) - WEEK
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.families then
      local flagged = {}
      for qid in pairs(DB.questIDs[a.key] or {}) do
        if C_QuestLog.IsQuestFlaggedCompleted(qid) and not ns.IgnoredPre90(c, qid) then flagged[FamilyOf(a, qid)] = true end
      end
      c.famDone = c.famDone or {}
      local done = c.famDone[a.key] or {}
      c.famDone[a.key] = done
      for _, fam in ipairs(ns.Families(a)) do
        local t = done[fam]
        -- done last week: still completed now means it didn't reset this
        -- week (so it resets next week); cleared means it did
        if t and t < thisWeek and t >= thisWeek - WEEK then
          DB.famPhase = DB.famPhase or {}
          DB.famPhase[a.key] = DB.famPhase[a.key] or {}
          DB.famPhase[a.key][fam] = flagged[fam] and (thisWeek + WEEK) or thisWeek
        end
        if flagged[fam] then
          if not ns.FamilyDone(c, a, fam) then done[fam] = now end
        else
          done[fam] = nil
        end
      end
    end
  end
end

-- Crafting professions (skill line IDs); gathering ones don't take orders.
local CRAFTING_SKILL_LINES = {
  [171] = true, -- Alchemy
  [164] = true, -- Blacksmithing
  [333] = true, -- Enchanting
  [202] = true, -- Engineering
  [773] = true, -- Inscription
  [755] = true, -- Jewelcrafting
  [165] = true, -- Leatherworking
  [197] = true, -- Tailoring
}

-- Records which crafting professions this character has.
function ns.UpdateProfessions(c)
  c = c or ns.GetChar()
  local p1, p2 = GetProfessions()
  -- professions read as empty while logging out; only believe "none"
  -- if it's still none a few seconds later
  if not (p1 or p2) and c.hasProf and not c.profRecheck then
    c.profRecheck = true
    C_Timer.After(5, function() ns.UpdateProfessions(c); ns.Refresh() end)
    return
  end
  c.profRecheck = nil
  c.hasProf = (p1 or p2) and true or false
  local crafts = {}
  for _, idx in ipairs({ p1, p2 }) do
    if idx and GetProfessionInfo then
      local name, _, _, _, _, _, skillLine = GetProfessionInfo(idx)
      if skillLine and CRAFTING_SKILL_LINES[skillLine] then crafts[#crafts + 1] = name end
    end
  end
  c.craftProfs = crafts
  c.hasCraftProf = #crafts > 0
end

-- atLogout: on a real logout the game has already cleared your gold and
-- professions (GetMoney() = 0), so only the time is updated then.
function ns.SnapshotChar(atLogout)
  local c = ns.GetChar()
  c.lastSeen = time()
  if atLogout then return end
  local _, class = UnitClass("player")
  c.class = class
  c.level = UnitLevel("player")
  c.money = GetMoney()
  c.lastSeen = time()
  ns.UpdateProfessions(c)
  if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType and Enum.BankType.Account then
    local ok, m = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    if ok and m then DB.warband = m end
  end
end

------------------------------------------------------------------------
-- Cashflow: context-based source attribution
------------------------------------------------------------------------
local timed = {}       -- one-shot / short-lived contexts
local windows = {}     -- open NPC windows
local WINDOW_PRIORITY = { "Transfer", "Crafting Order", "Auction", "Trade", "Mail", "Vendor", "Trainer", "Flight", "Loot" }
local pendingQuest     -- quest money announced before PLAYER_MONEY
local lastMoney

-- The gold you receive can be higher than the quest's listed reward
-- (War Mode and other bonuses), so match with some headroom.
local function QuestMoneyMatches(listed, received)
  return received >= listed and received <= listed * 1.6 + 1
end

function ns.PushContext(src, detail, key, dur, once)
  timed[#timed + 1] = { src = src, detail = detail, key = key, expires = GetTime() + (dur or 3), once = once }
end

local function SetWindow(src, on) windows[src] = on or nil end

local function Resolve(delta)
  local now = GetTime()
  if pendingQuest and now - pendingQuest.t < 3 and QuestMoneyMatches(pendingQuest.amount, delta) then
    local p = pendingQuest; pendingQuest = nil
    return p.src or "Quest", p.detail, p.key
  end
  for i = #timed, 1, -1 do
    if timed[i].expires < now then table.remove(timed, i) end
  end
  local c = timed[#timed]
  if c then
    if c.once then table.remove(timed) end
    return c.src, c.detail, c.key
  end
  for _, w in ipairs(WINDOW_PRIORITY) do
    if windows[w] then return w end
  end
  return "Other"
end

local function Apply(c, e, sign)
  if e.s == "Transfer" then return end
  local amt = e.a * sign
  if e.a > 0 then
    c.wIn[e.s] = (c.wIn[e.s] or 0) + amt
    c.allIn = c.allIn + amt
  else
    c.wOut[e.s] = (c.wOut[e.s] or 0) - amt
    c.allOut = c.allOut - amt
  end
  if e.k and e.a > 0 then
    local w = ns.Weekly(c, e.k)
    w.gold = w.gold + amt
    local L = DB.learned[e.k] or { cS = 0, cN = 0, qS = 0, qN = 0 }
    DB.learned[e.k] = L
    if e.s == "Weekly Cache" or e.s == "Special Assignment" then
      L.cS = L.cS + amt; L.cN = L.cN + sign
    elseif e.s == "Quest" or e.s == "World Quest" then
      L.qS = L.qS + amt; L.qN = L.qN + sign
    end
  end
  if e.s == "Crafting Order" and e.a > 0 then
    c.crafting.gold = (c.crafting.gold or 0) + amt
  end
end

function ns.Record(amount, src, detail, key)
  local c = ns.GetChar()
  ns.CheckReset(c, ns.charKey)
  local e = { t = time(), c = ns.charKey, a = amount, s = src, d = detail, k = key }
  local L = DB.ledger
  L[#L + 1] = e
  if #L > LEDGER_MAX + 200 then
    local keep = {}
    for i = #L - LEDGER_MAX + 1, #L do keep[#keep + 1] = L[i] end
    DB.ledger = keep
  end
  Apply(c, e, 1)
  ns.lastEntry, ns.lastEntryTime = e, GetTime()
  ns.session.net = ns.session.net + ((src ~= "Transfer") and amount or 0)
  if src == "World Quest" and amount > 0 and ns.WQ then ns.WQ.OnGold(amount) end
  ns.Refresh()
end

function ns.Reclassify(e, src, detail, key)
  local c = ns.GetChar(e.c)
  Apply(c, e, -1)
  e.s, e.d, e.k = src, detail or e.d, key
  Apply(c, e, 1)
  if src == "World Quest" and e.a > 0 and ns.WQ then ns.WQ.OnGold(e.a) end
  ns.Refresh()
end

local function OnMoney()
  local m = GetMoney()
  if not lastMoney then lastMoney = m; return end
  -- money reads 0 while logging out: don't log that as spending it all
  -- (or save 0 as this character's gold)
  if m == 0 and lastMoney > 0 then lastMoney = 0; return end
  local delta = m - lastMoney
  lastMoney = m
  ns.GetChar().money = m
  if delta == 0 then return end
  local src, detail, key = Resolve(delta)
  ns.Record(delta, src, detail, key)
end

------------------------------------------------------------------------
-- Hooks
------------------------------------------------------------------------
local function OnUseContainerItem(bag, slot)
  if not (C_Container and C_Container.GetContainerItemInfo) then return end
  local info = C_Container.GetContainerItemInfo(bag, slot)
  local link = info and info.hyperlink
  local name = link and link:match("%[(.-)%]")
  if not name then return end
  local a = ns.ActivityForCacheID(info.itemID) or ns.ActivityForCache(name)
  if a then
    ns.PushContext(a.cacheSource or "Weekly Cache", name, a.key, 10, true)
  elseif IsGenericContainer(name) then
    ns.PushContext("Container", name, nil, 10, true)
  end
end

local function OnTakeMail(index)
  if not GetInboxHeaderInfo then return end
  local _, _, sender, subject, money = GetInboxHeaderInfo(index)
  if not money or money <= 0 then return end
  local src = "Mail"
  local invoiceType = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
  local ls, lsub = lower(sender), lower(subject)
  if ns.IsMyChar(sender) then
    src = "Transfer"
  elseif invoiceType == "seller" or invoiceType == "seller_temp_invoice" or lsub:find("auction", 1, true) then
    src = "Auction"
  elseif lsub:find("crafting order", 1, true) or lsub:find("order", 1, true) and ls:find("craft", 1, true) then
    src = "Crafting Order"
  end
  ns.PushContext(src, (sender or "?") .. ": " .. (subject or ""), nil, 6, true)
end

local function OnSendMail(recipient)
  local m = GetSendMailMoney and GetSendMailMoney()
  if m and m > 0 then
    ns.PushContext(ns.IsMyChar(recipient) and "Transfer" or "Mail", "to " .. (recipient or "?"), nil, 6, true)
  end
end

local function InstallHooks()
  if C_Container and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)
  end
  if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", OnTakeMail) end
  if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", OnTakeMail) end
  if SendMail then hooksecurefunc("SendMail", OnSendMail) end
  if C_Mail and C_Mail.SendMail then
    hooksecurefunc(C_Mail, "SendMail", function(r) OnSendMail(r) end)
  end
  if RepairAllItems then
    hooksecurefunc("RepairAllItems", function(guild)
      ns.PushContext(guild and "Transfer" or "Repair", guild and "guild repair" or nil, nil, 3, true)
    end)
  end
  if C_Bank then
    for _, fn in ipairs({ "DepositMoney", "WithdrawMoney" }) do
      if C_Bank[fn] then
        hooksecurefunc(C_Bank, fn, function() ns.PushContext("Transfer", "Warband bank", nil, 4, true) end)
      end
    end
  end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local INTERACTION_SOURCES -- built lazily from Enum.PlayerInteractionType
local function InteractionSource(t)
  if not INTERACTION_SOURCES then
    INTERACTION_SOURCES = {}
    local E = Enum and Enum.PlayerInteractionType
    if E then
      local map = {
        Merchant = "Vendor", Banker = "Transfer", AccountBanker = "Transfer",
        GuildBanker = "Transfer", MailInfo = "Mail", Auctioneer = "Auction",
        TaxiNode = "Flight", TradePartner = "Trade", Trainer = "Trainer",
        ProfessionsCustomerOrder = "Crafting Order", ProfessionsCraftingOrder = "Crafting Order",
        CraftingOrder = "Crafting Order",
      }
      for k, src in pairs(map) do
        if E[k] then INTERACTION_SOURCES[E[k]] = src end
      end
    end
  end
  return INTERACTION_SOURCES[t]
end

local scanPending = false
local function QueueScan()
  if scanPending then return end
  scanPending = true
  C_Timer.After(1, function()
    scanPending = false
    ns.ScanQuestLog()
    ns.SnapshotCompletion()
    ns.Refresh()
  end)
end

local handlers = {}

function handlers.ADDON_LOADED(name)
  if name == "Blizzard_Professions" then
    if ns.Orders and DB then ns.Orders.HookOrdersPage() end
    return
  end
  if name ~= ADDON then return end
  GoldCircuitDB = GoldCircuitDB or {}
  DB = GoldCircuitDB
  CopyDefaults(DEFAULTS, DB)
  ns.DB = DB
  for _, a in ipairs(ns.ACTIVITIES) do
    ns.ActSet(a)
    -- built-in quest IDs (a /gc forget still blocks them)
    for qid, title in pairs(a.ids or {}) do
      if not DB.blocked[qid] then
        DB.questIDs[a.key] = DB.questIDs[a.key] or {}
        DB.questIDs[a.key][qid] = DB.questIDs[a.key][qid] or title
      end
    end
  end
  -- the Soiree world quest was matched to Apex by its title and its turn-in
  -- counted as the Apex Cache: clear that (real ones come back from the
  -- quest flags)
  if DB.questIDs.apex and DB.questIDs.apex[91966] then
    for _, c in pairs(DB.chars or {}) do
      local w = c.weekly and c.weekly.apex
      if w and not w.manual then w.done, w.at = 0, nil end
    end
  end
  for qid in pairs(ns.NOT_WEEKLY) do DB.blocked[qid] = true end
  -- drop them if already learned; their completed flag made this week's
  -- snapshot count the activity as done (a real turn-in sets w.at)
  for key, ids in pairs(DB.questIDs) do
    local hit = false
    for qid in pairs(ns.NOT_WEEKLY) do
      if ids[qid] then ids[qid] = nil; hit = true end
    end
    if hit then
      for _, c in pairs(DB.chars or {}) do
        local w = c.weekly and c.weekly[key]
        if w and not w.manual and not w.at then w.done = 0 end
      end
    end
  end
  -- built-in hidden weekly flags (unless one turned out not to be weekly)
  DB.eventFlags = DB.eventFlags or {}
  DB.eventFlagsDropped = DB.eventFlagsDropped or {}
  for _, a in ipairs(ns.ACTIVITIES) do
    for id in pairs(a.weeklyFlags or {}) do
      if not DB.eventFlagsDropped[id] then
        DB.eventFlags[a.key] = DB.eventFlags[a.key] or {}
        DB.eventFlags[a.key][id] = DB.eventFlags[a.key][id] or 0
      end
    end
  end
  -- one-time updates to saved settings
  DB.migrated = DB.migrated or {}
  if not DB.migrated.aqirPatterns then
    local ids = DB.questIDs.aqir
    local seeded = ns.ACT_BY_KEY.aqir.ids or {}
    for qid, title in pairs(ids or {}) do
      local t = tostring(title):lower()
      if not seeded[qid] and not (t:find("aqir invasion", 1, true) or t:find("aqir assault", 1, true)) then
        ids[qid] = nil
      end
    end
    for _, c in pairs(DB.chars) do
      if c.inLog then c.inLog.aqir = nil end
      if c.inLogQid then c.inLogQid.aqir = nil end
    end
    DB.migrated.aqirPatterns = true
  end
  if not DB.migrated.aqirPickup then
    if DB.pickups then DB.pickups.aqir = nil end -- was the story quest giver
    DB.migrated.aqirPickup = true
  end
  if not DB.migrated.aqirOff then
    local s = DB.settings.act.aqir
    if s then
      s.enabled = false               -- hourly ~1k event: off by default now
      if not s.override then s.gold = 1000 end
      if s.minutes == 25 then s.minutes = 15 end
    end
    DB.migrated.aqirOff = true
  end
  -- bonus/hidden quests learned on a repeat run, e.g. 97316 "Reward Quest (DNT)"
  if not DB.migrated.dntQuests then
    for _, ids in pairs(DB.questIDs) do
      for qid, title in pairs(ids) do
        if tostring(title):find("DNT", 1, true) then ids[qid] = nil; DB.blocked[qid] = true end
      end
    end
    DB.migrated.dntQuests = true
  end
  -- the Aqir reminder was on (5 min) by default in 0.12; it's opt-in now
  -- the Surplus Bag of Party Favors is the Runestones reward (it came along
  -- with the Soiree into the Apex Cache): move its gold to Runestones
  if not DB.migrated.surplusBag then
    for _, e in ipairs(DB.ledger) do
      if e.d == "Surplus Bag of Party Favors" and e.k ~= "runestones" and e.a > 0 then
        local old = DB.learned[e.k or ""]
        if old and (old.cN or 0) > 0 then old.cS, old.cN = old.cS - e.a, old.cN - 1 end
        local L = DB.learned.runestones or { cS = 0, cN = 0, qS = 0, qN = 0 }
        L.cS, L.cN = L.cS + e.a, L.cN + 1
        DB.learned.runestones = L
        local c = DB.chars[e.c]
        if c and c.weekly and c.weekReset and e.t >= c.weekReset - WEEK then
          if e.k and c.weekly[e.k] then c.weekly[e.k].gold = math.max(0, (c.weekly[e.k].gold or 0) - e.a) end
          c.weekly.runestones = c.weekly.runestones or { done = 0, gold = 0 }
          c.weekly.runestones.gold = (c.weekly.runestones.gold or 0) + e.a
        end
        e.k = "runestones"
      end
    end
    DB.migrated.surplusBag = true
  end
  -- removed / merged activities: Soiree quest IDs join the Apex Cache,
  -- Prey Hunts and Amani Abyss are dropped
  for key, into in pairs(ns.REMOVED_ACTIVITIES) do
    if into then
      for qid, title in pairs(DB.questIDs[key] or {}) do
        DB.questIDs[into] = DB.questIDs[into] or {}
        DB.questIDs[into][qid] = DB.questIDs[into][qid] or title
      end
    end
    for _, e in ipairs(DB.ledger) do
      if e.k == key then e.k = into or nil end
    end
    DB.questIDs[key], DB.settings.act[key], DB.learned[key], DB.zones[key] = nil, nil, nil, nil
    if DB.pickups then DB.pickups[key] = nil end
    for _, c in pairs(DB.chars) do
      if c.weekly then c.weekly[key] = nil end
      if c.inLog then c.inLog[key] = nil end
      if c.inLogQid then c.inLogQid[key] = nil end
      if c.inLogN then c.inLogN[key] = nil end
      if c.lastDoneWeek then c.lastDoneWeek[key] = nil end
    end
  end
  -- pickups were learned from where you stood when accepting (or a
  -- continent map): found again from the quest giver
  if not DB.migrated.pickupsNPC then
    DB.pickups = {}
    DB.migrated.pickupsNPC = true
  end
  if not DB.migrated.remindOff then
    local s = DB.settings.act.aqir
    if s and s.remind == 5 then s.remind = 0 end
    DB.migrated.remindOff = true
  end
  -- event spots were taken from whichever map showed the marker first,
  -- often a neighbouring zone's edge (Skinning Den in Zul'Aman, not Harandar)
  if not DB.migrated.eventSpotMaps then
    DB.eventPOIPos = nil
    if DB.eventSpots then DB.eventSpots.abundance = nil end
    DB.zones.abundance = nil
    DB.migrated.eventSpotMaps = true
  end
  -- Saltheril's Soiree in the Events tab isn't the Apex Cache's (its
  -- reward is the Runestones one): forget it was matched to Apex
  if not DB.migrated.soireeRunestones then
    for poiID, key in pairs(DB.eventPOIIDs or {}) do
      if key == "apex" then DB.eventPOIIDs[poiID] = nil end
    end
    if DB.eventSpots then DB.eventSpots.apex = nil end
    DB.zones.apex = nil
    DB.migrated.soireeRunestones = true
  end
  -- the Soiree's "reward claimed" marked Runestones done on picking up the
  -- quest: clear it (a real completion comes back from the quest flags)
  if not DB.migrated.soireeNotDone then
    for _, c in pairs(DB.chars) do
      local w = c.weekly and c.weekly.runestones
      if w and not w.manual then w.done, w.at = 0, nil end
    end
    DB.migrated.soireeNotDone = true
  end
  -- Special Assignment caches have their own cashflow line now: move
  -- them out of "Weekly Cache" (this week's totals too)
  if not DB.migrated.saCacheSource then
    for _, e in ipairs(DB.ledger) do
      if e.k == "special" and e.s == "Weekly Cache" then
        e.s = "Special Assignment"
        local c = DB.chars[e.c]
        if c and c.wIn and c.weekReset and e.t >= c.weekReset - WEEK and e.a > 0 then
          c.wIn["Weekly Cache"] = math.max(0, (c.wIn["Weekly Cache"] or 0) - e.a)
          c.wIn["Special Assignment"] = (c.wIn["Special Assignment"] or 0) + e.a
        end
      end
    end
    DB.migrated.saCacheSource = true
  end
  -- most weeklies can be done from 80 now (only some need 90)
  if not DB.migrated.minLevel80 then
    if DB.settings.minLevel == 90 then DB.settings.minLevel = 80 end
    DB.migrated.minLevel80 = true
  end
  for _, ids in pairs(DB.questIDs) do
    for qid in pairs(ns.BAD_IDS) do ids[qid] = nil end
  end
end

function handlers.PLAYER_LOGIN()
  ns.charKey = ns.CharKey()
  ns.session = { start = time(), net = 0 }
  ns.ready = true
  local c = ns.GetChar()
  ns.CheckAllResets()
  c.weekReset = ns.NextReset()
  local savedLevel, savedSeen = c.level, c.lastSeen
  ns.SnapshotChar()
  -- reached 90 while the addon wasn't running (earlier this week)
  if savedLevel and savedLevel < 90 and (c.level or 0) >= 90 and savedSeen and savedSeen >= c.weekReset - WEEK then
    ns.OnReached90(c)
  end
  lastMoney = GetMoney()
  InstallHooks()
  ns.ScanQuestLog()
  ns.CheckFlagRollover(c)
  ns.SnapshotCompletion()
  ns.CheckEventTurnins()
  ns.FixSACount(c, ns.charKey)
  ns.SnapshotQuests()
  if ns.UI then ns.UI:Init() end
  C_Timer.NewTicker(30, function()
    ns.CheckAllResets()
    ns.Refresh()
  end)
  if ns.Travel then ns.Travel.Init() end
  if ns.WQ then ns.WQ.UpdateWarMode() end
  if ns.Orders then ns.Orders.InstallHooks() end
  if ns.WQ then
    ns.WQ.QueueScan(5)
    C_Timer.NewTicker(300, function() ns.WQ.Scan() end)
    C_Timer.After(3, function() pcall(ns.WQ.ScanScheduler) end)
    C_Timer.NewTicker(15, function()
      pcall(ns.WQ.ScanScheduler)
      ns.CheckReminders()
      ns.MaybeSnapshotQuests()
    end)
  end
end

------------------------------------------------------------------------
-- Hidden weekly "done" flags for map events (Aqir).
-- The game marks a hidden quest completed when you get the week's reward,
-- but which quest isn't known in advance. When the weekly reward bag
-- arrives, the quests that became completed since just before the event
-- (minus ones you turned in yourself) are remembered as candidates. Any
-- character with one of them completed is done this week - including runs
-- the addon never saw. Candidates still completed right after a weekly
-- reset aren't weekly flags, and are dropped.
------------------------------------------------------------------------
local qsnap, qsnapAt, qsnapTurned = nil, 0, {}

local function CompletedSet()
  if not (C_QuestLog.GetAllCompletedQuestIDs) then return end
  local ok, ids = pcall(C_QuestLog.GetAllCompletedQuestIDs)
  if not ok or type(ids) ~= "table" then return end
  local set = {}
  for _, id in ipairs(ids) do set[id] = true end
  return set
end

-- Only while some map event's weekly flag is still unknown: copying the
-- whole completed-quest history is the costliest thing the addon does.
local function FlagsNeeded()
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.mapEvent and ns.ActSet(a).enabled
       and not (DB.eventFlags and DB.eventFlags[a.key] and next(DB.eventFlags[a.key])) then return true end
  end
  return false
end

function ns.SnapshotQuests()
  if not FlagsNeeded() then qsnap = nil; return end
  local set = CompletedSet()
  if set then qsnap, qsnapAt, qsnapTurned = set, GetTime(), {} end
end

-- Keep the snapshot from just before an event (not refreshed while one
-- of them is running, so the run's flags show up in the difference).
function ns.MaybeSnapshotQuests()
  if not FlagsNeeded() then return end
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.mapEvent and ns.WQ and ns.WQ.EventLive(a, true) then return end
  end
  if GetTime() - qsnapAt > 120 then ns.SnapshotQuests() end
end

function ns.NoteTurnedIn(qid) qsnapTurned[qid] = true end

function ns.LearnEventFlags(a)
  if not qsnap then return end
  local before, turned = qsnap, qsnapTurned
  C_Timer.After(3, function() -- the flag can land a moment after the reward
    local now = CompletedSet()
    if not now then return end
    local new = {}
    for id in pairs(now) do
      if not before[id] and not turned[id] and not (a.doneQuests and a.doneQuests[id]) then new[#new + 1] = id end
    end
    -- a handful at most; many means unrelated quests happened in between
    if #new == 0 or #new > 8 then return end
    DB.eventFlags = DB.eventFlags or {}
    DB.eventFlags[a.key] = DB.eventFlags[a.key] or {}
    for _, id in ipairs(new) do DB.eventFlags[a.key][id] = DB.eventFlags[a.key][id] or time() end
    ns.SnapshotQuests()
  end)
end

-- First login after a weekly reset: a candidate that's still completed
-- doesn't reset weekly, so it can't tell whether this week is done.
function ns.CheckFlagRollover(c)
  if c.flagWeek and c.flagWeek ~= c.weekReset and DB.eventFlags then
    for _, flags in pairs(DB.eventFlags) do
      for id in pairs(flags) do
        if C_QuestLog.IsQuestFlaggedCompleted(id) then flags[id] = nil; DB.eventFlagsDropped[id] = true end
      end
    end
  end
  c.flagWeek = c.weekReset
end

------------------------------------------------------------------------
-- Event reminders (Aqir): a raid-warning style message N minutes before
-- the next start, if it isn't done this week on this character.
-- (The reminders in the map's Events tab can only be set by the game's
-- own UI, so the addon keeps its own.)
------------------------------------------------------------------------
local reminded = {}
function ns.CheckReminders()
  local c = ns.GetChar()
  for _, a in ipairs(ns.ACTIVITIES) do
    local s = ns.ActSet(a)
    if a.schedule and (s.remind or 0) > 0 and ns.Applies(c, a) then
      local d, count = ns.ActStatus(c, a)
      local active, nextIn = ns.ScheduleInfo(a, c, true)
      if d < count and not active and nextIn and nextIn > 0 and nextIn <= s.remind * 60 then
        local startAt = math.floor(((GetServerTime and GetServerTime() or time()) + nextIn) / 60)
        if reminded[a.key] ~= startAt then
          reminded[a.key] = startAt
          local msg = string.format("%s starts in %s", a.name, ns.Duration(nextIn))
          if RaidNotice_AddMessage and RaidWarningFrame then
            RaidNotice_AddMessage(RaidWarningFrame, msg, (ChatTypeInfo and ChatTypeInfo.RAID_WARNING) or { r = 1, g = 0.82, b = 0 })
          end
          if DB.settings.remindSound and PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
          ns.Print(msg .. ". |cff888888(reminder: Setup tab, or right-click it in the route)|r")
        end
      end
    end
  end
end

-- Manually set how many completions are done (route / tracker / alt grid).
function ns.SetDone(key, a, n)
  local c = ns.GetChar(key)
  local w = ns.Weekly(c, a.key)
  w.done, w.manual = math.max(0, n), true
  if n > 0 then w.at = time(); ns.NoteDone(c, a.key) end
  if a.kind == "crafting" then c.crafting.count = (n > 0) and math.max(1, c.crafting.count or 0) or 0 end
  ns.Refresh()
end

function handlers.PLAYER_ENTERING_WORLD()
  QueueScan()
end

function handlers.PLAYER_MONEY() OnMoney() end

function handlers.ACCOUNT_MONEY()
  if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType then
    local ok, m = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    if ok and m then DB.warband = m end
  end
  ns.PushContext("Transfer", "Warband bank", nil, 2, true)
  ns.Refresh()
end

function handlers.QUEST_ACCEPTED(a1, a2)
  local qid = a2 or a1 -- older clients passed (logIndex, questID)
  if type(qid) == "number" then
    local title = TitleFor(qid)
    local a = ns.ActivityForQuest(qid, title)
    if a then
      if not IsDailyInLog(qid) then ns.Learn(a, qid, title) end
      local c = ns.GetChar()
      c.inLog[a.key] = true
      c.inLogQid = c.inLogQid or {}
      c.inLogQid[a.key] = qid
      if ns.Pickups then ns.Pickups.LearnAt(a); ns.Pickups.OnAccepted(a) end
      ns.Refresh()
    end
  end
end

local function RememberTitle()
  local qid = GetQuestID and GetQuestID()
  if qid and qid > 0 then titles[qid] = GetTitleText and GetTitleText() end
end
function handlers.QUEST_DETAIL()
  RememberTitle()
  if ns.Pickups then ns.Pickups.OnNPC() end
end
handlers.QUEST_COMPLETE = RememberTitle
handlers.QUEST_PROGRESS = RememberTitle
-- an NPC's window: the weeklies it offers are picked up there
function handlers.GOSSIP_SHOW() if ns.Pickups then ns.Pickups.OnNPC() end end
function handlers.QUEST_GREETING() if ns.Pickups then ns.Pickups.OnNPC() end end

-- Marks a map event done this week on the current character.
function ns.MarkEventDone(a, why)
  local c = ns.GetChar()
  local w = ns.Weekly(c, a.key)
  if w.done < 1 then
    w.done, w.at = 1, time()
    ns.NoteDone(c, a.key)
    if DB.settings.announce then ns.Print(string.format("%s done this week on %s (%s).", a.name, ns.ColorName(ns.charKey, c), why)) end
    ns.Refresh()
  end
end

-- Special Assignment names without the "Special Assignment:" prefix, so
-- the unlock step ("Shade and Claw") and the assignment match.
function ns.SAKey(title)
  return (tostring(title or ""):gsub("^[^:]*[Ss]pecial [Aa]ssignment:%s*", ""):lower())
end

function ns.NoteSAUnlocked(c, title)
  if not title then return end
  c.saUnlocked = c.saUnlocked or {}
  c.saUnlocked[ns.SAKey(title)] = c.weekReset
  ns.Refresh()
end

-- The unlock step got counted as a finished assignment before 1.0: rebuild
-- this week's count once from what really shows completion - assignment
-- world quests turned in, and Fabled Veteran's Caches opened.
function ns.FixSACount(c, key)
  if c.saFixed == c.weekReset then return end
  c.saFixed = c.weekReset
  local w = c.weekly and c.weekly.special
  if not w or w.manual then return end
  local weekStart = (c.weekReset or ns.NextReset()) - WEEK
  local a = ns.ACT_BY_KEY.special
  local quests, caches = 0, 0
  local list = DB.recentTurnins or {}
  for i, r in ipairs(list) do
    if r.char == key and r.t >= weekStart and ns.MatchTitle(r.title) == a then
      local isWQ = r.wq
      if isWQ == nil then isWQ = (C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(r.qid)) and true or false; r.wq = isWQ end
      -- paired with another turn-in in the same moment = the unlock step
      local paired = false
      for j = math.max(1, i - 2), math.min(#list, i + 2) do
        local o = list[j]
        if j ~= i and o.char == key and math.abs(o.t - r.t) <= 2 and ns.MatchTitle(o.title) ~= a then paired = true end
      end
      if isWQ and not paired then quests = quests + 1; r.saDone = true else r.saDone = nil; ns.NoteSAUnlocked(c, r.title) end
    end
  end
  for _, e in ipairs(DB.ledger or {}) do
    if e.c == key and e.t >= weekStart and e.k == "special" and (e.s == "Special Assignment" or e.s == "Weekly Cache") then caches = caches + 1 end
  end
  w.done = math.min(ns.ActCap(a), math.max(quests, caches))
end

-- Event reward quests turned in earlier this week on this character
-- (from the recent turn-ins kept for /gc events).
function ns.CheckEventTurnins()
  local c = ns.GetChar()
  local weekStart = (c.weekReset or ns.NextReset()) - WEEK
  for _, r in ipairs(DB.recentTurnins or {}) do
    if r.char == ns.charKey and r.t >= weekStart then
      for _, ev in ipairs(ns.ACTIVITIES) do
        if ev.doneQuests and ev.doneQuests[r.qid] then
          ns.MarkEventDone(ev, "reward quest turned in " .. date("%a %H:%M", r.t))
        end
      end
    end
  end
end

-- Last time each event was seen live (you were in it / it was on the map).
ns.eventSeenAt = {}

function handlers.QUEST_TURNED_IN(qid, xp, money)
  local title = TitleFor(qid) or (DB.wq[qid] and DB.wq[qid].title)
  -- keep the last few turn-ins for /gc events
  DB.recentTurnins = DB.recentTurnins or {}
  local turnedInWQ = (C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(qid)) and true or false
  table.insert(DB.recentTurnins, 1, { qid = qid, title = title, t = time(), char = ns.charKey, wq = turnedInWQ })
  while #DB.recentTurnins > 40 do table.remove(DB.recentTurnins) end
  ns.NoteTurnedIn(qid)
  -- anything completed during (or just after) a live event belongs to it
  -- an event's hidden reward quest (Aqir: "Reward Quest (DNT)"): you
  -- finished a run. Only while its slot is running or just ended, in case
  -- another event shares the quest.
  for _, ev in ipairs(ns.ACTIVITIES) do
    if ev.doneQuests and ev.doneQuests[qid] then
      local sc = ns.WQ and ns.WQ.SchedFor(ev)
      if not sc or sc.window or (sc.lastEnd and time() - sc.lastEnd < 30 * 60) then
        ns.MarkEventDone(ev, "event reward quest")
      end
    end
  end
  local doneEvents = {}
  for _, ev in ipairs(ns.ACTIVITIES) do
    local cw = ns.GetChar().weekly[ev.key]
    if ev.mapEvent and cw and (cw.done or 0) >= 1 then
      -- already done this week: a repeat run must not learn bonus/hidden quests
      -- (e.g. "Reward Quest (DNT)") or announce it again
      doneEvents[ev.key] = true
    elseif ev.mapEvent and ns.ActSet(ev).enabled and not (ns.IsCampaign and ns.IsCampaign(qid))
       and not (title and title:find("DNT", 1, true)) then
      local live = ns.WQ and ns.WQ.EventLive(ev, true)
      local recently = ns.eventSeenAt[ev.key] and GetTime() - ns.eventSeenAt[ev.key] < 120
      local named = ns.MatchTitle(title) == ev -- "Aqir Invasion" / "Aqir Assault", never "The Aqir Swarm"
      if (live == "scenario" or live == "objective" or recently or named) and not DB.blocked[qid] then
        ns.Learn(ev, qid, title or (ev.name .. " event"))
        ns.MarkEventDone(ev, "event quest completed")
      end
    end
  end
  local a = ns.ActivityForQuest(qid, title)
  local c = ns.GetChar()
  ns.CheckReset(c, ns.charKey)
  if a and doneEvents[a.key] then a = nil end
  -- Special Assignments: the unlock step is a quest in your log that
  -- completes in the same second as the 3rd world quest (sometimes also
  -- titled "Special Assignment: ..."). Only the assignment itself - a world
  -- quest turned in on its own - is done.
  local prev = DB.recentTurnins[2]
  local paired = prev and prev.char == ns.charKey and math.abs(time() - prev.t) <= 2 or false
  local special = ns.ACT_BY_KEY.special
  if a and a.key == "special" and (not turnedInWQ or (paired and ns.MatchTitle(prev.title) ~= special)) then
    ns.NoteSAUnlocked(c, title)
    a = nil
  elseif paired and prev.saDone and ns.MatchTitle(title) ~= special then
    -- the "assignment" just before was the unlock after all: take it back
    local w = ns.Weekly(c, "special")
    w.done = math.max(0, w.done - 1)
    prev.saDone = nil
    ns.NoteSAUnlocked(c, prev.title)
  end
  if a and a.key == "special" then DB.recentTurnins[1].saDone = true end
  if a and a.kind ~= "crafting" then
    ns.Learn(a, qid, title)
    local zone = GetZoneText and GetZoneText()
    if zone and zone ~= "" then DB.zones[a.key] = zone end
    local s = ns.ActSet(a)
    local w = ns.Weekly(c, a.key)
    w.done = math.min(w.done + 1, ns.ActCap(a))
    w.at = time()
    ns.NoteDone(c, a.key)
    c.inLog[a.key] = nil
    if c.inLogN and c.inLogN[a.key] then c.inLogN[a.key] = math.max(0, c.inLogN[a.key] - 1) end
    if s.enabled and DB.settings.announce then
      local count = ns.ActCount(c, a)
      ns.Print(string.format("%s complete on %s%s", a.name, ns.ColorName(ns.charKey, c),
        count > 1 and string.format(" (%d/%d)", w.done, count) or ""))
    end
  end
  local isWQ = ns.WQ and ns.WQ.IsWorldQuest(qid)
  if isWQ then ns.WQ.OnTurnedIn(qid) end
  if money and money > 0 then
    local src = isWQ and "World Quest" or "Quest"
    local e = ns.lastEntry
    if e and e.s ~= src and e.a > 0 and QuestMoneyMatches(money, e.a) and ns.lastEntryTime and GetTime() - ns.lastEntryTime < 3 then
      ns.Reclassify(e, src, title, a and a.key)
    else
      pendingQuest = { amount = money, detail = title, key = a and a.key, t = GetTime(), src = src }
    end
  end
  QueueScan()
  ns.Refresh()
end

function handlers.QUEST_DATA_LOAD_RESULT(qid, ok)
  if ok and ns.WQ then ns.WQ.OnDataLoaded(qid) end
end
function handlers.UNIT_SPELLCAST_SUCCEEDED(...) if ns.Travel then ns.Travel.OnSpellCast(...) end end
function handlers.UNIT_SPELLCAST_START(...) if ns.Travel then ns.Travel.OnCastStart(...) end end
function handlers.UNIT_SPELLCAST_CHANNEL_START(...) if ns.Travel then ns.Travel.OnChannelStart(...) end end
function handlers.UNIT_SPELLCAST_CHANNEL_STOP(...) if ns.Travel then ns.Travel.OnChannelStop(...) end end
function handlers.LOADING_SCREEN_ENABLED() if ns.Travel then ns.Travel.OnLoadingStart() end end
function handlers.LOADING_SCREEN_DISABLED() if ns.Travel then ns.Travel.OnLoadingEnd() end end
function handlers.HEARTHSTONE_BOUND() if ns.Travel then ns.Travel.OnBindChanged() end end
function handlers.PLAYER_REGEN_DISABLED() if ns.WQWindow then ns.WQWindow:OnCombat(true) end end
function handlers.PLAYER_REGEN_ENABLED() if ns.WQWindow then ns.WQWindow:OnCombat(false) end end

function handlers.PLAYER_FLAGS_CHANGED(unit)
  if (unit == nil or unit == "player") and ns.WQ then ns.WQ.UpdateWarMode() end
end
function handlers.WAR_MODE_STATUS_UPDATE() if ns.WQ then ns.WQ.UpdateWarMode() end end

function handlers.QUEST_WATCH_LIST_CHANGED() ns.Refresh() end
function handlers.SCENARIO_UPDATE() ns.Refresh() end
function handlers.SCENARIO_COMPLETED() ns.Refresh() end
-- Both fire often in cities, and a marker scan reads every Midnight map:
-- at most one marker scan per 30 seconds, Events tab reads bunched up.
local poiQueued, poiLast = false, 0
function handlers.AREA_POIS_UPDATED()
  if not ns.WQ or poiQueued then return end
  poiQueued = true
  C_Timer.After(math.max(2, 30 - (GetTime() - poiLast)), function()
    poiQueued, poiLast = false, GetTime()
    pcall(ns.WQ.ScanEventPOIs)
    ns.Refresh()
  end)
end
local schedQueued = false
function handlers.EVENT_SCHEDULER_UPDATE()
  if not ns.WQ or schedQueued then return end
  schedQueued = true
  C_Timer.After(2, function()
    schedQueued = false
    pcall(ns.WQ.ScanScheduler)
    ns.Refresh()
  end)
end
function handlers.SUPER_TRACKING_CHANGED()
  if ns.WQ then pcall(ns.WQ.OnSuperTrack) end
  ns.Refresh()
end

function handlers.ZONE_CHANGED_NEW_AREA()
  if ns.WQ then ns.WQ.QueueScan(3) end
end

function handlers.CHAT_MSG_LOOT(msg, looter, _, _, looter2)
  if not msg or not ns.charKey then return end
  local who = (looter2 and looter2 ~= "" and looter2) or looter or ""
  local me = UnitName("player") or ""
  if who ~= "" and who ~= me and not who:find("^" .. me .. "%-") then return end -- someone else's loot
  local id = tonumber(msg:match("item:(%d+)"))
  local name = msg:match("%[(.-)%]")
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.mapEvent then
      -- the weekly reward, e.g. [Aqir Research Satchel]
      local byName = name and ns.ActivityForCache(name) == a
      local bags = DB.eventBags and DB.eventBags[a.key]
      if byName or (id and bags and bags[id]) then
        if byName and id then
          DB.eventBags = DB.eventBags or {}
          DB.eventBags[a.key] = DB.eventBags[a.key] or {}
          DB.eventBags[a.key][id] = true
        end
        ns.MarkEventDone(a, (name or "reward") .. " looted")
        ns.LearnEventFlags(a)
      end
    elseif a.cacheDone then
      -- a reward you only get by completing it (Stormarion Assault's cache)
      if (id and a.cacheIDs and a.cacheIDs[id]) or (name and ns.ActivityForCache(name) == a) then
        ns.MarkEventDone(a, (name or "reward") .. " received")
      end
    end
  end
end

function handlers.QUEST_LOG_UPDATE() QueueScan() end
function handlers.QUEST_REMOVED() QueueScan() end

function handlers.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(t)
  local src = InteractionSource(t)
  if src then SetWindow(src, true) end
end
function handlers.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(t)
  local src = InteractionSource(t)
  if src then SetWindow(src, false) end
end

function handlers.LOOT_OPENED() SetWindow("Loot", true) end
function handlers.LOOT_CLOSED() C_Timer.After(0.5, function() SetWindow("Loot", false) end) end
function handlers.TRADE_SHOW() SetWindow("Trade", true) end
function handlers.TRADE_CLOSED() C_Timer.After(1, function() SetWindow("Trade", false) end) end

-- The profession window (where crafter orders live at the work table)
function handlers.TRADE_SKILL_SHOW() if ns.Orders then ns.Orders.OnOpen() end end
function handlers.TRADE_SKILL_CLOSE() if ns.Orders then ns.Orders.OnClose() end end

function handlers.CRAFTINGORDERS_SHOW_CRAFTER()
  SetWindow("Crafting Order", true)
  if ns.Orders then ns.Orders.OnOpen() end
end
function handlers.CRAFTINGORDERS_HIDE_CRAFTER()
  SetWindow("Crafting Order", false)
  if ns.Orders then ns.Orders.OnClose() end
end
function handlers.CRAFTINGORDERS_SHOW_CUSTOMER() SetWindow("Crafting Order", true) end
function handlers.CRAFTINGORDERS_HIDE_CUSTOMER() SetWindow("Crafting Order", false) end

function handlers.CRAFTINGORDERS_FULFILL_ORDER_RESPONSE(result, orderID)
  local ok = (result == 0) or (Enum and Enum.CraftingOrderResult and result == Enum.CraftingOrderResult.Ok)
  if not ok then return end
  local c = ns.GetChar()
  ns.CheckReset(c, ns.charKey)
  c.crafting.count = (c.crafting.count or 0) + 1
  -- per profession: Tailoring done doesn't make Enchanting done (ns.CraftStatus)
  c.crafting.profs = c.crafting.profs or {}
  if ns.Orders then c.crafting.profs[ns.Orders.CurrentProfession()] = true end
  ns.Weekly(c, "crafting").done = 1
  ns.PushContext("Crafting Order", "Order #" .. tostring(orderID or "?"), "crafting", 10, true)
  if ns.Orders and orderID then ns.Orders.OnFulfilled(orderID) end
  ns.Refresh()
end

-- Reaching 90 offers a level-90 version of some weeklies (Runestones,
-- Harandar, Abundance) even if the 80-89 one was done this week: those are
-- reset, and the quests done before 90 stop counting until the weekly reset.
function ns.OnReached90(c)
  local ignore = { week = c.weekReset, ids = {} }
  local reset = {}
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.again90 then
      for qid in pairs(DB.questIDs[a.key] or {}) do
        if C_QuestLog.IsQuestFlaggedCompleted(qid) then ignore.ids[qid] = true end
      end
      local w = c.weekly[a.key]
      if w and w.done > 0 then
        w.done, w.manual, w.at = 0, nil, nil
        reset[#reset + 1] = a.name
      end
    end
  end
  c.pre90 = ignore
  if #reset > 0 then
    ns.Print(string.format("Level 90: %s can be done again at 90 this week.", table.concat(reset, ", ")))
  end
  ns.Refresh()
end

function ns.IgnoredPre90(c, qid)
  local p = c.pre90
  return p and p.week == c.weekReset and p.ids[qid] or false
end

function handlers.PLAYER_LEVEL_UP(level)
  local c = ns.GetChar()
  local before = c.level or 0
  c.level = level
  if before < 90 and (level or 0) >= 90 then ns.OnReached90(c) end
  ns.Refresh()
end

function handlers.SKILL_LINES_CHANGED()
  ns.UpdateProfessions()
  ns.Refresh()
end

function handlers.PLAYER_LOGOUT()
  if ns.charKey and DB then ns.SnapshotChar(true) end
end

-- Events that may run before the character is known.
local PRE_LOGIN = { ADDON_LOADED = true, PLAYER_LOGIN = true }
local eventCount = {} -- [event] = times handled this session (/gc mem)

ev:SetScript("OnEvent", function(_, event, ...)
  local h = handlers[event]
  if not h then return end
  -- Many events (SKILL_LINES_CHANGED, QUEST_LOG_UPDATE, PLAYER_MONEY...) fire
  -- during loading before PLAYER_LOGIN; ignore them until we know who we are.
  if not ns.ready and not PRE_LOGIN[event] then return end
  -- Since 12.0 some event data is "secret" (e.g. chat in dungeons, raids,
  -- Mythic+ and PvP; casts in encounters): looking inside it is a Lua
  -- error, so such events are skipped.
  if hasanysecretvalues and hasanysecretvalues(...) then return end
  eventCount[event] = (eventCount[event] or 0) + 1
  h(...)
end)
for event in pairs(handlers) do
  pcall(ev.RegisterEvent, ev, event) -- some events may not exist on every build
end

-- /gc mem: what each repeating job allocates per run, and how often the
-- busiest events fire. Memory that comes back after a garbage collection is
-- short-lived tables; these show where they come from.
function ns.MemReport()
  UpdateAddOnMemoryUsage()
  ns.Print(string.format("memory %d KB (falls back when the game collects garbage).", GetAddOnMemoryUsage(ADDON)))
  local function Cost(label, fn)
    local runs, kb = 5, 0
    for _ = 1, runs do
      local before = collectgarbage("count")
      pcall(fn)
      kb = kb + math.max(0, collectgarbage("count") - before)
    end
    print(string.format("  %s: ~%.0f KB per run", label, kb / runs))
  end
  print("  Per run (approximate):")
  Cost("Dashboard + tracker refresh", function() ns.UI:Update() end)
  if ns.WQWindow.frame and ns.WQWindow.frame:IsShown() then
    Cost("World Quest Tracker refresh", function() ns.WQWindow:Update() end)
  end
  Cost("Directions (route planner)", function() ns.Travel.Plan(ns.Travel.Goal(), ns.Travel.Sample()) end)
  Cost("Position check (every 1s)", ns.Travel.Tick)
  Cost("Quest log scan", function() ns.ScanQuestLog(); ns.SnapshotCompletion() end)
  Cost("Map event markers (max every 30s)", ns.WQ.ScanEventPOIs)
  Cost("Events tab (every 15s)", ns.WQ.ScanScheduler)
  Cost("Zone scan (every 5 min)", ns.WQ.Scan)
  local mins = math.max(1, (time() - ns.session.start) / 60)
  local list = {}
  for e, n in pairs(eventCount) do list[#list + 1] = { e = e, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  print(string.format("  Busiest events (%.0f min this session):", mins))
  for i = 1, math.min(8, #list) do
    print(string.format("    %s: %d (%.1f per minute)", list[i].e, list[i].n, list[i].n / mins))
  end
end

------------------------------------------------------------------------
-- Refresh (throttled)
------------------------------------------------------------------------
local refreshQueued = false
function ns.Refresh()
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0.25, function()
    refreshQueued = false
    if ns.UI and ns.UI.Update then ns.UI:Update() end
  end)
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local function FindAct(key)
  if not key then return end
  key = lower(key)
  if ns.ACT_BY_KEY[key] then return ns.ACT_BY_KEY[key] end
  for _, a in ipairs(ns.ACTIVITIES) do
    if lower(a.name):find(key, 1, true) or lower(a.short) == key then return a end
  end
end

local HELP = {
  "/gc — toggle the dashboard",
  "/gc mini — toggle the compact tracker",
  "/gc route — print this character's route to chat",
  "/gc done <activity> | undo <activity> — manually mark on this character (or right-click it)",
  "/gc unskip — bring back every world quest you skipped",
  "/gc learn <activity> <questID> — assign a quest ID manually",
  "/gc forget <activity> — clear learned quest IDs (and block them)",
  "/gc ids — list learned quest IDs",
  "/gc delchar <Name-Realm> — remove a character",
  "/gc wqwin — toggle the world quest tracker window",
  "/gc orders — crafting order diagnostics (what the addon can see)",
  "/gc tsmprice <source> — TSM price used for crafting reagents (default first(DBMinBuyout, DBMarket))",
  "/gc travel — list learned hearthstone/teleports/portals (del <n>: remove one, forget: clear all)",
  "/gc wq — list gold world quests open on this character",
  "/gc wqscan — rescan zones for world quests",
  "/gc events [activity] — event diagnostics: the map's Events tab, markers, quests (default Aqir; e.g. /gc events abundance)",
  "/gc sa — Special Assignment diagnostics (rescans first)",
  "/gc pin [activity] — show the marker/pin you clicked on the map; with an activity, save it as its spot (event spot or pickup)",
  "/gc wqhere — add the zone you're standing in to the world quest scan",
  "/gc minimap — toggle the minimap button",
  "/gc mem — memory diagnostics (what each repeating job allocates)",
  "Activities: apex venom harandar runestones abundance special aqir crafting stormarion",
}

SLASH_GOLDCIRCUIT1 = "/gc"
SLASH_GOLDCIRCUIT2 = "/goldcircuit"
local function Command(msg)
  local cmd, a1, a2 = strsplit(" ", strtrim(msg or ""), 3)
  cmd = lower(cmd)
  if cmd == "" then
    ns.UI:Toggle()
  elseif cmd == "mini" then
    ns.UI:ToggleMini()
  elseif cmd == "route" then
    local r = ns.BuildRoute(ns.charKey)
    if #r.steps == 0 then ns.Print("Nothing left this week on this character.") return end
    ns.Print(string.format("Route (%s, ~%d min):", ns.Money(r.gold), r.mins))
    for i, s in ipairs(r.steps) do
      print(string.format("  %d. [%s] %s — %s", i, s.zone, s.name, ns.Money(s.gold)))
    end
  elseif cmd == "done" or cmd == "undo" then
    local a = FindAct(a1)
    if not a then ns.Print("Unknown activity: " .. tostring(a1)) return end
    ns.SetDone(ns.charKey, a, (cmd == "done") and select(2, ns.ActStatus(ns.GetChar(), a)) or 0)
    ns.Print(a.name .. ((cmd == "done") and " marked done." or " reset."))
  elseif cmd == "unskip" then
    ns.WQ.ClearSkips()
  elseif cmd == "learn" then
    local a, qid = FindAct(a1), tonumber(a2)
    if not a or not qid then ns.Print("Usage: /gc learn <activity> <questID>") return end
    DB.blocked[qid] = nil
    ns.Learn(a, qid, TitleFor(qid))
    ns.SnapshotCompletion(); ns.Refresh()
  elseif cmd == "forget" then
    local a = FindAct(a1)
    if not a then ns.Print("Unknown activity: " .. tostring(a1)) return end
    for qid in pairs(DB.questIDs[a.key] or {}) do DB.blocked[qid] = true end
    DB.questIDs[a.key] = nil
    ns.Print("Cleared learned quest IDs for " .. a.name .. ". Use /gc learn to set one manually.")
    ns.Refresh()
  elseif cmd == "ids" then
    for _, a in ipairs(ns.ACTIVITIES) do
      local parts = {}
      for qid, t in pairs(DB.questIDs[a.key] or {}) do parts[#parts + 1] = qid .. " (" .. tostring(t) .. ")" end
      local none = a.kind == "crafting" and "|cff888888event-based (no quest)|r" or "|cff888888not learned yet|r"
      print(string.format("  %s: %s", a.name, #parts > 0 and table.concat(parts, ", ") or none))
    end
  elseif cmd == "delchar" then
    if a1 and DB.chars[a1] then
      DB.chars[a1] = nil
      ns.Print("Removed " .. a1)
      ns.Refresh()
    else
      ns.Print("Character not found. Use the exact Name-Realm shown in the Alts tab tooltip.")
    end
  elseif cmd == "wq" then
    local list, total = ns.WQ.Remaining(ns.GetChar())
    ns.Print(string.format("%d gold world quests open on this character (%s):", #list, ns.Money(total)))
    for i, q in ipairs(list) do
      print(string.format("  %d. [%s] %s — %s%s", i, q.zone or "?", q.title or q.qid, ns.Money(q.gold),
        q.expires and ("  (" .. ns.Duration(q.expires - time()) .. " left)") or ""))
    end
  elseif cmd == "travel" then
    if lower(a1) == "forget" then ns.Travel.Forget() return end
    if lower(a1) == "del" then ns.Travel.DeletePortal(tonumber(a2)) return end
    local c = ns.GetChar()
    ns.Print("Learned travel:")
    print("  Hearthstone: " .. (c.hearth and (c.hearth.zone or "?") or "|cff888888not learned — use it once|r"))
    for _, t in ipairs(ns.Travel.Teleports()) do
      if t.key ~= "hearth" then print("  " .. t.label .. (t.note and ("  |cff888888" .. t.note .. "|r") or "")) end
    end
    for i, p in ipairs(DB.travel.portals) do
      print(string.format("  %d. Portal: %s (%.0f, %.0f) » %s  |cff888888used %dx|r", i, p.from.zone or "?",
        (p.from.mx or 0) * 100, (p.from.my or 0) * 100, p.to.zone or "?", p.uses or 1))
    end
    print("  |cff888888/gc travel del <number> removes one portal link; /gc travel forget clears everything.|r")
  elseif cmd == "orders" then
    ns.Orders.Report()
  elseif cmd == "tsmprice" then
    local src = strtrim((msg or ""):sub(#"tsmprice" + 1))
    if src == "" then
      ns.Print("TSM price source: " .. DB.settings.orders.tsmPrice .. "  (e.g. /gc tsmprice DBMarket)")
    else
      DB.settings.orders.tsmPrice = src
      ns.Print("TSM price source set to: " .. src)
      ns.Refresh()
    end
  elseif cmd == "wqwin" then
    ns.WQWindow:Toggle()
  elseif cmd == "events" or cmd == "aqir" then
    -- /gc aqir: the old name, still works
    local a = cmd == "aqir" and ns.ACT_BY_KEY.aqir or (a1 and a1 ~= "" and FindAct(a1)) or ns.ACT_BY_KEY.aqir
    if not a then ns.Print("Unknown activity: " .. tostring(a1)) return end
    ns.WQ.ReportEvent(a)
  elseif cmd == "sa" then
    ns.WQ.FindMaps(true)
    ns.WQ.Scan()
    ns.WQ.ReportSA()
  elseif cmd == "pin" then
    local a = a1 and a1 ~= "" and FindAct(a1)
    if a1 and a1 ~= "" and not a then ns.Print("Unknown activity: " .. a1) return end
    ns.WQ.PinReport(a)
  elseif cmd == "wqhere" then
    ns.WQ.AddCurrentZone()
  elseif cmd == "wqscan" then
    ns.WQ.FindMaps(true)
    ns.WQ.Scan()
    local n, g = ns.WQ.Count()
    local maps = 0
    for _ in pairs(ns.DB.wqMaps or {}) do maps = maps + 1 end
    ns.Print(string.format("Scanned %d zones: %d gold world quests worth %s.", maps, n, ns.Money(g)))
  elseif cmd == "mem" then
    ns.MemReport()
  elseif cmd == "minimap" then
    DB.settings.minimap.hide = not DB.settings.minimap.hide
    ns.UI:UpdateMinimap()
  else
    for _, l in ipairs(HELP) do print("  " .. l) end
  end
end

-- Replies to a command you typed show even with chat messages off.
SlashCmdList.GOLDCIRCUIT = function(msg)
  ns.inCommand = true
  local ok, err = pcall(Command, msg)
  ns.inCommand = false
  if not ok then geterrorhandler()(err) end
end

-- Addon compartment (the puzzle-piece menu by the minimap)
function GoldCircuit_OnAddonCompartmentClick(_, button)
  if IsShiftKeyDown() then ns.WQWindow:Toggle()
  elseif button == "RightButton" then ns.UI:ToggleMini()
  else ns.UI:Toggle() end
end
function GoldCircuit_OnAddonCompartmentEnter(_, frame)
  if ns.UI and ns.UI.ShowSummaryTooltip then ns.UI:ShowSummaryTooltip(frame) end
end
function GoldCircuit_OnAddonCompartmentLeave()
  GameTooltip:Hide()
end
