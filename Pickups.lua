local ADDON, ns = ...

--[[
  Where to pick up each weekly: the quest giver. (Used only for directions
  when you click a weekly; whether it's done still comes from the quest
  completion check.)

  Sources, best first:
    npc   - you talked to the NPC and it offered (or gave you) the quest:
            its exact spot and name. Never replaced by the others.
    hub   - a quest hub on the map that the game says offers the quest.
    quest - a quest offer ("!") on the map, from the most detailed map
            it shows on (never a continent map).
--]]

local P = {}
ns.Pickups = P

local RANK = { npc = 3, hub = 2, quest = 1 }

-- Activities that get pickup navigation (not orders or Special Assignments).
-- Map events (Aqir) are handled by P.Navigate's event branch.
local function Eligible(a)
  return a and a.kind ~= "crafting" and a.key ~= "special" and not a.mapEvent
end

local function Point(map, mx, my, zone)
  if not (map and mx and my) then return end
  local p = { map = map, mx = mx, my = my, zone = zone }
  if C_Map.GetWorldPosFromMapPos and CreateVector2D then
    local cont, wp = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(mx, my))
    if cont and wp then p.cont, p.x, p.y = cont, wp.x, wp.y end
  end
  if not zone then
    local mi = C_Map.GetMapInfo(map)
    p.zone = mi and mi.name or "?"
  end
  return p
end

-- Keeps the better source; returns true if stored.
local function Store(key, p)
  ns.DB.pickups = ns.DB.pickups or {}
  local cur = ns.DB.pickups[key]
  local a = ns.ACT_BY_KEY[key]
  local stale = cur and a and a.pickupMoves and (cur.t or 0) < ns.NextReset() - 604800
  if cur and not stale and (RANK[cur.source] or 0) > (RANK[p.source] or 0) then return false end
  p.t = time()
  ns.DB.pickups[key] = p
  return true
end

-- How exact a map is: city / micro > zone > other; continents aren't used.
local function MapRank(mapID)
  local mi = C_Map.GetMapInfo(mapID)
  local T = Enum and Enum.UIMapType or {}
  if not mi or mi.mapType == T.Continent or mi.mapType == T.World or mi.mapType == T.Cosmic then return 0 end
  if mi.mapType == T.City or mi.mapType == T.Micro then return 3 end
  if mi.mapType == T.Zone then return 2 end
  return 1
end

-- Called after each world quest scan: quest hubs and quest offers on the map.
function P.Scan()
  local DB = ns.DB
  local best = {} -- [key] = { p = point, score = n }
  local function Offer(a, p, score)
    local cur = best[a.key]
    if not cur or score > cur.score then best[a.key] = { p = p, score = score } end
  end
  for mapID, mapName in pairs(ns.WQ.FindMaps()) do
    local mr = MapRank(mapID)
    if mr > 0 then
      -- quest hubs the game links to one of our weeklies
      if C_AreaPoiInfo.GetQuestHubsForMap and C_QuestHub and C_QuestHub.IsQuestCurrentlyRelatedToHub then
        local ok, hubs = pcall(C_AreaPoiInfo.GetQuestHubsForMap, mapID)
        for _, hub in ipairs(ok and hubs or {}) do
          local okI, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, hub)
          if okI and info and info.position then
            for _, a in ipairs(ns.ACTIVITIES) do
              if Eligible(a) then
                for qid in pairs(DB.questIDs[a.key] or {}) do
                  local okR, rel = pcall(C_QuestHub.IsQuestCurrentlyRelatedToHub, qid, hub)
                  if okR and rel then
                    local p = Point(mapID, info.position.x, info.position.y, mapName)
                    if p then
                      p.source, p.label, p.qid = "hub", info.name, qid
                      Offer(a, p, 100 + mr)
                    end
                    break
                  end
                end
              end
            end
          end
        end
      end
      -- quest offers ("!") on the map
      if C_QuestLine and C_QuestLine.GetAvailableQuestLines then
        if C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, mapID) end
        local ok, lines = pcall(C_QuestLine.GetAvailableQuestLines, mapID)
        for _, ql in ipairs(ok and lines or {}) do
          local a = (ql.questID and ns.ActivityForID(ql.questID)) or ns.MatchTitle(ql.questName)
          if Eligible(a) and not DB.blocked[ql.questID or 0] then
            local p = Point(mapID, ql.x, ql.y, mapName)
            if p then
              p.source, p.label, p.qid = "quest", ql.questName, ql.questID
              Offer(a, p, mr)
              if ql.questID then ns.Learn(a, ql.questID, ql.questName) end
            end
          end
        end
      end
    end
  end
  for key, b in pairs(best) do Store(key, b.p) end
end

-- Talking to an NPC (gossip, quest greeting or quest window): any weekly it
-- offers is picked up right here, from this NPC.
function P.OnNPC()
  if not (UnitExists and UnitExists("npc")) or (UnitIsUnit and UnitIsUnit("npc", "player")) then return end
  local name = UnitName("npc")
  if issecretvalue and issecretvalue(name) then return end
  local WEEKLY = Enum and Enum.QuestFrequency and Enum.QuestFrequency.Weekly
  local offers = {}
  if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
    local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
    for _, q in ipairs(ok and list or {}) do
      offers[#offers + 1] = { id = q.questID, title = q.title, weekly = WEEKLY and q.frequency == WEEKLY }
    end
  end
  if GetNumAvailableQuests and GetAvailableQuestInfo then
    for i = 1, GetNumAvailableQuests() or 0 do
      local _, freq, _, _, id = GetAvailableQuestInfo(i)
      offers[#offers + 1] = { id = id, title = GetAvailableTitle and GetAvailableTitle(i), weekly = WEEKLY and freq == WEEKLY }
    end
  end
  local id = GetQuestID and GetQuestID()
  if id and id > 0 then offers[#offers + 1] = { id = id, title = GetTitleText and GetTitleText() } end
  if #offers == 0 then return end
  local s = ns.Travel and ns.Travel.Sample()
  if not s or s.inst then return end
  for _, o in ipairs(offers) do
    -- a known quest ID, or a matching title on a quest the game calls weekly
    -- (titles alone also match story quests, e.g. "...Haranir")
    local a = (o.id and ns.ActivityForID(o.id)) or (o.weekly and not ns.IsCampaign(o.id) and ns.MatchTitle(o.title)) or nil
    if a and (Eligible(a) or a.mapEvent) and not ns.DB.blocked[o.id or 0] then
      local cur = P.For(a)
      local p = Point(s.map, s.mx, s.my, s.zone)
      if p then
        p.source, p.label, p.qid = "npc", name, o.id
        local moved = not cur or cur.source ~= "npc" or cur.label ~= name or cur.map ~= p.map
        if Store(a.key, p) and moved and ns.DB.settings.announce then
          ns.Print(string.format("%s is picked up from %s (%s).", a.name, name or "?", p.zone or "?"))
        end
      end
    end
  end
end

-- Accepting a weekly from an NPC.
function P.LearnAt() P.OnNPC() end

-- /gc pin <activity>: the spot you marked is where it's picked up (ranked
-- like talking to the NPC, so map scans don't replace it).
function P.SetManual(a, map, mx, my, label)
  if not (Eligible(a) or a.mapEvent) then return false end
  local p = Point(map, mx, my)
  if not p then return false end
  p.source, p.label = "npc", label
  ns.DB.pickups = ns.DB.pickups or {}
  ns.DB.pickups[a.key] = nil -- replace whatever was there
  Store(a.key, p)
  return true
end

-- { map, mx, my, zone, cont, x, y, source, label } or nil
-- A learned spot, else the built-in one from Data.lua (a.pickup).
local builtin = {}
function P.For(a)
  local p = ns.DB.pickups and ns.DB.pickups[a.key]
  -- Abundance's quest giver moves with the zone: only this week's counts
  if p and a.pickupMoves and (p.t or 0) < ns.NextReset() - 604800 then p = nil end
  if p or not a.pickup then return p end
  if not builtin[a.key] then
    local b = Point(a.pickup[1], a.pickup[2], a.pickup[3])
    if b and b.zone ~= "?" then
      b.source, b.label = "builtin", "quest giver"
      builtin[a.key] = b
    end
    return b
  end
  return builtin[a.key]
end

function P.SourceText(p)
  return (p.source == "npc" and "the NPC (you talked to them)") or (p.source == "hub" and "quest hub on the map")
    or (p.source == "builtin" and "built-in location") or "quest offer on the map"
end

-- The map pin the addon placed for a weekly, removed again once you've
-- picked the weekly up or got there (unless you've changed the pin since).
local ARRIVED = 15 -- yards
local placed, arrivalTicker

local function OurPinUp()
  if placed and placed.pinID then
    local ok, _, id = pcall(C_SuperTrack.GetSuperTrackedMapPin)
    return ok and id == placed.pinID or false
  end
  if not (placed and C_Map.HasUserWaypoint and C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint) then return false end
  local w = C_Map.GetUserWaypoint()
  return w and w.uiMapID == placed.map and w.position
    and math.abs(w.position.x - placed.mx) < 0.001 and math.abs(w.position.y - placed.my) < 0.001 or false
end

function P.ClearPin(why)
  if arrivalTicker then arrivalTicker:Cancel(); arrivalTicker = nil end
  if OurPinUp() then
    if placed.pinID then
      if C_SuperTrack.ClearSuperTrackedMapPin then C_SuperTrack.ClearSuperTrackedMapPin() end
    elseif C_Map.ClearUserWaypoint then
      C_Map.ClearUserWaypoint()
    end
    if why and ns.DB.settings.announce then ns.Print("Map pin removed (" .. why .. ").") end
    ns.Refresh()
  end
  placed = nil
end

local Pin

local function CheckArrival()
  if not OurPinUp() then P.ClearPin() return end
  local here = ns.Travel and ns.Travel.Sample()
  if placed.via then
    -- through the portal: on to the real destination
    local d = ns.Travel.Dist(here, placed.via.to)
    if d and d <= 300 then
      local f = placed.final
      placed = nil
      Pin(f.p, f.label, f.key)
    end
    return
  end
  local d = ns.Travel and ns.Travel.Dist(here, placed.point)
  if d and d <= ARRIVED then P.ClearPin("you're there") end
end

-- The portal the addon's route starts with (fly to it, then take it), if
-- any (see ViaPortal).
local function FirstPortal(p)
  if not (ns.Travel and ns.Travel.Plan) then return end
  local plan = ns.Travel.Plan(Point(p.map, p.mx, p.my, p.zone))
  if not (plan and plan.reachable) then return end
  for _, st in ipairs(plan.steps) do
    if st.kind == "portal" then return st.portal end
    if not (st.kind == "fly" and st.to and st.to.kind == "portalIn") then return end
  end
end

-- Tracks something on the map itself, like clicking it there: an event
-- marker (Aqir, an Abundance grotto) or a quest offer ("!"). Quest offers
-- get the game's arrow from another zone too (through portals).
local function TrackMapPin(pinType, id)
  if not (pinType and id and C_SuperTrack and C_SuperTrack.SetSuperTrackedMapPin) then return false end
  local ok = pcall(C_SuperTrack.SetSuperTrackedMapPin, pinType, id)
  if not ok then return false end
  local okG, t, got = pcall(C_SuperTrack.GetSuperTrackedMapPin)
  return okG and t == pinType and got == id
end

-- The weekly's quest to track as an offer: the one the quest giver offered
-- (other known IDs may not be offered this week).
local function OfferQuest(p)
  local done = C_QuestLog.IsQuestFlaggedCompleted
  if p.qid and not (done and done(p.qid)) then return p.qid end
end

-- A pin on the map you're actually on: a zone can have several versions
-- (Eversong Woods 2395 / 2567) and a pin on the one you're not shown
-- doesn't appear. The spot is moved to your map (through world
-- coordinates) when it's on it; else its own map. Returns map, x, y.
local function PlacePin(p)
  if not (C_Map.SetUserWaypoint and UiMapPoint) then return end
  local maps = {}
  if C_Map.GetBestMapForUnit then maps[#maps + 1] = C_Map.GetBestMapForUnit("player") end
  if WorldMapFrame and WorldMapFrame:IsShown() then maps[#maps + 1] = WorldMapFrame:GetMapID() end
  maps[#maps + 1] = p.map
  local w = Point(p.map, p.mx, p.my)
  for _, m in ipairs(maps) do
    local x, y
    if m == p.map then
      x, y = p.mx, p.my
    elseif w and w.cont and C_Map.GetMapPosFromWorldPos and CreateVector2D then
      local _, pos = C_Map.GetMapPosFromWorldPos(w.cont, CreateVector2D(w.x, w.y), m)
      if pos then x, y = pos.x, pos.y end
    end
    if x and x > 0 and x < 1 and y > 0 and y < 1
      and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(m)) then
      C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, x, y))
      local got = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
      if got and got.uiMapID == m then
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
        return m, x, y
      end
    end
  end
end

-- The game's own marker for a portal ("Portal to Harandar") on the map
-- you're on, at most 60 yards from where it's known to be: tracking it
-- puts the marker on the portal, not floating above the spot.
local function PortalPOI(from)
  if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap and C_Map.GetBestMapForUnit) then return end
  local map = C_Map.GetBestMapForUnit("player")
  local ok, pois = pcall(C_AreaPoiInfo.GetAreaPOIForMap, map or 0)
  for _, id in ipairs(ok and type(pois) == "table" and pois or {}) do
    local okI, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, map, id)
    if okI and info and info.position then
      -- atlas names aren't translated, the names are
      local name = (info.atlasName or "") .. " " .. (info.name or "")
      if name:lower():find("portal", 1, true) then
        local d = ns.Travel.Dist(Point(map, info.position.x, info.position.y), from)
        if d and d <= 60 then return id end
      end
    end
  end
end

-- In the zone of p (any version of its map).
local function InZone(p)
  local s = ns.Travel and ns.Travel.Sample()
  return s and (s.map == p.map or (s.zone and s.zone == p.zone)) or false
end

-- Only when the spot itself can't be tracked (a plain map pin gets no
-- arrow from another zone): mark the first portal of the addon's route,
-- then the spot once you're through. Returns true if it did.
local function ViaPortal(p, label, key)
  local pt = FirstPortal(p)
  if not pt then return false end
  local poi = PortalPOI(pt.from)
  local map, mx, my
  if poi and TrackMapPin(ns.WQ.PIN_AREAPOI, poi) then
    map, mx, my = pt.from.map, pt.from.mx, pt.from.my
  else
    poi = nil
    map, mx, my = PlacePin({ map = pt.from.map, mx = pt.from.mx, my = pt.from.my })
  end
  if not map then return false end
  print(string.format("  |cff888888%s on the portal in %s » %s first|r", poi and "tracking the marker" or "map pin",
    pt.from.zone or "?", pt.to.zone or "?"))
  if arrivalTicker then arrivalTicker:Cancel() end
  placed = { map = map, mx = mx, my = my, key = key, pinID = poi, via = pt, final = { p = p, label = label, key = key } }
  arrivalTicker = C_Timer.NewTicker(1, CheckArrival)
  if ns.Travel then
    ns.Travel.SetGoalLabel(label, { map = p.map, mx = p.mx, my = p.my, pinID = poi, via = { map = map, mx = mx, my = my } })
  end
  return true
end

function Pin(p, label, key)
  local map, mx, my = p.map, p.mx, p.my
  local T = Enum and Enum.SuperTrackingMapPinType or {}
  local pinID
  if p.poiID and TrackMapPin(ns.WQ.PIN_AREAPOI, p.poiID) then
    pinID = p.poiID
    print("  |cff888888tracking the map marker|r")
  else
    -- when the giver moves (Abundance) only in its zone: every zone's giver
    -- offers the same quest and the game's arrow goes to the nearest one
    local a = ns.ACT_BY_KEY[key or ""]
    local qid = not p.poiID and not (a and a.pickupMoves and not InZone(p)) and T.QuestOffer and OfferQuest(p)
    if qid and TrackMapPin(T.QuestOffer, qid) then
      pinID = qid
      print(string.format("  |cff888888tracking the quest offer (quest %d)|r", qid))
    end
  end
  if not pinID then
    if not InZone(p) and ViaPortal(p, label, key) then return end
    map, mx, my = PlacePin(p)
    if not map then
      ns.Warn(string.format("Couldn't put a map pin on %s (%.1f, %.1f).", p.zone or "?", (p.mx or 0) * 100, (p.my or 0) * 100))
      map, mx, my = p.map, p.mx, p.my
    else
      local mi = C_Map.GetMapInfo(map)
      print(string.format("  |cff888888map pin on %s (map %d) %.1f, %.1f|r", mi and mi.name or "?", map, mx * 100, my * 100))
    end
  end
  if arrivalTicker then arrivalTicker:Cancel() end
  placed = { map = map, mx = mx, my = my, key = key, pinID = pinID, point = Point(map, mx, my) }
  arrivalTicker = C_Timer.NewTicker(1, CheckArrival)
  if ns.Travel then ns.Travel.SetGoalLabel(label, { map = map, mx = mx, my = my, pinID = pinID }) end
end

-- Accepting the weekly the pin was for.
function P.OnAccepted(a)
  if placed and a and placed.key == a.key then P.ClearPin("picked up " .. a.name) end
end

-- Click on a weekly: track it, or guide to the quest giver.
function P.Navigate(a)
  local c = ns.GetChar()
  local qid = c.inLogQid and c.inLogQid[a.key]
  if qid and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
    if C_QuestLog.AddQuestWatch then pcall(C_QuestLog.AddQuestWatch, qid) end
    C_SuperTrack.SetSuperTrackedQuestID(qid)
    ns.Print("Tracking " .. a.name .. " (it's in your quest log).")
    return
  end
  if a.schedule or a.mapEvent then
    -- the event's marker on the map ("Aqir Invasion of Zul'Aman"), even
    -- between runs; only without one, the NPCs (Aqir Researchers)
    if ns.WQ.ScanEventPOIs then pcall(ns.WQ.ScanEventPOIs, true) end
    local live = ns.WQ.EventLive(a, true)
    if live == "scenario" or live == "objective" then
      ns.Print("You're in the " .. a.name .. " event now.")
      return
    end
    local ev = ns.DB.eventPOIs and ns.DB.eventPOIs[a.key]
    local hub = P.For(a) or (ns.DB.eventHubs and ns.DB.eventHubs[a.key])
    local target = (ev and ev.mx and ev) or (hub and hub.mx and hub)
    if not target then
      ns.Warn(a.name .. ": no marker for it on the map right now.")
      return
    end
    local label = target == ev and (ev.name or a.name) or (target.label or target.name or a.name)
    Pin(target, label, a.key)
    ns.Print(string.format("Directions to %s in %s.", label, target.zone or "?"))
    return
  end
  local p = P.For(a)
  -- this week's spot from the map's Events tab (Abundance moves zone): its
  -- marker is tracked, like clicking it on the map. Not the quest giver you
  -- talked to: every zone's giver offers the same quest.
  local spot = a.eventMarker and ns.WQ.EventSpot(a)
  if spot and not spot.mx then
    ns.Warn(string.format("%s is in %s this week; its spot isn't on the map yet.", a.name, spot.zone or "?"))
    return
  end
  if spot then
    Pin(spot, spot.name or a.name, a.key)
    ns.Print(string.format("Directions to %s in %s.", spot.name or a.name, spot.zone or "?"))
    return
  end
  if not p and a.pickupMoves then
    ns.Warn(a.name .. ": this week's spot isn't known yet. Open the map's Events tab while on the Midnight continent (/gc events abundance shows what it lists).")
    return
  end
  if not p then
    ns.Warn(a.name .. ": quest giver not known yet. It's found when the quest shows on the world map, or when you talk to the NPC once.")
    return
  end
  Pin(p, a.name .. " (pick up)", a.key)
  ns.Print(string.format("Directions to pick up %s from %s (%s %.0f, %.0f).", a.name, p.label or "?", p.zone or "?", p.mx * 100, p.my * 100))
end
