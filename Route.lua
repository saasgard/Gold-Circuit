local ADDON, ns = ...

-- Estimated gold (copper) for one completion of an activity.
-- Uses the real average you've earned once there is data, unless you
-- typed your own value in Setup (override).
function ns.EstGold(a)
  local s = ns.ActSet(a)
  if not s.override then
    local L = ns.DB.learned[a.key]
    if L and (L.cN or 0) > 0 then
      local q = (L.qN or 0) > 0 and (L.qS / L.qN) or 0
      return math.floor(L.cS / L.cN + q), true
    elseif a.kind == "crafting" then
      -- average weekly crafting-order income across all characters with data
      local sum, n = 0, 0
      for _, c in pairs(ns.DB.chars) do
        if c.crafting and (c.crafting.gold or 0) > 0 then sum = sum + c.crafting.gold; n = n + 1 end
      end
      if n > 0 then return math.floor(sum / n), true end
    end
  end
  return (s.gold or 0) * 10000, false
end

function ns.ZoneFor(a)
  return ns.DB.zones[a.key] or a.zone or "Zone not learned yet"
end

-- Returns the status of one activity on one character.
-- Returns done, available this week, picked up (and for Special
-- Assignments the list of them).
function ns.ActStatus(c, a)
  local w = c.weekly and c.weekly[a.key]
  local done = w and w.done or 0
  local inLog = (c.inLog and c.inLog[a.key]) and true or false
  if a.key == "special" and ns.WQ then
    -- how many are up comes from the map: done ones + open ones
    local list = ns.WQ.SpecialAssignments(c)
    local doneN, open = 0, 0
    for _, sa in ipairs(list) do
      if sa.done then doneN = doneN + 1 else open = open + 1 end
    end
    done = math.max(done, doneN)
    if w and w.manual then done = w.done end
    -- turn-ins that are still on the map are already in doneN; never more
    -- than 3 in all
    local count = math.min(ns.ActCap(a), math.max(done, done + open))
    return math.min(done, count), count, inLog, list
  end
  if a.families then
    -- one completion per kind of quest (Apex: "Midnight:" and Trailing Xal'atath)
    local fams = ns.Families(a)
    if not (w and w.manual) then
      if c.famDone and c.famDone[a.key] then
        done = 0
        for _, fam in ipairs(fams) do if ns.FamilyDone(c, a, fam) then done = done + 1 end end
      end -- (an alt not logged in since: what was counted this week)
    end
    return math.min(done, #fams), #fams, inLog
  end
  if a.kind == "crafting" then
    -- one completion per crafting profession
    local profs = ns.CraftStatus(c)
    if not (w and w.manual) then
      done = 0
      for _, p in ipairs(profs) do if p.done then done = done + 1 end end
    end
    return math.min(done, #profs), #profs, inLog
  end
  local count = ns.ActCount(c, a)
  return math.min(done, count), count, inLog
end

-- Crafting orders, per crafting profession (a character can have two, each
-- with its own orders): { name, done, scanned, n, profit } each. One scanned
-- at its table in the last 36h is done when nothing profitable is left
-- there; otherwise once you've fulfilled an order with it this week.
function ns.CraftStatus(c)
  local out, now = {}, time()
  local names = c.craftProfs
  if not names or #names == 0 then
    names = {}
    for prof in pairs(c.craftOrders or {}) do names[#names + 1] = prof end
    table.sort(names)
    if #names == 0 then names[1] = "Crafting" end
  end
  local cr = c.crafting or {}
  local filled = cr.profs or {}
  -- an order fulfilled before orders were counted per profession: only
  -- certain to be this profession's if it's the only one
  local legacy = (cr.count or 0) > 0 and not cr.profs and #names == 1
  for _, prof in ipairs(names) do
    local s = { name = prof }
    local entry = c.craftOrders and c.craftOrders[prof]
    if ns.Orders and entry and entry.scanned and now - entry.scanned < 36 * 3600 then
      s.scanned = true
      s.n, s.profit = ns.Orders.Summary(c, prof)
      s.done = s.n == 0
    else
      s.done = (filled[prof] or legacy or (prof == "Crafting" and (cr.count or 0) > 0)) and true or false
    end
    out[#out + 1] = s
  end
  return out
end

-- Recurring events (Aqir): is it running now, and seconds until the next start.
-- The map's Events tab is used when it lists the event; otherwise the
-- addon's own checks.
function ns.ScheduleInfo(a, c, isCurrent)
  local sc = a.schedule
  if not sc then return end
  local now = (GetServerTime and GetServerTime()) or time()
  local into = (now - (sc.offset or 0)) % sc.every
  local fallbackNext = sc.every - into
  local es = ns.WQ and ns.WQ.SchedFor and ns.WQ.SchedFor(a)
  if es then
    local live = ns.WQ.EventLive(a, isCurrent) -- you're in it, or the Events tab says running
    local t = time() -- the Events tab's clock
    local nextIn = (es.nextStart and es.nextStart > t) and (es.nextStart - t) or fallbackNext
    return live and true or false, nextIn, es
  end
  -- Fallback when the Events tab doesn't list it. (A quest from the event
  -- staying in your log isn't used: it lingers after the event is over.)
  local active = false
  if C_TaskQuest and C_TaskQuest.IsActive and (sc.questID or 0) > 0 then
    local ok, v = pcall(C_TaskQuest.IsActive, sc.questID)
    active = ok and v and true or false
  end
  -- scenario / bonus objective you're in, or an event marker on the map
  if not active and ns.WQ and ns.WQ.EventLive then
    active = ns.WQ.EventLive(a, isCurrent) and true or false
  end
  return active, fallbackNext
end

function ns.Applies(c, a)
  local s = ns.ActSet(a)
  if not s.enabled then return false end
  -- Midnight content starts at 80; some weeklies need 90
  if (c.level or 0) < (a.minLevel or ns.MIN_LEVEL) then return false end
  -- crafting orders only for characters with a crafting profession
  -- (alts not logged in since this check existed fall back to "any profession";
  -- scanned crafting orders prove a profession even if a logout wiped it)
  if a.kind == "crafting" then
    local hasOrders = c.craftOrders and next(c.craftOrders) ~= nil
    if c.hasCraftProf == false and not hasOrders then return false end
    if c.hasCraftProf == nil and c.hasProf == false and not hasOrders then return false end
  end
  return true
end

--[[
  Route optimisation for one character:
  1. Collect every enabled activity with completions left.
  2. Group by zone (fewer flights / portals).
  3. Order zones by total gold per minute; within a zone, quests already
     in your log come first, then by gold per minute.
--]]
local function BuildRoute(key)
  local c = ns.GetChar(key)
  ns.CheckReset(c, key)
  local todo, done = {}, {}
  local totalGold, totalMins = 0, 0

  for _, a in ipairs(ns.ACTIVITIES) do
    if ns.Applies(c, a) then
      local s = ns.ActSet(a)
      local d, count, inLog, saList = ns.ActStatus(c, a)
      local left = math.max(0, count - d)
      local est, learned = ns.EstGold(a)
      local e = {
        a = a, key = a.key, name = a.name, short = a.short,
        done = d, count = count, left = left, inLog = inLog,
        zone = (a.kind == "crafting") and "Profession hub" or ns.ZoneFor(a),
        gold = est * left, mins = s.minutes * left, unitGold = est, learned = learned,
        earned = (c.weekly[a.key] and c.weekly[a.key].gold) or 0,
      }
      -- Special Assignments: how many are up; the route stops in the zone
      -- of the first open one (unlocked ones first)
      if a.key == "special" then
        e.saOpen, e.saReady = {}, 0
        for _, sa in ipairs(saList or {}) do
          if not sa.done then
            e.saOpen[#e.saOpen + 1] = sa
            if sa.unlocked then e.saReady = e.saReady + 1 end
          end
        end
        e.sa = e.saOpen[1]
        if e.sa then e.zone = e.sa.zone end
      end
      -- where to pick it up (and whether it's offered right now)
      if ns.Pickups and a.kind ~= "crafting" and a.key ~= "special" then
        e.pickup = ns.Pickups.For(a)
        if e.pickup and e.zone == "Zone not learned yet" and e.pickup.zone then e.zone = e.pickup.zone end
      end
      -- Events-tab activities: this week's spot, and (Stormarion) whether it's on
      if a.eventTab and not a.schedule and ns.WQ then
        e.spot = a.eventMarker and ns.WQ.EventSpot(a) or nil
        local es = ns.WQ.SchedFor(a)
        if es and a.eventDone ~= false and a.eventMarker then e.eventRunning = (es.ongoing or es.window) and true or false end
      end
      if a.schedule then
        e.eventActive, e.nextIn, e.sched = ns.ScheduleInfo(a, c, key == ns.charKey)
        e.urgent = e.eventActive or (e.nextIn and e.nextIn < 10 * 60) or false
      end
      -- Crafting orders: professions scanned at their table in the last 36h
      -- count the profitable orders still open there, with their real
      -- profit; the others not done yet count the estimate.
      if a.kind == "crafting" then
        e.profs = ns.CraftStatus(c)
        if not (c.weekly.crafting and c.weekly.crafting.manual) then
          local n, profit, anyScanned, unchecked = 0, 0, false, 0
          for _, p in ipairs(e.profs) do
            if p.scanned then anyScanned, n, profit = true, n + p.n, profit + p.profit
            elseif not p.done then unchecked = unchecked + 1 end
          end
          if anyScanned then
            e.ordersN = n
            e.name = n > 0 and string.format("Crafting Orders (%d profitable)", n) or "Crafting Orders"
            e.gold = profit + est * unchecked
            e.unitGold, e.learned = e.gold, unchecked == 0
            e.mins = (n > 0 and math.max(s.minutes, 3 * n) or 0) + s.minutes * unchecked
          end
        end
      end
      if count == 0 then
        -- nothing up at all (no Special Assignment on the map)
      elseif left > 0 then
        todo[#todo + 1] = e
        totalGold = totalGold + e.gold
        totalMins = totalMins + e.mins
      else
        done[#done + 1] = e
      end
    end
  end

  -- Gold world quests: one summary entry (the WQ window has the details)
  local wqList, wqGold = {}, 0
  if ns.WQ then
    wqList, wqGold = ns.WQ.Remaining(c)
    if #wqList > 0 then
      local now = time()
      local urgent = 0
      for _, q in ipairs(wqList) do
        if q.expires and (q.expires - now) < 4 * 3600 then urgent = urgent + 1 end
      end
      local e = {
        name = "World Quests", short = "WQ", isWQGroup = true,
        done = 0, count = #wqList, left = #wqList, inLog = false,
        zone = "World quests", gold = wqGold, mins = (ns.DB.settings.wq.minutes or 4) * #wqList,
        unitGold = wqGold, learned = true, urgent = urgent > 0, urgentCount = urgent, list = wqList,
      }
      todo[#todo + 1] = e
      totalGold = totalGold + e.gold
      totalMins = totalMins + e.mins
    end
  end

  local zones, zl = {}, {}
  for _, e in ipairs(todo) do
    local z = zones[e.zone]
    if not z then
      z = { name = e.zone, gold = 0, mins = 0, items = {}, inLog = false }
      zones[e.zone] = z
      zl[#zl + 1] = z
    end
    z.gold = z.gold + e.gold
    z.mins = z.mins + e.mins
    z.inLog = z.inLog or e.inLog
    z.urgent = z.urgent or e.urgent
    z.items[#z.items + 1] = e
  end
  for _, z in ipairs(zl) do z.gpm = z.gold / math.max(1, z.mins) end
  local UNKNOWN = "Zone not learned yet"
  table.sort(zl, function(x, y)
    -- known zones form the real route; unknown-zone tasks go last
    -- time-critical first: an event starting soon, a world quest expiring
    if (x.urgent or false) ~= (y.urgent or false) then return x.urgent end
    local ux, uy = x.name == UNKNOWN, y.name == UNKNOWN
    if ux ~= uy then return uy end
    if x.gpm ~= y.gpm then return x.gpm > y.gpm end
    return x.name < y.name
  end)

  local steps = {}
  for _, z in ipairs(zl) do
    table.sort(z.items, function(x, y)
      if x.inLog ~= y.inLog then return x.inLog end
      if (x.urgent or false) ~= (y.urgent or false) then return x.urgent end
      local gx, gy = x.gold / math.max(1, x.mins), y.gold / math.max(1, y.mins)
      if gx ~= gy then return gx > gy end
      return x.name < y.name
    end)
    for _, e in ipairs(z.items) do e.zoneGPM = z.gpm; steps[#steps + 1] = e end
  end

  return { steps = steps, done = done, gold = totalGold, mins = totalMins, zones = zl, char = c,
    wq = wqList, wqGold = wqGold }
end

-- During one UI refresh the same routes are asked for several times (the
-- header, the tab, the compact tracker): they're worked out once and
-- reused for that refresh only (ns.BeginRefresh / ns.EndRefresh).
local memo
function ns.BeginRefresh() memo = { t = GetTime(), routes = {} } end
function ns.EndRefresh() memo = nil end
local function Memo() return memo and memo.t == GetTime() and memo or nil end

function ns.BuildRoute(key)
  local m = Memo()
  if not m then return BuildRoute(key) end
  local k = key or ns.charKey
  local r = m.routes[k]
  if not r then r = BuildRoute(key); m.routes[k] = r end
  return r
end

local AltQueue
function ns.AltQueue()
  local m = Memo()
  if not m then return AltQueue() end
  m.queue = m.queue or AltQueue()
  return m.queue
end

-- Every tracked character sorted by remaining estimated gold.
function AltQueue()
  local list = {}
  local minLevel = ns.DB.settings.minLevel or 0
  for key, c in pairs(ns.DB.chars) do
    if (c.level or 0) >= minLevel or key == ns.charKey then
      local r = ns.BuildRoute(key)
      list[#list + 1] = { key = key, c = c, gold = r.gold, mins = r.mins, left = #r.steps, route = r,
        wqN = #r.wq, wqGold = r.wqGold }
    end
  end
  table.sort(list, function(x, y)
    if x.gold ~= y.gold then return x.gold > y.gold end
    return x.key < y.key
  end)
  return list
end

function ns.WeekIncome(c)
  local n = 0
  for src, v in pairs(c.wIn or {}) do if src ~= "Transfer" then n = n + v end end
  return n
end

function ns.WeekSpend(c)
  local n = 0
  for src, v in pairs(c.wOut or {}) do if src ~= "Transfer" then n = n + v end end
  return n
end
