local ADDON, ns = ...

--[[
  Gold world quests.

  World quests rotate, so instead of a fixed list the addon scans the
  Midnight zone maps for every active world quest, reads its gold reward
  and time left, and keeps a shared list (world quests are the same for
  every character in the region). Each character then tracks which of
  those it has completed.

  Zone maps are found by name once per game build. If a zone is missing,
  stand in it and type /gc wqhere.
--]]

local WQ = {}
ns.WQ = WQ

-- Midnight maps to scan, by ID so it works in every client language
-- (12.1.5). Everything under them (cities, caves, delves...) is included.
local MAP_IDS = {
  2537, 2561,                         -- Quel'Thalas (continent)
  2393, 2443, 2605,                   -- Silvermoon City
  2395, 2567, 2594,                   -- Eversong Woods
  2437, 2568, 2585, 2536,             -- Zul'Aman, Atal'Aman
  2413, 2480,                         -- Harandar
  2405, 2479,                         -- Voidstorm
  2424, 2432, 2565, 2566, 2569,       -- Isle of Quel'Danas
  2512,                               -- The Coiled Isle
}
local COILED = { [2512] = true }      -- needs level 90

-- Backup on English clients only: zones added by a later patch are found
-- by name (Midnight maps have IDs above 2300; lower ones are the old
-- Burning Crusade versions of the same zones).
local MAP_NAMES = {
  "Quel'Thalas", "Eversong Woods", "Silvermoon City", "Zul'Aman",
  "Harandar", "Voidstorm", "Isle of Quel'Danas", "Coiled Isle",
}
local MIDNIGHT_MAP_MIN = 2300

local function S() return ns.DB.settings.wq end

local function GetQuests(mapID)
  if not C_TaskQuest then return {} end
  local fn = C_TaskQuest.GetQuestsOnMap or C_TaskQuest.GetQuestsForPlayerByMapID
  if not fn then return {} end
  local ok, list = pcall(fn, mapID)
  return ok and list or {}
end

local function IsWorldQuest(qid)
  return C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(qid)
end
WQ.IsWorldQuest = IsWorldQuest

-- Finds the map IDs to scan; cached per game build.
-- Every map under the listed ones is included whatever its name or type
-- (zone, city, sub-zone), so areas like the Coiled Isle aren't missed.
local MAPS_VERSION = 3
function WQ.FindMaps(force)
  local DB = ns.DB
  local build = GetBuildInfo and select(1, GetBuildInfo()) or "?"
  if not force and DB.wqMaps and DB.wqMapsBuild == build and DB.wqMapsVer == MAPS_VERSION and next(DB.wqMaps) then
    return DB.wqMaps
  end
  local maps = {}
  local T = Enum and Enum.UIMapType or {}
  local function matches(name)
    local ln = name:lower()
    for _, n in ipairs(MAP_NAMES) do
      if ln == n:lower() or ln:find(n:lower(), 1, true) then return true end
    end
  end
  local function addTree(id, name)
    maps[id] = name
    if C_Map.GetMapChildrenInfo then
      local ok, kids = pcall(C_Map.GetMapChildrenInfo, id, nil, true) -- all descendants
      for _, ch in ipairs(ok and kids or {}) do
        if ch.mapType ~= T.Dungeon then maps[ch.mapID] = ch.name end
      end
    end
  end
  for _, id in ipairs(MAP_IDS) do
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    if info then addTree(id, info.name) end
  end
  local english = GetLocale and GetLocale():match("^en") ~= nil
  if english and C_Map and C_Map.GetMapInfo then
    for id = MIDNIGHT_MAP_MIN, 5000 do
      local info = not maps[id] and C_Map.GetMapInfo(id)
      if info and info.name and info.mapType ~= T.Dungeon and matches(info.name) then
        if info.mapType == T.Continent or info.mapType == T.Zone or info.mapType == T.City
           or info.mapType == T.Micro or info.mapType == T.Orphan then
          addTree(id, info.name)
        end
      end
    end
  end
  for id, name in pairs(DB.wqExtraMaps or {}) do addTree(id, name) end
  DB.wqMaps, DB.wqMapsBuild, DB.wqMapsVer = maps, build, MAPS_VERSION
  return maps
end

-- Adds the zone the player is standing in to the scan list.
function WQ.AddCurrentZone()
  local id = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local info = id and C_Map.GetMapInfo(id)
  if not info then return end
  ns.DB.wqExtraMaps = ns.DB.wqExtraMaps or {}
  ns.DB.wqExtraMaps[id] = info.name
  WQ.FindMaps(true)
  ns.Print(string.format("Now scanning %s (map %d) for world quests.", info.name, id))
  WQ.Scan()
end

local waitingForData = {}

-- Level a character needs for quests on a map: the Coiled Isle needs 90,
-- the rest of Midnight 80.
local levelCache = {}
local function MinLevelFor(mapID, zone)
  if zone and tostring(zone):lower():find("coiled", 1, true) then return 90 end
  if not mapID then return 80 end
  if levelCache[mapID] then return levelCache[mapID] end
  local lvl, id = 80, mapID
  for _ = 1, 6 do
    if COILED[id] then lvl = 90; break end
    local mi = id and C_Map.GetMapInfo(id)
    if not mi then break end
    if mi.name and mi.name:lower():find("coiled", 1, true) then lvl = 90; break end -- English backup
    id = mi.parentMapID
  end
  levelCache[mapID] = lvl
  return lvl
end
WQ.MinLevelFor = MinLevelFor

local function LevelOK(c, e)
  return (c.level or 0) >= (e.minLevel or MinLevelFor(e.map, e.zone))
end

-- Another character only counts what was open when you last played it
-- (each character has its own Special Assignments and progress). One not
-- logged in since that's been recorded is estimated from what's on the map
-- now (WQ.IsEstimate).
-- shared: gold world quests are the same for every level-90 character, so
-- one a level-90 character found since that alt was last played (it never
-- saw it, and hasn't done it) counts for a level-90 alt too.
local function KnownOpen(c, qid, shared)
  if c == ns.GetChar() or not c.wqOpen then return true end
  if c.wqOpen[qid] then return true end
  local e = shared and ns.DB.wq[qid]
  return (e and e.by90 and (c.level or 0) >= 90 and not (c.wqDone and c.wqDone[qid])) or false
end

function WQ.IsEstimate(c)
  return c ~= ns.GetChar() and c.wqOpen == nil
end

-- For map events like Aqir: the reward tells us if this week is done.
-- Returns "open" (epic bag offered), "done" (token offered) or nil (unknown yet).
local function EventRewardState(qid)
  if not (HaveQuestRewardData and HaveQuestRewardData(qid)) then
    if C_TaskQuest.RequestPreloadRewardData and not waitingForData[qid] then
      waitingForData[qid] = true
      C_TaskQuest.RequestPreloadRewardData(qid)
    end
    return nil
  end
  waitingForData[qid] = nil
  local n = GetNumQuestLogRewards and GetNumQuestLogRewards(qid) or 0
  if n == 0 then return nil end
  local containerClass = (Enum and Enum.ItemClass and Enum.ItemClass.Container) or 1
  local epicBag, other = false, false
  for i = 1, n do
    local name, _, _, quality, _, itemID = GetQuestLogRewardInfo(i, qid)
    if itemID or name then
      local classID = itemID and C_Item and C_Item.GetItemInfoInstant and select(6, C_Item.GetItemInfoInstant(itemID))
      local isBag = classID == containerClass
      if quality == 4 and isBag then
        epicBag = true
        local act = ns.ActivityForID(qid)
        if act and itemID then
          ns.DB.eventBags = ns.DB.eventBags or {}
          ns.DB.eventBags[act.key] = ns.DB.eventBags[act.key] or {}
          ns.DB.eventBags[act.key][itemID] = true
        end
      else other = true end
    end
  end
  if epicBag then return "open" end
  if other then return "done" end
end
WQ.EventRewardState = EventRewardState

function WQ.Scan()
  local DB = ns.DB
  if not DB or not S().enabled then return end
  local now = time()
  local list = DB.wq
  local seen, any = {}, false

  for mapID, mapName in pairs(WQ.FindMaps()) do
    for _, q in ipairs(GetQuests(mapID)) do
      local qid = q.questID or q.questId
      -- Weeklies shown on the map (e.g. this week's Abundant Offerings):
      -- remember which zone they're in, for the route.
      local act = qid and ns.ActivityForID(qid)
      -- map events (Aqir) can also be recognised by name the first time
      if qid and not act and C_TaskQuest.GetQuestInfoByQuestID then
        local byName = ns.MatchTitle(C_TaskQuest.GetQuestInfoByQuestID(qid))
        if byName and byName.mapEvent and not DB.blocked[qid] then
          act = byName
          ns.Learn(act, qid, C_TaskQuest.GetQuestInfoByQuestID(qid))
        end
      end
      if act and act.mapEvent then
        local state = EventRewardState(qid)
        local c = ns.GetChar()
        local w = ns.Weekly(c, act.key)
        w.eventState = state or w.eventState
        if state == "done" and w.done < 1 then w.done = 1; w.at = time() end
      end
      if act then
        local mi = C_Map.GetMapInfo(q.mapID or mapID)
        local zone = (mi and mi.name) or mapName
        if zone and DB.zones[act.key] ~= zone then
          DB.zones[act.key] = zone
          DB.zonesFromMap = DB.zonesFromMap or {}
          DB.zonesFromMap[act.key] = true
        end
      end
      local taskTitle = qid and C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(qid)
      if qid and not taskTitle and C_QuestLog.RequestLoadQuestByID and not waitingForData["t" .. qid] then
        waitingForData["t" .. qid] = true
        C_QuestLog.RequestLoadQuestByID(qid)
        WQ.QueueScan(3)
      end
      local titleAct = taskTitle and ns.MatchTitle(taskTitle)
      local isSA = (act and act.key == "special") or (titleAct and titleAct.key == "special") or false
      if qid and not seen[qid] and (IsWorldQuest(qid) or isSA) then
        seen[qid], any = true, true
        local e = list[qid] or {}
        local m = q.mapID or mapID
        local mi = C_Map.GetMapInfo(m)
        e.map = m
        e.zone = (mi and mi.name) or mapName
        e.minLevel = MinLevelFor(m, e.zone)
        if (ns.GetChar().level or 0) >= 90 then e.by90 = true end -- shown to level-90 alts (KnownOpen)
        e.title = (C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(qid)) or e.title or ("World Quest " .. qid)
        local left = C_TaskQuest.GetQuestTimeLeftSeconds and C_TaskQuest.GetQuestTimeLeftSeconds(qid)
        if left and left > 0 then e.expires = now + left end
        if HaveQuestRewardData and HaveQuestRewardData(qid) then
          -- a character too low for the quest is shown no gold reward:
          -- don't let that overwrite the real amount for everyone
          local g = GetQuestLogRewardMoney and GetQuestLogRewardMoney(qid) or 0
          if g > 0 or (ns.GetChar().level or 0) >= e.minLevel then e.gold = g end
          waitingForData[qid] = nil
        elseif C_TaskQuest.RequestPreloadRewardData and not waitingForData[qid] then
          waitingForData[qid] = true
          C_TaskQuest.RequestPreloadRewardData(qid)
        end
        -- Activities like Special Assignment are tracked on their own
        e.activity = (act or ns.MatchTitle(e.title)) and true or nil
        if isSA then
          e.sa = true
          e.firstSeen = e.firstSeen or now
          DB.zones.special = e.zone
          if not DB.blocked[qid] then ns.Learn(ns.ACT_BY_KEY.special, qid, e.title) end
          -- unlock progress ("World quests completed 1/3") if the game exposes it
          local c = ns.GetChar()
          c.saProgress = c.saProgress or {}
          c.saProgress[qid] = nil
          if C_QuestLog.GetQuestObjectives then
            local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
            for _, o in ipairs(ok and objs or {}) do
              if o.numRequired and o.numRequired > 1 then
                c.saProgress[qid] = { have = o.numFulfilled or 0, need = o.numRequired }
                break
              end
            end
          end
        end
        list[qid] = e
      end
    end

    -- Locked Special Assignments aren't world quests yet: they're map
    -- points of interest named "Special Assignment: ..." with a time left.
    if C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap then
      local okP, pois = pcall(C_AreaPoiInfo.GetAreaPOIForMap, mapID)
      for _, poiID in ipairs(okP and pois or {}) do
        local okI, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
        if okI and info and info.name and info.position
           and info.name:lower():find("special assignment", 1, true) then
          local key = -poiID
          local mi = C_Map.GetMapInfo(mapID)
          local isContinent = mi and Enum and Enum.UIMapType and mi.mapType == Enum.UIMapType.Continent or false
          local e = list[key] or {}
          -- prefer the zone map over the continent view of the same pin
          if not e.map or not isContinent or e.fromContinent then
            e.map, e.mx, e.my = mapID, info.position.x, info.position.y
            e.zone = (mi and mi.name) or mapName
            e.fromContinent = isContinent
            e.cont = nil
            if isContinent then
              -- which zone is under the pin? (else "...in the Coiled Isle to unlock")
              local okZ, z = pcall(C_Map.GetMapInfoAtPosition, mapID, info.position.x, info.position.y)
              if okZ and z and z.name and z.mapID ~= mapID then
                e.zone = z.name
              else
                local fromText = (info.description or ""):match("in (.-) to unlock")
                if fromText and fromText ~= "" then e.zone = (fromText:gsub("^[Tt]he%s+", "")) end
              end
            end
          end
          e.title, e.poiID = info.name, poiID
          e.minLevel = math.max(MinLevelFor(e.map, e.zone), MinLevelFor(nil, info.description))
          e.primary = info.isPrimaryMapForPOI and true or false
          local dx, dy = info.position.x - 0.5, info.position.y - 0.5
          e.edge = dx * dx + dy * dy -- markers near a map's edge are usually a neighbour's
          e.sa, e.locked, e.activity = true, true, true
          e.saNeed = tonumber((info.description or ""):match("(%d+)")) or 3
          e.firstSeen = e.firstSeen or now
          local okS, secs = pcall(C_AreaPoiInfo.GetAreaPOISecondsLeft, poiID)
          if okS and secs and secs > 0 then e.expires = now + secs end
          seen[key], any = true, true
          list[key] = e
          DB.zones.special = e.zone
        end
      end
    end
  end

  -- One entry per Special Assignment: the same locked pin shows on several
  -- maps (zone, continent, world). Keep the unlocked quest if there is one,
  -- else the pin from the zone map.
  local best = {}
  local function rank(e)
    if not e.locked then return 4 end
    if e.primary then return 3 end
    if not e.fromContinent then return 2 end
    return 1
  end
  for key, e in pairs(list) do
    if e.sa and seen[key] then
      local name = (e.title or ""):lower()
      local cur = best[name] and list[best[name]]
      if not cur or rank(e) > rank(cur) or (rank(e) == rank(cur) and (e.edge or 1) < (cur.edge or 1)) then
        best[name] = key
      end
    end
  end
  for key, e in pairs(list) do
    if e.sa and seen[key] and best[(e.title or ""):lower()] ~= key then list[key] = nil; seen[key] = nil end
  end

  -- Drop expired quests, and ones no longer on the map (only if the scan worked)
  for qid, e in pairs(list) do
    if (e.expires and e.expires <= now) or (any and not seen[qid]) then list[qid] = nil end
  end

  -- Completion snapshot for this character + forget finished ones that rotated out
  -- (kept until the quest expires, not only while a scan sees it: a level-90
  -- alt would otherwise get a quest it did offered again, see KnownOpen)
  local c = ns.GetChar()
  c.wqDone = c.wqDone or {}
  for qid, e in pairs(list) do
    if qid > 0 and C_QuestLog.IsQuestFlaggedCompleted(qid) then c.wqDone[qid] = e.expires or (now + 7 * 86400) end
  end
  -- what's open on this character, so its alt-grid row shows its own
  -- world quests / Special Assignments rather than the current character's
  c.wqOpen = {}
  for qid in pairs(list) do
    if not c.wqDone[qid] then c.wqOpen[qid] = true end
  end
  for _, ch in pairs(DB.chars) do
    if ch.wqDone then
      for qid, v in pairs(ch.wqDone) do
        if (type(v) == "number" and v <= now) or (v == true and not list[qid]) then ch.wqDone[qid] = nil end
      end
    end
  end
  -- tidy per-character SA data
  for _, ch in pairs(DB.chars) do
    for qid in pairs(ch.saProgress or {}) do if not list[qid] then ch.saProgress[qid] = nil end end
    for zone, log in pairs(ch.wqZoneLog or {}) do
      for qid, t in pairs(log) do if now - t > 8 * 86400 then log[qid] = nil end end
      if not next(log) then ch.wqZoneLog[zone] = nil end
    end
  end
  DB.wqScanned = now
  pcall(WQ.ScanEventPOIs)
  pcall(WQ.ScanScheduler)
  if ns.Pickups then
    local ok, err = pcall(ns.Pickups.Scan)
    if not ok then ns.Pickups.lastError = err end
  end
  ns.Refresh()
end

local scanQueued = false
function WQ.QueueScan(delay)
  if scanQueued then return end
  scanQueued = true
  C_Timer.After(delay or 2, function()
    scanQueued = false
    WQ.Scan()
  end)
end

-- Reward data is waited on by quest ID, quest names by "t"..questID.
-- Quest data arrives in bursts (35 a minute with the map open), and a zone
-- scan is the costliest job: a listed quest's gold is filled in directly,
-- anything else waits for one scan 10 seconds later.
function WQ.OnDataLoaded(qid)
  local tkey = "t" .. tostring(qid)
  if not (waitingForData[qid] or waitingForData[tkey]) then return end
  local e = ns.DB.wq[qid]
  if e and not waitingForData[tkey] and HaveQuestRewardData and HaveQuestRewardData(qid) then
    waitingForData[qid] = nil
    local g = GetQuestLogRewardMoney and GetQuestLogRewardMoney(qid) or 0
    if g > 0 or (ns.GetChar().level or 0) >= (e.minLevel or 80) then
      if e.gold ~= g then e.gold = g; ns.Refresh() end
    end
    return
  end
  waitingForData[tkey] = nil
  WQ.QueueScan(10)
end

-- The chat line waits for the actual gold received (it includes bonuses
-- such as War Mode, which the listed reward doesn't).
local pendingPrint

local function PrintDone(p, amount)
  if not ns.DB.settings.announce then return end
  local extra = ""
  if amount and p.base and p.base > 0 and amount > p.base then
    extra = string.format(" |cff888888(%s + %s bonus)|r", ns.Money(p.base), ns.Money(amount - p.base))
  end
  ns.Print(string.format("World quest done: %s — %s%s", p.title, ns.Money(amount or p.base or 0), extra))
end

function WQ.OnTurnedIn(qid)
  local e = ns.DB.wq[qid]
  local c = ns.GetChar()
  c.wqDone = c.wqDone or {}
  c.wqDone[qid] = (e and e.expires) or (time() + 7 * 86400)
  if e and e.zone and not e.sa then
    c.wqZoneLog = c.wqZoneLog or {}
    c.wqZoneLog[e.zone] = c.wqZoneLog[e.zone] or {}
    c.wqZoneLog[e.zone][qid] = time()
  end
  if e and e.gold and e.gold > 0 then
    local p = { qid = qid, title = e.title or ("World Quest " .. qid), base = e.gold, t = GetTime() }
    pendingPrint = p
    -- fallback if no money change shows up (e.g. gold went somewhere odd)
    C_Timer.After(3, function()
      if pendingPrint == p then pendingPrint = nil; PrintDone(p, nil) end
    end)
  end
end

-- Called by the ledger when World Quest gold is recorded.
function WQ.OnGold(amount)
  local p = pendingPrint
  if p and GetTime() - p.t < 3 then
    pendingPrint = nil
    PrintDone(p, amount)
  end
end

-- War Mode bonus (%) for the character you're on; stored so alts keep theirs.
function WQ.UpdateWarMode()
  local pct = 0
  if C_PvP and C_PvP.IsWarModeActive and C_PvP.IsWarModeActive() then
    pct = (C_PvP.GetWarModeRewardBonus and C_PvP.GetWarModeRewardBonus()) or 10
  end
  local c = ns.GetChar()
  if c.warmode ~= pct then
    c.warmode = pct
    ns.Refresh()
  end
end

-- Gold world quests still open for a character, best first.
-- Gold includes that character's War Mode bonus.
function WQ.Remaining(c)
  local out, total = {}, 0
  local s = S()
  if not s.enabled then return out, 0 end
  if (c.level or 0) < 80 then return out, 0 end
  local now, minGold = time(), (s.minGold or 0) * 10000
  local mult = 1 + (c.warmode or 0) / 100
  for qid, e in pairs(ns.DB.wq) do
    local gold = math.floor((e.gold or 0) * mult)
    if not e.activity and (e.gold or 0) > 0 and gold >= minGold
       and (not e.expires or e.expires > now)
       and not (c.wqDone and c.wqDone[qid]) and LevelOK(c, e) and not WQ.IsSkipped(qid) and KnownOpen(c, qid, true) then
      out[#out + 1] = { qid = qid, title = e.title, zone = e.zone, gold = gold, base = e.gold, expires = e.expires,
        minLevel = e.minLevel }
      total = total + gold
    end
  end
  table.sort(out, function(a, b) return a.gold > b.gold end)
  return out, total
end

------------------------------------------------------------------------
-- Skipping world quests you don't want to do
------------------------------------------------------------------------
WQ.sessionSkip = {}

function WQ.IsSkipped(qid)
  return (WQ.sessionSkip[qid] or (ns.DB.wqSkip and ns.DB.wqSkip[qid])) and true or false
end

function WQ.Skip(qid, permanent)
  local e = ns.DB.wq[qid]
  local title = (e and e.title) or ("World Quest " .. qid)
  if permanent then
    ns.DB.wqSkip[qid] = title
    ns.Print(string.format("Skipping %s from now on. |cff888888(Skipped list in the World Quest Tracker, or /gc unskip)|r", title))
  else
    WQ.sessionSkip[qid] = title
    ns.Print(string.format("Skipping %s until you log out.", title))
  end
  if WQ.IsWatched(qid) or WQ.IsSuperTracked(qid) then WQ.Untrack(qid) end
  ns.Refresh()
end

function WQ.Unskip(qid)
  WQ.sessionSkip[qid] = nil
  ns.DB.wqSkip[qid] = nil
  ns.Refresh()
end

-- Every skipped quest: { qid, title, permanent }
function WQ.Skipped()
  local out = {}
  for qid, t in pairs(ns.DB.wqSkip or {}) do out[#out + 1] = { qid = qid, title = t, permanent = true } end
  for qid, t in pairs(WQ.sessionSkip) do
    if not (ns.DB.wqSkip and ns.DB.wqSkip[qid]) then out[#out + 1] = { qid = qid, title = t, permanent = false } end
  end
  table.sort(out, function(a, b) return tostring(a.title) < tostring(b.title) end)
  return out
end

function WQ.ClearSkips()
  wipe(WQ.sessionSkip)
  wipe(ns.DB.wqSkip)
  ns.Print("All skipped world quests are back in the list.")
  ns.Refresh()
end

-- Objective lines ("Slay 8 Wyrmspawn 0/8") and the quest type, for tooltips.
function WQ.Objectives(qid)
  local out = {}
  if not qid or qid < 0 then return out end
  if C_QuestLog.GetQuestObjectives then
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
    for _, o in ipairs(ok and objs or {}) do
      if o.text and o.text ~= "" then out[#out + 1] = { text = o.text, done = o.finished } end
    end
  end
  if #out == 0 and C_QuestLog.GetNumQuestObjectives and GetQuestObjectiveInfo then
    for i = 1, C_QuestLog.GetNumQuestObjectives(qid) or 0 do
      local text, _, finished = GetQuestObjectiveInfo(qid, i, false)
      if text and text ~= "" then out[#out + 1] = { text = text, done = finished } end
    end
  end
  if #out == 0 and C_QuestLog.RequestLoadQuestByID then pcall(C_QuestLog.RequestLoadQuestByID, qid) end
  return out
end

function WQ.QuestType(qid)
  if not (qid and qid > 0 and C_QuestLog.GetQuestTagInfo) then return end
  local ok, info = pcall(C_QuestLog.GetQuestTagInfo, qid)
  return ok and info and info.tagName or nil
end

------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------
local function Title(qid)
  local e = ns.DB.wq[qid]
  return (e and e.title) or ("World Quest " .. qid), (e and e.zone) or "?"
end

-- The quest behind a Special Assignment listed by its map pin (negative
-- key): its world quest on the map once unlocked, or the unlock quest in
-- your log while locked. Matched by name; completed quests are skipped
-- (the unlock step is completed when the assignment unlocks).
function WQ.ResolveSA(key)
  local e = ns.DB.wq[key]
  if not (e and e.sa) then return end
  local done = C_QuestLog.IsQuestFlaggedCompleted
  if e.realQid and not done(e.realQid) then return e.realQid end
  local want = ns.SAKey(e.title)
  local function Match(q, title)
    return q and q > 0 and title and ns.SAKey(title) == want and not done(q)
  end
  local maps = { e.map }
  for id in pairs(WQ.FindMaps()) do maps[#maps + 1] = id end
  for _, m in ipairs(maps) do
    for _, q in ipairs(GetQuests(m)) do
      local id = q.questID or q.questId
      if Match(id, C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(id)) then
        e.realQid = id
        return id
      end
    end
  end
  for i = 1, (C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0) do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and Match(info.questID, info.title) then
      e.realQid = info.questID
      return info.questID
    end
  end
end

-- A pin row counts as tracked when its real quest is.
local function RealQid(qid)
  local e = qid < 0 and ns.DB.wq[qid]
  return e and e.realQid
end

function WQ.IsWatched(qid)
  if qid < 0 then
    local real = RealQid(qid)
    return real and WQ.IsWatched(real) or false
  end
  if C_QuestLog.GetQuestWatchType then
    local ok, t = pcall(C_QuestLog.GetQuestWatchType, qid)
    if ok and t ~= nil then return true end
  end
  return false
end

local PIN_AREAPOI = (Enum and Enum.SuperTrackingMapPinType and Enum.SuperTrackingMapPinType.AreaPOI) or 0
WQ.PIN_AREAPOI = PIN_AREAPOI

function WQ.IsSuperTracked(qid)
  if qid < 0 then
    local real = RealQid(qid)
    if real and WQ.IsSuperTracked(real) then return true end
    if not (C_SuperTrack and C_SuperTrack.GetSuperTrackedMapPin) then return false end
    local ok, t, id = pcall(C_SuperTrack.GetSuperTrackedMapPin)
    return ok and t == PIN_AREAPOI and id == -qid or false
  end
  return C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID
    and C_SuperTrack.GetSuperTrackedQuestID() == qid or false
end

local function CombatBlocked()
  if InCombatLockdown and InCombatLockdown() then
    ns.Warn("Can't change quest tracking in combat — try again after.")
    return true
  end
end

-- Adds to the objective tracker and makes it the active waypoint (arrow).
function WQ.Track(qid)
  local label, labelZone
  if qid < 0 then
    -- a Special Assignment listed by its map pin: track its real quest
    -- if there is one; otherwise its map marker, like clicking it on the map
    local e = ns.DB.wq[qid]
    local real = WQ.ResolveSA(qid)
    if not real then
      if C_SuperTrack and C_SuperTrack.SetSuperTrackedMapPin and pcall(C_SuperTrack.SetSuperTrackedMapPin, PIN_AREAPOI, -qid) then
        ns.Print(string.format("Tracking %s (%s).", e and e.title or "Special Assignment", e and e.zone or "?"))
      else
        WQ.SetWaypoint(qid) -- fallback: a map pin
      end
      ns.Refresh()
      return
    end
    label, labelZone = e and e.title, e and e.zone
    qid = real
  end
  if CombatBlocked() then return end
  if IsWorldQuest(qid) then
    if C_QuestLog.AddWorldQuestWatch then
      local manual = Enum and Enum.QuestWatchType and Enum.QuestWatchType.Manual
      pcall(C_QuestLog.AddWorldQuestWatch, qid, manual)
    end
  elseif C_QuestLog.AddQuestWatch then
    pcall(C_QuestLog.AddQuestWatch, qid) -- a quest in your log
  end
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
    pcall(C_SuperTrack.SetSuperTrackedQuestID, qid)
  end
  local title, zone = Title(qid)
  ns.Print(string.format("Tracking %s (%s).", label or title, labelZone or zone))
  ns.Refresh()
end

function WQ.Untrack(qid)
  if qid < 0 then
    local real = RealQid(qid)
    if real and (WQ.IsWatched(real) or WQ.IsSuperTracked(real)) then return WQ.Untrack(real) end
    if WQ.IsSuperTracked(qid) and C_SuperTrack.ClearSuperTrackedMapPin then pcall(C_SuperTrack.ClearSuperTrackedMapPin)
    elseif C_Map.ClearUserWaypoint then C_Map.ClearUserWaypoint() end
    ns.Refresh()
    return
  end
  if CombatBlocked() then return end
  if C_QuestLog.RemoveWorldQuestWatch then pcall(C_QuestLog.RemoveWorldQuestWatch, qid) end
  if not IsWorldQuest(qid) and C_QuestLog.RemoveQuestWatch then pcall(C_QuestLog.RemoveQuestWatch, qid) end
  if WQ.IsSuperTracked(qid) and C_SuperTrack.SetSuperTrackedQuestID then
    pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
  end
  ns.Refresh()
end

function WQ.ToggleTrack(qid)
  if WQ.IsWatched(qid) or WQ.IsSuperTracked(qid) then WQ.Untrack(qid) else WQ.Track(qid) end
end

-- Drops a map pin at the quest's location.
function WQ.SetWaypoint(qid)
  local e = ns.DB.wq[qid]
  if not (e and e.map and C_Map.SetUserWaypoint and UiMapPoint) then return end
  local x, y = e.mx, e.my
  if not x and C_TaskQuest.GetQuestLocation then x, y = C_TaskQuest.GetQuestLocation(qid, e.map) end
  if not x then ns.Warn("Location not available for that quest yet.") return end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(e.map, x, y))
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
  if ns.Travel then ns.Travel.SetGoalLabel(e.title or "Map pin", { map = e.map, mx = x, my = y }) end
  ns.Print(string.format("Map pin set: %s (%s %.1f, %.1f).", e.title or qid, e.zone or "?", x * 100, y * 100))
end

function WQ.ShowOnMap(qid)
  local e = ns.DB.wq[qid]
  if e and e.map and OpenWorldMap then OpenWorldMap(e.map) end
end

-- Right-click menu for a world quest / Special Assignment row.
function WQ.Menu(owner, qid)
  local e = ns.DB.wq[qid]
  ns.Style.Menu(owner, function(_, root)
    root:CreateTitle((e and e.title) or ("World Quest " .. qid))
    local tracked = WQ.IsWatched(qid) or WQ.IsSuperTracked(qid)
    root:CreateButton(tracked and "Untrack" or "Track", function() WQ.ToggleTrack(qid) end)
    root:CreateButton("Show on map", function() WQ.ShowOnMap(qid) end)
    root:CreateButton("Map pin", function() WQ.SetWaypoint(qid) end)
    if qid > 0 and not (e and e.sa) then
      root:CreateDivider()
      root:CreateButton("Skip for this session", function() WQ.Skip(qid, false) end)
      root:CreateButton("Skip permanently", function() WQ.Skip(qid, true) end)
    end
  end, true)
end

-- Shared click handler: Left = track/untrack, Shift = open map,
-- Ctrl = map pin, Right = menu (track, pin, skip).
function WQ.OnClick(qid, button, owner)
  if button == "RightButton" then WQ.Menu(owner, qid)
  elseif IsShiftKeyDown and IsShiftKeyDown() then WQ.ShowOnMap(qid)
  elseif IsControlKeyDown and IsControlKeyDown() then WQ.SetWaypoint(qid)
  else WQ.ToggleTrack(qid) end
end

------------------------------------------------------------------------
-- Distance (world coordinates are in yards)
------------------------------------------------------------------------
function WQ.PlayerWorldPos()
  if not (C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return end
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end -- e.g. inside instances
  local cont, wp = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if cont and wp then return cont, wp.x, wp.y end
end

-- Quest locations don't move, so they're cached on the shared entry.
function WQ.QuestWorldPos(qid)
  local e = ns.DB.wq[qid]
  if not (e and e.map) then return end
  if e.cont then return e.cont, e.wx, e.wy end
  if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local x, y = e.mx, e.my
  if not x and C_TaskQuest.GetQuestLocation then x, y = C_TaskQuest.GetQuestLocation(qid, e.map) end
  if not x then return end
  local cont, wp = C_Map.GetWorldPosFromMapPos(e.map, CreateVector2D(x, y))
  if cont and wp then
    e.cont, e.wx, e.wy = cont, wp.x, wp.y
    return cont, wp.x, wp.y
  end
end

-- Yards from the player, or nil if unknown / on a different continent.
function WQ.Distance(qid, pc, px, py)
  if not pc then return end
  local qc, qx, qy = WQ.QuestWorldPos(qid)
  if not qc or qc ~= pc then return end
  local dx, dy = qx - px, qy - py
  return math.sqrt(dx * dx + dy * dy)
end

function WQ.FormatDistance(yd)
  if not yd then return "|cff666666—|r" end
  if yd >= 1000 then return string.format("%.1fk yd", yd / 1000) end
  return string.format("%d yd", math.floor(yd / 10 + 0.5) * 10)
end

WQ.CLICK_HINT = "Click: track · Shift: map · Ctrl: pin · Right-click: skip & more"

------------------------------------------------------------------------
-- Special Assignments
------------------------------------------------------------------------
local function NormZone(z) return (tostring(z or ""):lower():gsub("^the%s+", "")) end
function WQ.SameZone(a, b) return a and b and NormZone(a) == NormZone(b) or false end

-- Open Special Assignments for a character: zone, time left and unlock
-- progress (3 world quests in that zone). Progress comes from the quest's
-- objectives when the game provides it, otherwise from the world quests
-- this character turned in there since the assignment appeared.
function WQ.SpecialAssignments(c)
  local out, now = {}, time()
  local s = ns.ActSet(ns.ACT_BY_KEY.special)
  if not s.enabled then return out end
  -- assignments this character turned in this week, by name (a locked
  -- assignment's map pin and its unlocked quest have different IDs)
  -- (only real completions: the unlock step has the same name but isn't one)
  local turnedIn = {}
  local weekStart = (c.weekReset or ns.NextReset()) - 604800
  for _, r in ipairs(ns.DB.recentTurnins or {}) do
    if r.saDone and r.t >= weekStart and r.title and ns.DB.chars[r.char] == c then turnedIn[ns.SAKey(r.title)] = true end
  end
  for qid, e in pairs(ns.DB.wq) do
    if e.sa and (not e.expires or e.expires > now) and LevelOK(c, e) and KnownOpen(c, qid) then
      local key = ns.SAKey(e.title)
      local done = (c.wqDone and c.wqDone[qid]) or turnedIn[key] or false
      local prog = c.saProgress and c.saProgress[qid]
      local unlockedNow = c.saUnlocked and c.saUnlocked[key] == c.weekReset
      local have, need, exact
      if unlockedNow then
        -- its unlock step was turned in this week
        have, need, exact = 3, 3, true
      elseif prog then
        have, need, exact = prog.have, prog.need, true
      elseif not e.locked then
        -- the game only lists it as a world quest once it's unlocked
        have, need, exact = 3, 3, true
      else
        need, have, exact = e.saNeed or 3, 0, false
        for zone, log in pairs(c.wqZoneLog or {}) do
          if WQ.SameZone(zone, e.zone) then
            for _, t in pairs(log) do
              if t >= (e.firstSeen or 0) then have = have + 1 end
            end
          end
        end
        have = math.min(have, need)
      end
      local open = 0
      for q2, w in pairs(ns.DB.wq) do
        if not w.sa and not w.activity and WQ.SameZone(w.zone, e.zone) and (not w.expires or w.expires > now)
           and not (c.wqDone and c.wqDone[q2]) then open = open + 1 end
      end
      out[#out + 1] = {
        qid = qid, title = e.title, short = (e.title or ""):gsub("^Special Assignment:%s*", ""),
        zone = e.zone, map = e.map, expires = e.expires, have = have, need = need, exact = exact,
        unlocked = have >= need, done = done, openInZone = open,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.done ~= b.done then return not a.done end
    if a.unlocked ~= b.unlocked then return a.unlocked end
    return (a.expires or math.huge) < (b.expires or math.huge)
  end)
  return out
end

-- Zones that have an open (not done) Special Assignment for this character
-- (list: WQ.SpecialAssignments(c), if already worked out).
function WQ.SAZones(c, list)
  local z = {}
  for _, sa in ipairs(list or WQ.SpecialAssignments(c)) do
    if not sa.done then z[NormZone(sa.zone)] = sa end
  end
  return z
end

------------------------------------------------------------------------
-- Live world events (Aqir Invasion)
------------------------------------------------------------------------
local function MatchesEvent(a, text)
  if not text or text == "" then return false end
  local lt = text:lower()
  for _, p in ipairs(a.eventNames or a.patterns or {}) do
    if lt:find(p:lower(), 1, true) then return true end
  end
  return false
end

-- Name of the scenario you're in, if any.
local function ScenarioName()
  if C_ScenarioInfo and C_ScenarioInfo.GetScenarioInfo then
    local ok, info = pcall(C_ScenarioInfo.GetScenarioInfo)
    if ok and type(info) == "table" and info.name and info.name ~= "" then return info.name end
  end
  if C_Scenario and C_Scenario.GetInfo then
    local ok, name = pcall(C_Scenario.GetInfo)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
end

-- Bonus objectives / area tasks in progress on the map you're on.
local function TasksHere()
  local out = {}
  local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if not mapID then return out end
  for _, q in ipairs(GetQuests(mapID)) do
    local qid = q.questID or q.questId
    if qid and (q.inProgress or (C_TaskQuest.IsActive and C_TaskQuest.IsActive(qid))) then
      out[#out + 1] = { qid = qid, title = C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(qid) }
    end
  end
  return out
end

-- Event markers on the scanned maps, refreshed by Scan. Two kinds per event:
--   DB.eventPOIs[key] - the event itself while it runs ("Aqir Invasion")
--   DB.eventHubs[key] - the NPCs that are always there ("Aqir Researchers")
-- The same marker shows on several maps (a city and the zones around it);
-- the one the game calls its primary map wins, else the most detailed map
-- where it's nearest the middle (near an edge it's usually a neighbour's).
local function IsHub(a, name)
  for _, h in ipairs(a.hubNames or {}) do
    if name and name:lower():find(h:lower(), 1, true) then return true end
  end
  return false
end

function WQ.POIScore(info, mi, x, y)
  local T = Enum and Enum.UIMapType or {}
  local s = info.isPrimaryMapForPOI and 1000 or 0
  if mi and (mi.mapType == T.City or mi.mapType == T.Micro) then s = s + 300
  elseif mi and mi.mapType == T.Zone then s = s + 200
  elseif mi and mi.mapType == T.Continent then s = s - 500 end
  local dx, dy = x - 0.5, y - 0.5
  return s - (dx * dx + dy * dy) * 100
end

-- Only while an event (Aqir) is tracked, unless asked for (force).
function WQ.ScanEventPOIs(force)
  local DB = ns.DB
  if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo) then return end
  if not force then
    local wanted = false
    for _, a in ipairs(ns.ACTIVITIES) do
      if a.schedule and ns.ActSet(a).enabled then wanted = true end
    end
    if not wanted then return end
  end
  local now = time()
  local T = Enum and Enum.UIMapType or {}
  local events, hubs = {}, {}
  local Score = WQ.POIScore
  for mapID, mapName in pairs(WQ.FindMaps()) do
    local ids, seen = {}, {}
    for _, fn in ipairs({ C_AreaPoiInfo.GetAreaPOIForMap, C_AreaPoiInfo.GetEventsForMap }) do
      if fn then
        local ok, list = pcall(fn, mapID)
        for _, id in ipairs(ok and list or {}) do
          if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
      end
    end
    local mi = C_Map.GetMapInfo(mapID)
    for _, poiID in ipairs(ids) do
      local ok2, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
      if ok2 and info and info.name and info.position then
        for _, a in ipairs(ns.ACTIVITIES) do
          if a.schedule and (MatchesEvent(a, info.name) or MatchesEvent(a, info.description)) then
            local hub = IsHub(a, info.name)
            local bucket = hub and hubs or events
            local score = Score(info, mi, info.position.x, info.position.y)
            local cur = bucket[a.key]
            if not cur or score > cur.score then
              local okS, secs = pcall(C_AreaPoiInfo.GetAreaPOISecondsLeft, poiID)
              bucket[a.key] = { poiID = poiID, name = info.name, label = info.name, zone = (mi and mi.name) or mapName,
                map = mapID, mx = info.position.x, my = info.position.y, seen = now, score = score,
                ends = (okS and secs and secs > 0) and (now + secs) or nil,
                continent = mi and mi.mapType == T.Continent or false }
            end
          end
        end
      end
    end
  end
  DB.eventPOIs, DB.eventHubs = events, hubs
  for key, ev in pairs(hubs) do DB.zones[key] = ev.zone end
  for key, ev in pairs(events) do if not ev.continent then DB.zones[key] = ev.zone end end
end

------------------------------------------------------------------------
-- The map's Events tab (C_EventScheduler): what's running right now,
-- whether you've claimed its reward, and when the next one starts. This
-- is the server's own view, so an event someone else finished early no
-- longer shows as running.
------------------------------------------------------------------------
WQ.sched = nil -- [actKey] = { ongoing, claimed, ends, nextStart, nextEnd, hasReminder, t }
local SCHED_FRESH = 5 * 60

-- Name and map of an event's marker. Blizzard's Events tab looks it up
-- with no map ID (C_AreaPoiInfo.GetAreaPOIInfo(nil, areaPoiID)); the
-- event's own map is the fallback.
local function EventPOIInfo(poiID)
  if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo) then return end
  local ES = C_EventScheduler
  local okM, map = false, nil
  if ES.GetEventUiMapID then okM, map = pcall(ES.GetEventUiMapID, poiID) end
  map = okM and type(map) == "number" and map or nil
  local ok, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, nil, poiID)
  if not (ok and info and info.name) and map then
    ok, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, map, poiID)
  end
  if ok and info and info.name then return info, map end
  return nil, map
end

-- Which activity an event belongs to (cached by POI ID).
local poiMiss = {}
local function EventActivity(poiID)
  if not poiID then return end
  local DB = ns.DB
  local key = DB.eventPOIIDs[poiID]
  if key then return ns.ACT_BY_KEY[key] end
  if poiMiss[poiID] then return end
  local info = EventPOIInfo(poiID)
  if not info then return end -- no name yet: try again next scan
  local name = info.name:lower()
  for _, a in ipairs(ns.ACTIVITIES) do
    local hit = false
    if a.eventTab then
      for _, n in ipairs(a.eventTab) do
        if name:find(n:lower(), 1, true) then hit = true end
      end
    elseif a.schedule then
      hit = MatchesEvent(a, info.name) or MatchesEvent(a, info.description)
    end
    if hit then
      DB.eventPOIIDs[poiID] = a.key
      return a
    end
  end
  poiMiss[poiID] = true -- some other event
end

-- Where an event is: its map, the spot on it and the zone name. The Events
-- tab often gives no map (Abundance, Aqir), and a marker also shows on the
-- zones next to it, so every map it's on is scored like ScanEventPOIs does
-- (its own map wins, not a neighbour's edge). A marker that isn't up has no
-- position: then the spot it had last time (DB.eventPOIPos, grottos don't
-- move), else a built-in one (ns.EVENT_SPOTS), else only the zone.
local function EventSpotFor(poiID, name)
  local ES = C_EventScheduler
  local DB = ns.DB
  DB.eventPOIPos = DB.eventPOIPos or {}
  local okZ, zone = pcall(ES.GetEventZoneName, poiID)
  zone = okZ and type(zone) == "string" and zone ~= "" and zone or nil
  local okM, map = pcall(ES.GetEventUiMapID, poiID)
  map = okM and type(map) == "number" and map or nil
  local maps = {}
  for mapID in pairs(WQ.FindMaps()) do maps[#maps + 1] = mapID end
  if map then maps[#maps + 1] = map end
  local info, best
  for _, mapID in ipairs(maps) do
    local ok, i = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
    if ok and i and i.position then
      local mi = C_Map.GetMapInfo(mapID)
      local score = WQ.POIScore(i, mi, i.position.x, i.position.y)
      if zone and mi and WQ.SameZone(mi.name, zone) then score = score + 500 end
      if not best or score > best then best, info, map = score, i, mapID end
    end
  end
  local pos = info and { map = map, x = info.position.x, y = info.position.y, name = info.name }
  if pos then DB.eventPOIPos[poiID] = pos else pos = DB.eventPOIPos[poiID] end
  if not pos then
    local b = ns.EVENT_SPOTS[poiID]
    if b then pos = { map = b[1], x = b[2], y = b[3], name = b[4] } end
  end
  map = (pos and pos.map) or map
  local mi = map and C_Map.GetMapInfo(map)
  if not (map or zone) then return end
  local label = (info and info.name) or (pos and pos.name) or name
  return { poiID = poiID, map = map, mx = pos and pos.x, my = pos and pos.y, name = label,
    label = label, zone = zone or (mi and mi.name) or "?", t = time() }
end

-- An Events-tab activity's marker that's actually on a map (Abundance:
-- Herbalism Grotto). The Events tab can list another one with no marker
-- anywhere ("Abundance: Skinning Den", map nil); the map is where it is.
local function MapMarkerFor(a)
  local best, bestID
  for mapID in pairs(WQ.FindMaps()) do
    local mi = C_Map.GetMapInfo(mapID)
    for _, fn in ipairs({ C_AreaPoiInfo.GetAreaPOIForMap, C_AreaPoiInfo.GetEventsForMap }) do
      local ok, list = false, nil
      if fn then ok, list = pcall(fn, mapID) end
      for _, id in ipairs(ok and type(list) == "table" and list or {}) do
        local okI, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, id)
        if okI and info and info.name and info.position then
          for _, n in ipairs(a.eventTab) do
            if info.name:lower():find(n:lower(), 1, true) then
              local score = WQ.POIScore(info, mi, info.position.x, info.position.y)
              if not best or score > best then best, bestID = score, id end
            end
          end
        end
      end
    end
  end
  return bestID
end

-- Is the event's marker on its map right now? nil = can't tell.
local function MarkerUp(poiID)
  local _, map = EventPOIInfo(poiID)
  if not (map and C_AreaPoiInfo.GetAreaPOIForMap) then return nil end
  local ok, pois = pcall(C_AreaPoiInfo.GetAreaPOIForMap, map)
  if not ok or type(pois) ~= "table" then return nil end
  for _, id in ipairs(pois) do if id == poiID then return true end end
  return false
end

function WQ.ScanScheduler()
  local ES = C_EventScheduler
  if not (ES and ES.GetScheduledEvents and ES.GetOngoingEvents) then return end
  if ES.CanShowEvents then
    local ok, can = pcall(ES.CanShowEvents)
    if ok and can == false then return end
  end
  local okO, ongoing = pcall(ES.GetOngoingEvents)
  local okS, scheduled = pcall(ES.GetScheduledEvents)
  ongoing = okO and type(ongoing) == "table" and ongoing or nil
  scheduled = okS and type(scheduled) == "table" and scheduled or nil
  if not ongoing and not scheduled then
    -- nothing from the server yet (the Events tab asks the same way)
    if ES.RequestEvents then pcall(ES.RequestEvents) end
    return
  end
  local now = time() -- the Events tab compares start/end times with time()
  -- the Events tab only shows an event the game has a marker for
  -- (GetAreaPOIInfo without a map, Blizzard's EventScheduler.lua); the lists
  -- can still hold others, e.g. last week's Abundance grotto
  local function Listed(e)
    local ok, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, nil, e.areaPoiID)
    return ok and info ~= nil
  end
  local out = {}
  for _, a in ipairs(ns.ACTIVITIES) do
    if a.schedule or a.eventTab then out[a.key] = { ongoing = false, t = now } end
  end
  for _, e in ipairs(ongoing or {}) do
    local a = Listed(e) and EventActivity(e.areaPoiID)
    local s = a and out[a.key]
    if s then
      -- several can be listed (last week's grotto too): the one whose
      -- marker is on the map wins
      if not s.poiID or (MarkerUp(e.areaPoiID) and not MarkerUp(s.poiID)) then s.poiID = e.areaPoiID end
      s.matched, s.ongoing = true, true
      if e.rewardsClaimed then s.claimed = true end
    end
  end
  -- Scheduled events: the one running now ("active" in the Events tab is
  -- startTime <= now < endTime) and the next start. Reward claimed on any
  -- of them means you've had this week's reward.
  for _, e in ipairs(scheduled or {}) do
    local a = Listed(e) and EventActivity(e.areaPoiID)
    local s = a and out[a.key]
    if s and e.startTime and e.endTime then
      s.matched = true
      s.anyPoi = s.anyPoi or e.areaPoiID
      if e.rewardsClaimed then s.claimed = true end
      if e.endTime <= now and (not s.lastEnd or e.endTime > s.lastEnd) then s.lastEnd = e.endTime end
      if e.startTime <= now and e.endTime > now then
        local cur = s.poiID
        if not cur or (MarkerUp(e.areaPoiID) and not MarkerUp(cur)) then s.poiID = e.areaPoiID end
        s.window = true
        if s.poiID == e.areaPoiID then s.ends = e.endTime end
      elseif e.startTime > now and (not s.nextStart or e.startTime < s.nextStart) then
        s.nextStart, s.nextEnd, s.nextPoi = e.startTime, e.endTime, e.areaPoiID
        s.hasReminder = e.hasReminder and true or false
      end
    end
  end
  for _, s in pairs(out) do
    -- inside the time slot, but finished early (by other players): its
    -- marker is gone from the map
    if s.window and not s.ongoing then
      local up = s.poiID and MarkerUp(s.poiID)
      s.ongoing = up ~= false
      s.endedEarly = up == false
    end
  end
  WQ.sched = out
  -- where the Events-tab activities are this week (Abundance moves zone
  -- every week); remembered so it's known on other continents too
  ns.DB.eventSpots = ns.DB.eventSpots or {}
  for key, s in pairs(out) do
    local a = ns.ACT_BY_KEY[key]
    -- the running one, else the next to start (the list can still hold
    -- ended ones, e.g. last week's zone)
    local poi = s.poiID or s.nextPoi or s.anyPoi
    -- its marker on the map beats the Events tab's entry
    if a.eventTab and a.eventMarker then poi = MapMarkerFor(a) or poi end
    -- a marker you clicked on the map this week wins (WQ.OnSuperTrack)
    local cur = ns.DB.eventSpots[key]
    if cur and cur.picked and (cur.t or 0) >= ns.NextReset() - 604800 then poi = nil end
    if a.eventTab and poi then
      local spot = EventSpotFor(poi, a.name)
      if spot then
        spot.ends = poi == s.poiID and s.ends or nil -- the running one: valid until it ends
        ns.DB.eventSpots[key] = spot
        ns.DB.zones[key] = spot.zone
      end
    end
  end
  for key, s in pairs(out) do
    local a = ns.ACT_BY_KEY[key]
    if s.claimed and a.eventDone ~= false then ns.MarkEventDone(a, "reward claimed, map Events tab") end
  end
end

-- Clicking an event's marker on the map (Abundance: Herbalism Grotto): that's
-- where it is this week, whatever the Events tab list says.
function WQ.OnSuperTrack()
  if not (C_SuperTrack and C_SuperTrack.GetSuperTrackedMapPin and C_EventScheduler) then return end
  local ok, pinType, poiID = pcall(C_SuperTrack.GetSuperTrackedMapPin)
  if not (ok and pinType == PIN_AREAPOI and poiID) then return end
  local a = EventActivity(poiID)
  if not (a and a.eventTab and a.eventMarker) then return end
  ns.DB.eventSpots = ns.DB.eventSpots or {}
  local cur = ns.DB.eventSpots[a.key]
  if cur and cur.poiID == poiID then return end
  local spot = EventSpotFor(poiID, a.name)
  if not spot then return end
  spot.picked = true
  ns.DB.eventSpots[a.key] = spot
  ns.DB.zones[a.key] = spot.zone
  ns.Print(string.format("%s this week: %s in %s (the marker you clicked).", a.name, spot.name or "?", spot.zone or "?"))
end

-- Where an Events-tab activity is now (Abundance's grotto, Stormarion
-- Assault...), or nil: the running one until it ends, a marker you
-- clicked this week, otherwise a spot seen in the last day.
function WQ.EventSpot(a)
  local spot = ns.DB.eventSpots and ns.DB.eventSpots[a.key]
  if not spot then return end
  if spot.picked then return (spot.t or 0) >= ns.NextReset() - 604800 and spot or nil end
  if spot.ends then return spot.ends > time() and spot or nil end
  if time() - (spot.t or 0) < 86400 then return spot end
end

-- What you're pointing at on the map: a marker you clicked (super-tracked
-- area POI, e.g. Saltheril's Soiree), a tracked quest, or a placed pin.
-- { map, x, y, name, what } or nil.
local function UserWaypoint()
  local w = C_Map.HasUserWaypoint and C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint()
  if w and w.uiMapID and w.position then
    return { map = w.uiMapID, x = w.position.x, y = w.position.y, what = "map pin" }
  end
end

local function AreaPOIPoint(poiID)
  local maps = {}
  if WorldMapFrame and WorldMapFrame.GetMapID then maps[#maps + 1] = WorldMapFrame:GetMapID() end
  if C_Map.GetBestMapForUnit then maps[#maps + 1] = C_Map.GetBestMapForUnit("player") end
  for mapID in pairs(WQ.FindMaps()) do maps[#maps + 1] = mapID end
  local best, out
  for _, mapID in ipairs(maps) do
    local ok, i = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
    if ok and i and i.position then
      local score = WQ.POIScore(i, C_Map.GetMapInfo(mapID), i.position.x, i.position.y)
      if not best or score > best then
        best, out = score, { map = mapID, x = i.position.x, y = i.position.y, name = i.name, poiID = poiID, what = "map marker" }
      end
    end
  end
  return out
end

local function PointedAt()
  local ST = C_SuperTrack
  if ST and ST.IsSuperTrackingUserWaypoint and ST.IsSuperTrackingUserWaypoint() then
    local w = UserWaypoint()
    if w then return w end
  end
  if ST and ST.GetSuperTrackedMapPin then
    local ok, pinType, pinID = pcall(ST.GetSuperTrackedMapPin)
    if ok and pinID then
      if pinType == PIN_AREAPOI then
        local p = AreaPOIPoint(pinID)
        if p then return p end
      end
      local e = ns.DB.wq[-pinID] -- locked Special Assignment
      if e and e.map and e.mx then return { map = e.map, x = e.mx, y = e.my, name = e.title, what = "map marker" } end
    end
  end
  local qid = ST and ST.GetSuperTrackedQuestID and ST.GetSuperTrackedQuestID()
  if qid and qid > 0 and C_QuestLog.GetNextWaypoint then
    local m, x, y = C_QuestLog.GetNextWaypoint(qid)
    if m and x and y then
      return { map = m, x = x, y = y, name = C_QuestLog.GetTitleForQuestID(qid), what = "tracked quest" }
    end
  end
  return UserWaypoint()
end

-- /gc pin [activity]: print what you're pointing at on the map; with an
-- activity, use it as that activity's spot: the spot of its current event
-- (Events-tab activities, e.g. this week's Abundance grotto), otherwise
-- where its weekly is picked up.
function WQ.PinReport(a)
  local p = PointedAt()
  if not p then ns.Warn("Nothing marked. Click a marker on the world map, or Ctrl-click to place a pin.") return end
  local mi = C_Map.GetMapInfo(p.map)
  local zone = mi and mi.name or "?"
  ns.Print(string.format("%s%s: %s (map %d) %.1f, %.1f%s", p.what:sub(1, 1):upper() .. p.what:sub(2),
    p.name and (" \"" .. p.name .. "\"") or "", zone, p.map, p.x * 100, p.y * 100,
    p.poiID and (" (marker " .. p.poiID .. ")") or ""))
  if not a then return end
  if not a.eventTab then
    if not ns.Pickups.SetManual(a, p.map, p.x, p.y, p.name or "map pin") then
      ns.Warn(a.name .. " has no pickup spot (it isn't picked up from a quest giver).")
      return
    end
    ns.Print(string.format("Saved as where %s is picked up.", a.name))
    ns.Refresh()
    return
  end
  local spot = ns.DB.eventSpots and ns.DB.eventSpots[a.key]
  if not (spot and spot.poiID) then
    ns.Warn(a.name .. ": no event from the map's Events tab to attach it to (open the Events tab, then try again).")
    return
  end
  local name = spot.name or a.name
  ns.DB.eventPOIPos = ns.DB.eventPOIPos or {}
  ns.DB.eventPOIPos[spot.poiID] = { map = p.map, x = p.x, y = p.y, name = name }
  spot.map, spot.mx, spot.my = p.map, p.x, p.y
  spot.zone = zone ~= "?" and zone or spot.zone
  ns.DB.zones[a.key] = spot.zone
  ns.Print(string.format("Saved as the spot for %s (event %d).", name, spot.poiID))
  print(string.format("  [%d] = { %d, %.3f, %.3f, \"%s\" },", spot.poiID, p.map, p.x, p.y, name))
  ns.Refresh()
end

-- Fresh Events-tab data for an activity, or nil (then the addon falls back
-- to its own checks). Only when the Events tab actually lists the event: it
-- shows events for the continent you're on.
function WQ.SchedFor(a)
  local s = WQ.sched and WQ.sched[a.key]
  if s and s.matched and time() - s.t < SCHED_FRESH then return s end
end

-- Is the event running? The Events tab decides when it lists the event
-- (only being inside its scenario overrides it); otherwise you being in
-- it, or its marker on the map.
function WQ.EventLive(a, isCurrent)
  if isCurrent and MatchesEvent(a, ScenarioName()) then ns.eventSeenAt[a.key] = GetTime(); return "scenario" end
  local sc = WQ.SchedFor(a)
  if sc then return sc.ongoing and "events tab" or nil end
  if isCurrent then
    for _, t in ipairs(TasksHere()) do
      if MatchesEvent(a, t.title) then ns.eventSeenAt[a.key] = GetTime(); return "objective" end
    end
  end
  local ev = ns.DB.eventPOIs and ns.DB.eventPOIs[a.key]
  if ev and time() - ev.seen < 15 * 60 and (not ev.ends or ev.ends > time()) then return "map" end
end

-- Text of a map marker's tooltip widgets (e.g. the Aqir Researchers' weekly
-- reward), whatever widget types they use.
local function WidgetTexts(setID)
  local out = {}
  local W = C_UIWidgetManager
  if not (setID and W and W.GetAllWidgetsBySetID) then return out end
  local ok, widgets = pcall(W.GetAllWidgetsBySetID, setID)
  local getters = {}
  for name, fn in pairs(W) do
    if type(fn) == "function" and name:match("^Get.+VisualizationInfo$") then getters[#getters + 1] = fn end
  end
  for _, wi in ipairs(ok and widgets or {}) do
    for _, fn in ipairs(getters) do
      local ok2, v = pcall(fn, wi.widgetID)
      if ok2 and type(v) == "table" then
        local parts = {}
        for _, f in ipairs({ "text", "leftText", "rightText", "tooltip", "shownState", "enabledState" }) do
          if v[f] ~= nil and v[f] ~= "" then parts[#parts + 1] = f .. "=" .. tostring(v[f]):gsub("|T.-|t", ""):gsub("\n", " / ") end
        end
        if v.itemInfo and v.itemInfo.itemID then parts[#parts + 1] = "item=" .. v.itemInfo.itemID end
        if #parts > 0 then out[#out + 1] = string.format("widget %d: %s", wi.widgetID, table.concat(parts, "  ")) end
        break
      end
    end
  end
  return out
end
WQ.WidgetTexts = WidgetTexts

-- /gc events: everything the Events tab lists.
local function ReportScheduler()
  local ES = C_EventScheduler
  if not ES then print("  Events tab: not available on this client") return end
  local okO, ongoing = pcall(ES.GetOngoingEvents)
  local okS, scheduled = pcall(ES.GetScheduledEvents)
  local now = time()
  local function line(kind, e)
    local info, map = EventPOIInfo(e.areaPoiID)
    local a = EventActivity(e.areaPoiID)
    local when = ""
    if e.startTime then
      when = e.startTime > now and (" starts in " .. ns.Duration(e.startTime - now))
        or (e.endTime and e.endTime > now and (" running, ends in " .. ns.Duration(e.endTime - now)) or " ended")
    end
    local okL, listed = pcall(C_AreaPoiInfo.GetAreaPOIInfo, nil, e.areaPoiID)
    print(string.format("    %s %d \"%s\" map %s%s%s%s%s", kind, e.areaPoiID or 0, info and info.name or "?", tostring(map),
      when, e.rewardsClaimed and " |cff33ff66reward claimed|r" or "", a and (" |cffffd100= " .. a.name .. "|r") or "",
      (okL and listed) and "" or " |cff888888(not shown in the tab)|r"))
  end
  local any = false
  print("  Events tab lists:")
  for _, e in ipairs(okO and type(ongoing) == "table" and ongoing or {}) do any = true; line("ongoing", e) end
  local n = 0
  for _, e in ipairs(okS and type(scheduled) == "table" and scheduled or {}) do
    n = n + 1
    if n <= 12 then any = true; line("scheduled", e) end
  end
  if not any then print("    nothing (open the map's Events tab once, then try again)") end
end

-- /gc events [activity]: what each source sees right now.
function WQ.ReportEvent(a)
  WQ.ScanEventPOIs(true)
  ns.CheckEventTurnins()
  -- the word its quests and markers are found by ("Aqir", "Abundance")
  local word = (a.eventNames and a.eventNames[1]) or (a.eventTab and a.eventTab[1]) or a.name
  local lword = word:lower()
  ns.Print(a.name .. " event diagnostics:")
  print("  Scenario: " .. tostring(ScenarioName() or "none"))
  local tasks = TasksHere()
  if #tasks == 0 then print("  Area objectives in progress here: none") end
  for _, t in ipairs(tasks) do print(string.format("  Area objective: %d \"%s\"", t.qid, tostring(t.title))) end
  local n = 0
  if C_QuestLog.GetNumQuestLogEntries then
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
      local info = C_QuestLog.GetInfo(i)
      if info and info.title and info.title:lower():find(lword, 1, true) then
        n = n + 1
        print(string.format("  Quest log: %d \"%s\"%s%s%s", info.questID or 0, info.title, info.isTask and " (task)" or "",
          info.isHidden and " (hidden)" or "", (info.campaignID and info.campaignID > 0) and " (campaign - ignored)" or ""))
      end
    end
  end
  if n == 0 then print("  Quest log: nothing with " .. word) end
  local listed = 0
  if C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap then
    for mapID, mapName in pairs(WQ.FindMaps()) do
      local ok, pois = pcall(C_AreaPoiInfo.GetAreaPOIForMap, mapID)
      for _, poiID in ipairs(ok and pois or {}) do
        local ok2, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
        local text = ok2 and info and ((info.name or "") .. " " .. (info.description or "")) or ""
        if text:lower():find(lword, 1, true) then
          listed = listed + 1
          print(string.format("  Marker %d on %s (map %d): \"%s\" %s", poiID, mapName, mapID, info.name or "?", info.description or ""))
          if listed == 1 then
            for _, wt in ipairs(WidgetTexts(info.tooltipWidgetSet)) do print("    " .. wt) end
          end
        end
      end
    end
  end
  if listed == 0 then print("  Markers mentioning " .. word .. ": none on the scanned maps") end
  if a.schedule then
    local ev = ns.DB.eventPOIs and ns.DB.eventPOIs[a.key]
    print("  Event marker: " .. (ev and string.format("%s on %s (%.0f, %.0f)%s", ev.name, ev.zone, ev.mx * 100, ev.my * 100,
      ev.ends and (", ends in " .. ns.Duration(ev.ends - time())) or "") or "none (not running)"))
    local hub = ns.DB.eventHubs and ns.DB.eventHubs[a.key]
    print("  NPCs: " .. (hub and string.format("%s on %s (%.0f, %.0f)", hub.name, hub.zone, hub.mx * 100, hub.my * 100) or "none found"))
  end
  local pk = ns.Pickups and ns.Pickups.For(a)
  if pk then print(string.format("  Learned quest giver: %s on %s (%.0f, %.0f), from %s", pk.label or "?", pk.zone or "?", pk.mx * 100, pk.my * 100, ns.Pickups.SourceText(pk))) end
  pcall(WQ.ScanScheduler)
  local sc = WQ.SchedFor(a)
  if not C_EventScheduler then
    print("  Events tab: not available on this client")
  elseif not sc then
    print("  Events tab: no " .. a.name .. " recognised (it only lists events on the continent you're on)")
  else
    local now = time()
    print(string.format("  Events tab: %s%s%s", sc.ongoing and "RUNNING" or (sc.endedEarly and "finished early" or "not running"),
      sc.claimed and ", reward claimed" or "",
      sc.nextStart and (", next starts in " .. ns.Duration(sc.nextStart - now) .. (sc.hasReminder and " (game reminder set)" or "")) or ""))
  end
  ReportScheduler()
  if a.eventMarker then
    local sp = WQ.EventSpot(a)
    print("  Spot used: " .. (sp and string.format("%s (marker %s) on %s (%.1f, %.1f)%s", sp.name or "?", tostring(sp.poiID),
      sp.zone or "?", (sp.mx or 0) * 100, (sp.my or 0) * 100, sp.picked and ", the marker you clicked" or "") or "none"))
  end
  local c = ns.GetChar()
  local w = c.weekly and c.weekly[a.key]
  print("  This week on this character: " .. ((w and w.done or 0) >= 1 and "DONE" or "not done"))
  local flags = ns.DB.eventFlags and ns.DB.eventFlags[a.key]
  if flags and next(flags) then
    for id in pairs(flags) do
      print(string.format("  Learned weekly flag %d: %s", id, C_QuestLog.IsQuestFlaggedCompleted(id) and "completed" or "not completed"))
    end
  elseif a.mapEvent then
    print("  Weekly flag: not learned yet (learned the next time a character gets the weekly satchel)")
  end
  for qid in pairs(a.doneQuests or {}) do
    print(string.format("  Reward quest %d: %s", qid, C_QuestLog.IsQuestFlaggedCompleted(qid) and "completed" or "not completed"))
  end
  for qid, title in pairs(ns.DB.questIDs[a.key] or {}) do
    local mine = C_QuestLog.IsQuestFlaggedCompleted(qid)
    print(string.format("  Quest %d (%s): %s this week", qid, tostring(title), mine and "completed" or "not completed"))
  end
  if ns.DB.eventBags and ns.DB.eventBags[a.key] then
    for id in pairs(ns.DB.eventBags[a.key]) do print("  Reward bag item: " .. id) end
  end
  if ns.DB.recentTurnins and #ns.DB.recentTurnins > 0 then
    print("  Last quest turn-ins (all characters):")
    for i, r in ipairs(ns.DB.recentTurnins) do
      if i > 10 then break end
      local c = r.char and ns.DB.chars[r.char]
      print(string.format("    %s  %d  %s  |cff888888%s|r", date("%H:%M", r.t), r.qid, tostring(r.title or "?"),
        r.char and ns.ColorName(r.char, c) or "?"))
    end
  end
  if a.schedule then
    local active, nextIn = ns.ScheduleInfo(a, ns.GetChar(), true)
    print("  Result: " .. (active and "ACTIVE (" .. tostring(WQ.EventLive(a, true) or "quest log") .. ")" or ("not active, next start in " .. ns.Duration(nextIn))))
  end
end

-- /gc sa: what the scan sees for Special Assignments.
function WQ.ReportSA()
  ns.Print("Special Assignment diagnostics:")
  local maps, n = WQ.FindMaps(), 0
  local names = {}
  for id, name in pairs(maps) do n = n + 1; if #names < 30 then names[#names + 1] = name .. " (" .. id .. ")" end end
  table.sort(names)
  print("  Scanning " .. n .. " maps: " .. table.concat(names, ", ") .. (n > 30 and ", ..." or ""))
  local found = 0
  for mapID, mapName in pairs(maps) do
    for _, q in ipairs(GetQuests(mapID)) do
      local qid = q.questID or q.questId
      local title = qid and C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(qid)
      if title and title:lower():find("special assignment", 1, true) then
        found = found + 1
        print(string.format("  Found %d \"%s\" on %s (map %d), world quest: %s", qid, title, mapName, mapID, tostring(IsWorldQuest(qid))))
      end
    end
  end
  if found == 0 then print("  No Special Assignment in the world quest list (normal while it's locked).") end
  local pois = 0
  if C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap then
    for mapID, mapName in pairs(maps) do
      local ok, list = pcall(C_AreaPoiInfo.GetAreaPOIForMap, mapID)
      for _, poiID in ipairs(ok and list or {}) do
        local ok2, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
        if ok2 and info and info.name and info.name:lower():find("special assignment", 1, true) then
          pois = pois + 1
          print(string.format("  Map pin %d \"%s\" on %s (map %d): %s", poiID, info.name, mapName, mapID, info.description or ""))
        end
      end
    end
  end
  if pois == 0 then print("  No locked Special Assignment pins found on the scanned maps.") end
  local c = ns.GetChar()
  for _, sa in ipairs(WQ.SpecialAssignments(c)) do
    print(string.format("  Tracked: %s in %s — %d/%d%s%s", sa.title or sa.qid, sa.zone or "?", sa.have, sa.need,
      sa.exact and "" or " (counted by addon)", sa.done and " — done" or ""))
  end
end

function WQ.Count()
  local n, g = 0, 0
  for _, e in pairs(ns.DB.wq) do
    if not e.activity and (e.gold or 0) > 0 then n = n + 1; g = g + e.gold end
  end
  return n, g
end
