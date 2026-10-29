local ADDON, ns = ...

--[[
  Navigation: learns how you travel, then finds the fastest way to the
  quest you're tracking.

  Learning (no hardcoded portal coordinates needed):
    * Hearthstone (and hearthstone toys): where it lands, per character.
    * Teleport spells you know (class/racial/housing): where they land.
    * Teleport items you used from your bags or toy box.
    * Portals: any loading screen or instant jump that wasn't one of the
      above is stored as a one-way link from where you were to where you
      arrived. Portal links are shared by all characters.

  Planning: a shortest-time search over your position, teleport
  destinations, portal entrances/exits and the goal. Flying between any
  two points on the same continent costs takeoff + distance / speed.
--]]

local Travel = {}
ns.Travel = Travel

-- Hearthstone + common hearthstone toys (all go to your bind location).
local HEARTH_ITEMS = {
  6948, 54452, 64488, 93672, 142542, 162973, 163045, 165669, 165670, 165802,
  166746, 166747, 168907, 172179, 180290, 182773, 183716, 184353, 188952,
  190196, 190237, 193588, 200630, 206195, 208704, 209035, 212337, 228940,
}
local HEARTH_SPELL = 8690

local function S() return ns.DB.settings.travel end
local function D() return ns.DB.travel end

-- A spell this character knows (class / racial / housing teleports).
-- IsPlayerSpell is gone in 12.x; C_SpellBook.IsSpellKnown replaces it.
local function KnowsSpell(id)
  if not id then return false end
  if C_SpellBook and C_SpellBook.IsSpellKnown then
    local ok, v = pcall(C_SpellBook.IsSpellKnown, id)
    return ok and v and true or false
  end
  return IsPlayerSpell and IsPlayerSpell(id) or false
end

------------------------------------------------------------------------
-- Positions
------------------------------------------------------------------------
-- Full sample: world position plus the map point (for waypoints/labels).
function Travel.Sample()
  if not (C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return end
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local cont, wp = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if not (cont and wp) then return end
  local info = C_Map.GetMapInfo(mapID)
  return {
    cont = cont, x = wp.x, y = wp.y, map = mapID, mx = pos.x, my = pos.y,
    zone = (info and info.name) or (GetZoneText and GetZoneText()) or "?",
    t = GetTime(),
    taxi = UnitOnTaxi and UnitOnTaxi("player") or false,
    dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") or false,
    inst = IsInInstance and select(1, IsInInstance()) or false,
  }
end

local function Dist(a, b)
  if not (a and b) or a.cont ~= b.cont then return end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end
Travel.Dist = Dist

local function Point(s)
  return { cont = s.cont, x = s.x, y = s.y, map = s.map, mx = s.mx, my = s.my, zone = s.zone }
end

------------------------------------------------------------------------
-- Teleport options and their availability
------------------------------------------------------------------------
local hearthSpells = { [HEARTH_SPELL] = true }
local function BuildHearthSpells()
  if not (C_Item and C_Item.GetItemSpell) then return end
  local all = {}
  for _, id in ipairs(HEARTH_ITEMS) do all[#all + 1] = id end
  for _, id in ipairs(D().hearthItems or {}) do all[#all + 1] = id end
  for _, id in ipairs(all) do
    local _, sid = C_Item.GetItemSpell(id)
    if sid then hearthSpells[sid] = true
    elseif C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  end
end

local function ItemCooldown(id)
  if not (C_Container and C_Container.GetItemCooldown) then return 0 end
  local start, dur = C_Container.GetItemCooldown(id)
  if start and start > 0 and dur and dur > 1.5 then return math.max(0, start + dur - GetTime()) end
  return 0
end

local function SpellCooldown(id)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return 0 end
  local cd = C_Spell.GetSpellCooldown(id)
  if cd and cd.startTime and cd.startTime > 0 and cd.duration and cd.duration > 1.5 then
    return math.max(0, cd.startTime + cd.duration - GetTime())
  end
  return 0
end

local function SpellCast(id, default)
  local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
  if info and info.castTime then return info.castTime / 1000 end
  return default or 10
end

local function ItemName(id)
  return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
end

local function OwnsItem(id)
  if PlayerHasToy and PlayerHasToy(id) then
    return not C_ToyBox or not C_ToyBox.IsToyUsable or C_ToyBox.IsToyUsable(id)
  end
  return (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or 0) > 0
end

-- The hearthstone (or toy) this character can use right now, if any.
local function UsableHearth()
  local cooldown
  local function try(list)
    for _, id in ipairs(list or {}) do
      if OwnsItem(id) then
        local cd = ItemCooldown(id)
        if cd == 0 then return id end
        cooldown = cooldown and math.min(cooldown, cd) or cd
      end
    end
  end
  local id = try(HEARTH_ITEMS) or try(D().hearthItems)
  if id then return id, 0 end
  return nil, cooldown
end

------------------------------------------------------------------------
-- Built-in travel (12.1.5, measured in game): the Midnight portal hubs and
-- teleport toys, so routes work before you've taken them yourself. Once
-- you take / use one, the learned spot wins. Positions are map points;
-- world positions are worked out when needed (any client language).
------------------------------------------------------------------------
local BUILTIN_PORTALS = {
  { 2393, 0.3696, 0.6800, 2576, 0.6289, 0.7045 }, -- Silvermoon City -> Harandar (The Den)
  { 2393, 0.3527, 0.6591, 2405, 0.5164, 0.7020 }, -- Silvermoon City -> Voidstorm
  { 2576, 0.6471, 0.7100, 2393, 0.3657, 0.6880 }, -- Harandar (The Den) -> Silvermoon City
  { 2576, 0.6190, 0.7330, 2405, 0.5164, 0.7020 }, -- Harandar (The Den) -> Voidstorm
  { 2405, 0.5156, 0.7029, 2393, 0.3530, 0.6523 }, -- Voidstorm -> Silvermoon City
  { 2405, 0.5170, 0.7040, 2576, 0.6289, 0.7045 }, -- Voidstorm -> Harandar (same portal room; approximate until taken)
  { 84, 0.5332, 0.5432, 2537, 0.2702, 0.3913, faction = "Alliance" }, -- Stormwind -> Quel'Thalas
}
-- Teleport toys with a fixed destination.
local BUILTIN_TOYS = {
  { itemID = 253629, name = "Personal Key to the Arcantina", to = { 2541, 0.5050, 0.8070 } },
}

local function MapPoint(map, mx, my)
  if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local cont, wp = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(mx, my))
  if not (cont and wp) then return end
  local mi = C_Map.GetMapInfo(map)
  return { cont = cont, x = wp.x, y = wp.y, map = map, mx = mx, my = my, zone = mi and mi.name or "?" }
end

local builtinPortals
function Travel.BuiltinPortals()
  if builtinPortals then return builtinPortals end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local out = {}
  for _, b in ipairs(BUILTIN_PORTALS) do
    if not b.faction or b.faction == faction then
      local from, to = MapPoint(b[1], b[2], b[3]), MapPoint(b[4], b[5], b[6])
      if from and to then out[#out + 1] = { from = from, to = to, load = true, builtin = true } end
    end
  end
  builtinPortals = out
  return out
end

-- { itemID, dest } for each built-in toy
local builtinToys
function Travel.BuiltinToys()
  if builtinToys then return builtinToys end
  local out = {}
  for _, b in ipairs(BUILTIN_TOYS) do
    local dest = MapPoint(b.to[1], b.to[2], b.to[3])
    if dest then out[#out + 1] = { itemID = b.itemID, name = b.name, dest = dest } end
  end
  if #out == #BUILTIN_TOYS then builtinToys = out end -- (map data can be missing very early)
  return out
end

-- Every teleport this character could use, available or not.
function Travel.Teleports()
  local out = {}
  local c = ns.GetChar()
  local bind = GetBindLocation and GetBindLocation()
  if c.hearth then
    local id, cd = UsableHearth()
    local stale = c.hearth.stale or (bind and c.hearth.bind and bind ~= c.hearth.bind) or false
    out[#out + 1] = {
      key = "hearth", kind = "item", name = "Hearthstone", itemID = id or 6948,
      dest = c.hearth, cast = 10, cooldown = cd or 0, ready = id ~= nil and not stale,
      note = stale and "bind location changed — use it once to relearn" or (not id and cd and ("ready in " .. ns.Duration(cd))) or nil,
      label = "Hearthstone » " .. (c.hearth.zone or "?"),
    }
  end
  for key, t in pairs(D().tele) do
    if t.kind == "spell" and KnowsSpell(t.id) then
      local cd = SpellCooldown(t.id)
      local name = (C_Spell.GetSpellName and C_Spell.GetSpellName(t.id)) or t.name or ("spell " .. t.id)
      out[#out + 1] = { key = key, kind = "spell", spellID = t.id, name = name, dest = t,
        cast = SpellCast(t.id, 10), cooldown = cd, ready = cd == 0,
        note = cd > 0 and ("ready in " .. ns.Duration(cd)) or nil, label = name .. " » " .. (t.zone or "?") }
    elseif t.kind == "item" and OwnsItem(t.id) then
      local cd = ItemCooldown(t.id)
      local name = ItemName(t.id)
      local sid = C_Item and C_Item.GetItemSpell and select(2, C_Item.GetItemSpell(t.id))
      out[#out + 1] = { key = key, kind = "item", itemID = t.id, name = name, dest = t,
        cast = sid and SpellCast(sid, 10) or 10, cooldown = cd, ready = cd == 0,
        note = cd > 0 and ("ready in " .. ns.Duration(cd)) or nil, label = name .. " » " .. (t.zone or "?") }
    end
  end
  -- built-in toys you own but haven't used yet
  for _, b in ipairs(Travel.BuiltinToys()) do
    local id = b.itemID
    if id and not D().tele["item:" .. id] and OwnsItem(id) then
      local cd = ItemCooldown(id)
      local sid = C_Item and C_Item.GetItemSpell and select(2, C_Item.GetItemSpell(id))
      local name = ItemName(id)
      out[#out + 1] = { key = "item:" .. id, kind = "item", itemID = id, name = name, dest = b.dest,
        cast = sid and SpellCast(sid, 10) or 10, cooldown = cd, ready = cd == 0,
        note = cd > 0 and ("ready in " .. ns.Duration(cd)) or nil, label = name .. " » " .. (b.dest.zone or "?") }
    end
  end
  return out
end

------------------------------------------------------------------------
-- Learning
------------------------------------------------------------------------
local lastItem
local prev, preLoad, loading = nil, nil, false

-- Recent spell casts by the player, newest first: { spellID, t (finished),
-- dur (seconds from start) }. Kept as a short history because a toy can
-- fire a second instant spell right after its teleport, and channeled
-- toys report "succeeded" when the channel *starts* - the teleport only
-- happens when it ends.
local casts, castStart, chanStart = {}, {}, {}
local TELEPORT_CAST = 3.5 -- seconds; mounts (1.5s) and instant portals stay below this

local function PushCast(sid, channel)
  local now = GetTime()
  local starts = channel and chanStart or castStart
  local dur = starts[sid] and (now - starts[sid]) or 0
  starts[sid] = nil
  table.insert(casts, 1, { spellID = sid, t = now, dur = dur, channel = channel })
  while #casts > 12 do table.remove(casts) end
end

local function SameSpot(a, b, r)
  local d = Dist(a, b)
  return d and d <= r
end

local function Announce(msg)
  if ns.DB.settings.announce then ns.Print(msg) end
end

-- The same portal can be entered from a few yards apart and lands you in
-- a slightly different spot each time (you're often still moving when the
-- position is sampled), so match loosely: different portals in one room
-- are told apart by where they go.
local function LearnPortal(from, to, loaded)
  for _, p in ipairs(D().portals) do
    if SameSpot(p.from, from, 120) and SameSpot(p.to, to, 300) then
      p.uses = (p.uses or 1) + 1
      p.t = time()
      p.load = loaded or p.load
      return
    end
  end
  table.insert(D().portals, { from = Point(from), to = Point(to), uses = 1, t = time(), load = loaded })
  Announce(string.format("Learned travel link: %s » %s.", from.zone or "?", to.zone or "?"))
end

-- Did we just land at the hearthstone bind location?
local function AtBind()
  local bind = GetBindLocation and GetBindLocation()
  if not bind or bind == "" then return false end
  return bind == (GetSubZoneText and GetSubZoneText() or "") or bind == (GetMinimapZoneText and GetMinimapZoneText() or "")
    or bind == (GetZoneText and GetZoneText() or "")
end

-- Which bag item, toy or equipped item casts this spell (toys used from
-- action bars don't go through UseToy, so this is how they're found).
local spellItem = {}
local function ItemForSpell(sid)
  if spellItem[sid] then return spellItem[sid] end
  if not (C_Item and C_Item.GetItemSpell) then return end
  local function check(id)
    if not id or id <= 0 then return false end
    local _, s = C_Item.GetItemSpell(id)
    if s then spellItem[s] = spellItem[s] or id end
    return s == sid
  end
  for _, id in ipairs(HEARTH_ITEMS) do if check(id) then return id end end
  if C_Container and C_Container.GetContainerNumSlots then
    for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5) do
      for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
        local id = C_Container.GetContainerItemID(bag, slot)
        if check(id) then return id end
      end
    end
  end
  for slot = 1, 19 do
    local id = GetInventoryItemID and GetInventoryItemID("player", slot)
    if check(id) then return id end
  end
  if C_ToyBox and C_ToyBox.GetNumFilteredToys and C_ToyBox.GetToyFromIndex then
    for i = 1, C_ToyBox.GetNumFilteredToys() or 0 do
      if check(C_ToyBox.GetToyFromIndex(i)) then return C_ToyBox.GetToyFromIndex(i) end
    end
  end
end

local function StoreTele(key, t, label)
  local old = D().tele[key]
  D().tele[key] = t
  if not old or not SameSpot(old, t, 200) then
    Announce(string.format("Learned teleport: %s » %s.", label, t.zone or "?"))
  end
end

-- The teleport cast that finished right before a jump, if any:
-- { spellID, t, casted } where casted = it had a real cast/channel time
-- (hearthstones, toys, teleport spells), unlike portals and mounts.
local function CastBefore(from)
  local best, bestScore
  for _, cst in ipairs(casts) do
    if cst.t >= from.t - 1.5 and cst.t <= from.t + 4 then
      local casted = cst.dur >= TELEPORT_CAST or SpellCast(cst.spellID, 0) >= TELEPORT_CAST
      local score = (hearthSpells[cst.spellID] and 4) or (casted and KnowsSpell(cst.spellID) and 3)
        or (casted and 2) or 1
      if not best or score > bestScore then
        best, bestScore = { spellID = cst.spellID, t = cst.t, casted = casted }, score
      end
    end
  end
  return best
end

-- Removes portal links that were really a hearthstone or teleport toy:
-- they end where a teleport lands. Runs once on login and again whenever
-- a hearthstone or teleport destination is learned.
local function CleanPortals()
  local dests = {}
  for _, ch in pairs(ns.DB.chars) do if ch.hearth then dests[#dests + 1] = ch.hearth end end
  for _, t in pairs(D().tele) do dests[#dests + 1] = t end
  for _, b in ipairs(Travel.BuiltinToys()) do dests[#dests + 1] = b.dest end
  local removed = 0
  for i = #D().portals, 1, -1 do
    local p = D().portals[i]
    for _, d in ipairs(dests) do
      if (p.uses or 1) <= 3 and SameSpot(p.to, d, 150) then
        table.remove(D().portals, i)
        removed = removed + 1
        break
      end
    end
  end
  if removed > 0 then ns.Print(string.format("Removed %d travel links that were really a hearthstone or teleport.", removed)) end
end

-- Lands where a known hearthstone / teleport goes (a cast we missed)?
local function AtKnownTeleport(to)
  local c = ns.GetChar()
  if c.hearth and not c.hearth.stale and SameSpot(c.hearth, to, 100) then return true end
  for _, t in pairs(D().tele) do
    if SameSpot(t, to, 100) then return true end
  end
  return false
end

local function OnJump(from, to, loaded)
  if from.inst or to.inst or from.dead or from.taxi or to.taxi then return end
  local c = ns.GetChar()
  local lc = CastBefore(from)
  local sid = lc and lc.spellID
  local casted = lc and lc.casted
  local playerSpell = sid and KnowsSpell(sid)
  if sid and (hearthSpells[sid] or (casted and not playerSpell and AtBind())) then
    local new = not c.hearth or c.hearth.stale or not SameSpot(c.hearth, to, 200)
    c.hearth = Point(to)
    c.hearth.bind = GetBindLocation and GetBindLocation() or nil
    hearthSpells[sid] = true
    -- a hearthstone toy the built-in list doesn't know: remember it
    local itemID = ItemForSpell(sid)
    if itemID and not tContains(HEARTH_ITEMS, itemID) then
      D().hearthItems = D().hearthItems or {}
      if not tContains(D().hearthItems, itemID) then table.insert(D().hearthItems, itemID) end
    end
    if new then Announce("Learned Hearthstone destination: " .. (to.zone or "?") .. ".") end
    CleanPortals()
  elseif sid and casted and playerSpell then
    local t = Point(to)
    t.kind, t.id = "spell", sid
    t.name = C_Spell.GetSpellName and C_Spell.GetSpellName(sid) or nil
    StoreTele("spell:" .. sid, t, t.name or tostring(sid))
    CleanPortals()
  elseif sid and (casted or (lastItem and lastItem.t >= lc.t - 20 and lastItem.t <= lc.t + 1)) then
    local itemID = (lastItem and lastItem.t >= lc.t - 20 and lastItem.t <= lc.t + 1 and lastItem.id) or ItemForSpell(sid)
    if itemID then
      local t = Point(to)
      t.kind, t.id = "item", itemID
      StoreTele("item:" .. itemID, t, ItemName(itemID))
      CleanPortals()
    end
    -- a teleport we can't cast from the planner: still never a portal link
  elseif not AtKnownTeleport(to) then
    LearnPortal(from, to, loaded)
  end
  wipe(casts)
  lastItem = nil
  ns.Refresh()
end

function Travel.DeletePortal(i)
  local p = i and D().portals[i]
  if not p then ns.Print("No portal link with that number (see /gc travel).") return end
  table.remove(D().portals, i)
  ns.Print(string.format("Removed travel link %s » %s.", p.from.zone or "?", p.to.zone or "?"))
  ns.Refresh()
end

-- Called every second from a ticker.
function Travel.Tick()
  if loading then return end
  if not S().enabled then prev = nil; return end
  -- standing still: keep the last sample instead of making a new one
  local uy, ux, uinst = ns.PlayerYX()
  if prev and uy and prev.uy == uy and prev.ux == ux and prev.uinst == uinst then
    prev.t = GetTime()
    prev.taxi = UnitOnTaxi and UnitOnTaxi("player") or false
    prev.dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") or false
    return
  end
  local cur = Travel.Sample()
  if not cur then prev = nil; return end
  cur.uy, cur.ux, cur.uinst = uy, ux, uinst
  if prev and cur.t - prev.t <= 2.5 then
    local d = Dist(prev, cur)
    if (not d or d > 600) and not cur.taxi and not prev.taxi then OnJump(prev, cur, false) end
  end
  prev = cur
end

function Travel.OnLoadingStart()
  loading = true
  preLoad = prev
end

function Travel.OnLoadingEnd()
  loading = false
  if not S().enabled then preLoad = nil; return end
  C_Timer.After(1.5, function()
    local cur = Travel.Sample()
    if preLoad and cur then
      local d = Dist(preLoad, cur)
      if not d or d > 600 then OnJump(preLoad, cur, true) end
    end
    preLoad = nil
    prev = cur
  end)
end

function Travel.OnCastStart(unit, _, spellID)
  if unit == "player" and spellID then castStart[spellID] = GetTime() end
end

function Travel.OnChannelStart(unit, _, spellID)
  if unit == "player" and spellID then chanStart[spellID] = GetTime() end
end

function Travel.OnSpellCast(unit, _, spellID)
  if unit == "player" and spellID then PushCast(spellID, false) end
end

-- channeled teleports move you when the channel ends
function Travel.OnChannelStop(unit, _, spellID)
  if unit == "player" and spellID then PushCast(spellID, true) end
end

function Travel.OnItemUsed(itemID)
  if itemID then lastItem = { id = itemID, t = GetTime() } end
end

-- Binding your hearthstone at an innkeeper: you're standing about where it
-- will land, so that's its destination from now on (no need to use it
-- once first). Elsewhere (e.g. in an instance) it's relearned on first use.
function Travel.OnBindChanged()
  C_Timer.After(0.5, function() -- the new bind location is readable a moment later
    local c = ns.GetChar()
    local s = Travel.Sample()
    if s and not s.inst then
      local bind = GetBindLocation and GetBindLocation() or nil
      c.hearth = Point(s)
      c.hearth.bind = bind
      Announce(string.format("Hearthstone set to %s%s.", bind or s.zone or "?",
        (bind and s.zone and bind ~= s.zone) and (" (" .. s.zone .. ")") or ""))
    elseif c.hearth then
      c.hearth.bind, c.hearth.stale = nil, true
    end
    ns.Refresh()
  end)
end

------------------------------------------------------------------------
-- Goal: the tracked world quest / quest, or your map pin
------------------------------------------------------------------------
local function MapPointToWorld(map, x, y, zoneName)
  if not (map and x and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local cont, wp = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(x, y))
  if not (cont and wp) then return end
  local info = C_Map.GetMapInfo(map)
  return { cont = cont, x = wp.x, y = wp.y, map = map, mx = x, my = y, zone = zoneName or (info and info.name) or "?" }
end

-- Label for a map pin the addon placed (e.g. "Pick up: Harandar").
local goalLabel
function Travel.SetGoalLabel(label, p)
  goalLabel = { label = label, map = p.map, mx = p.mx, my = p.my, pinID = p.pinID, via = p.via }
end

function Travel.Goal()
  -- a tracked map marker (locked Special Assignment)
  if C_SuperTrack and C_SuperTrack.GetSuperTrackedMapPin then
    local ok, pinType, pinID = pcall(C_SuperTrack.GetSuperTrackedMapPin)
    if ok and pinID then
      local e = ns.DB.wq[-pinID]
      if e and e.map and e.mx then
        local g = MapPointToWorld(e.map, e.mx, e.my, e.zone)
        if g then g.label = e.title or "Special Assignment"; g.zone = e.zone or g.zone; return g end
      end
      -- an event marker or quest offer the addon tracked (Aqir, Runestones)
      local L = goalLabel
      if L and L.pinID == pinID then
        local g = MapPointToWorld(L.map, L.mx, L.my)
        if g then g.label = L.label; return g end
      end
    end
  end
  local qid = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
  if qid and qid > 0 then
    local e = ns.DB.wq[qid]
    if e and e.map and C_TaskQuest.GetQuestLocation then
      local x, y = C_TaskQuest.GetQuestLocation(qid, e.map)
      local g = MapPointToWorld(e.map, x, y, e.zone)
      if g then g.label = e.title or ("World Quest " .. qid); g.qid = qid; return g end
    end
    -- regular quests: look for the quest's POI on its map
    local map = GetQuestUiMapID and GetQuestUiMapID(qid)
    if map and map > 0 and C_QuestLog.GetQuestsOnMap then
      for _, q in ipairs(C_QuestLog.GetQuestsOnMap(map) or {}) do
        if q.questID == qid then
          local g = MapPointToWorld(map, q.x, q.y)
          if g then g.label = C_QuestLog.GetTitleForQuestID(qid) or ("Quest " .. qid); g.qid = qid; return g end
        end
      end
    end
  end
  if C_Map.HasUserWaypoint and C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint then
    local p = C_Map.GetUserWaypoint()
    if p and p.uiMapID and p.position then
      -- the pin on a portal on the way (Pickups): directions still go to
      -- where it leads
      local L, V = goalLabel, goalLabel and goalLabel.via
      if V and V.map == p.uiMapID and math.abs(V.mx - p.position.x) < 0.002 and math.abs(V.my - p.position.y) < 0.002 then
        local g = MapPointToWorld(L.map, L.mx, L.my)
        if g then g.label = L.label; return g end
      end
      local g = MapPointToWorld(p.uiMapID, p.position.x, p.position.y)
      if g then
        g.label = "Map pin"
        local L = goalLabel
        if L and L.map == p.uiMapID and math.abs(L.mx - p.position.x) < 0.002 and math.abs(L.my - p.position.y) < 0.002 then
          g.label = L.label
        end
        return g
      end
    end
  end
end

-- The game's own navigation step for a tracked quest in another zone
-- (what the on-screen marker points at, e.g. a portal), if any.
function Travel.GameHint(goal)
  if not (goal and goal.qid and C_QuestLog.GetNextWaypoint) then return end
  local m, x, y = C_QuestLog.GetNextWaypoint(goal.qid)
  if not (m and x and y) then return end
  local p = MapPointToWorld(m, x, y)
  if not p then return end
  -- the "next waypoint" being the quest itself isn't a hint
  local d = Dist(p, goal)
  if d and d < 50 then return end
  p.text = C_QuestLog.GetNextWaypointText and C_QuestLog.GetNextWaypointText(goal.qid) or nil
  if p.text == "" then p.text = nil end
  return p
end

------------------------------------------------------------------------
-- Planner (Dijkstra over a handful of nodes)
------------------------------------------------------------------------
local function FlyCost(a, b)
  local d = Dist(a, b)
  if not d then return end
  if d < 15 then return 0, d end
  local s = S()
  return (s.overhead or 5) + d / math.max(1, s.speed or 50), d
end

local nodeP, nodeK, nodeR, nodeDist, nodePrev, nodeDone = {}, {}, {}, {}, {}, {}

function Travel.Plan(goal, start)
  start = start or Travel.Sample()
  if not start then return nil, "Your position isn't available here." end
  if not goal then return nil, "Track a world quest (click it) or set a map pin." end
  local s = S()
  local load = s.loading or 15
  local penalty = s.minSaving or 20

  -- Nodes live in reused arrays (this runs every second while you have
  -- directions): position, kind and the teleport / portal behind it.
  local NP, NK, NR, dist, prev, done = nodeP, nodeK, nodeR, nodeDist, nodePrev, nodeDone
  local n = 0
  local function node(p, kind, ref) n = n + 1; NP[n], NK[n], NR[n] = p, kind, ref end
  node(start, "start"); node(goal, "goal")

  -- teleports usable now: start -> destination
  for _, t in ipairs(Travel.Teleports()) do
    if t.ready then node(t.dest, "tele", t) end
  end
  -- learned portals, plus the built-in ones you haven't taken yourself
  -- (entrance node, then its exit node)
  local learned = D().portals
  for _, pt in ipairs(learned) do node(pt.from, "portalIn", pt); node(pt.to, "portalOut", pt) end
  for _, b in ipairs(Travel.BuiltinPortals()) do
    local known = false
    for _, pt in ipairs(learned) do
      if SameSpot(pt.from, b.from, 120) and SameSpot(pt.to, b.to, 300) then known = true; break end
    end
    if not known then node(b.from, "portalIn", b); node(b.to, "portalOut", b) end
  end
  for i = 1, n do dist[i], prev[i], done[i] = nil, nil, nil end
  for i = n + 1, #NP do NP[i], NK[i], NR[i], dist[i], prev[i], done[i] = nil, nil, nil, nil, nil, nil end

  local function PortalCost(pt) return 3 + ((pt.load ~= false) and load or 0) end
  local function Relax(u, j, cost)
    local nd = dist[u] + cost
    if not dist[j] or nd < dist[j] then dist[j], prev[j] = nd, u end
  end

  -- Dijkstra. Ways out of a node: from the start, each ready teleport; from
  -- a portal entrance, its exit; and flying (same continent) to the goal or
  -- to a portal entrance - flying anywhere else is never shorter.
  dist[1] = 0
  for _ = 1, n do
    local u, best
    for i = 1, n do
      if not done[i] and dist[i] and (not best or dist[i] < best) then u, best = i, dist[i] end
    end
    if not u or u == 2 then break end
    done[u] = true
    if u == 1 then
      for j = 3, n do
        if NK[j] == "tele" then Relax(1, j, NR[j].cast + load + penalty) end
      end
    end
    if NK[u] == "portalIn" then Relax(u, u + 1, PortalCost(NR[u])) end
    for j = 2, n do
      if j ~= u and not done[j] and (j == 2 or NK[j] == "portalIn") then
        local cost = FlyCost(NP[u], NP[j])
        if cost then Relax(u, j, cost) end
      end
    end
  end

  local direct = FlyCost(start, goal)
  if not dist[2] then
    return { reachable = false, direct = direct, goal = goal }
  end
  -- the steps of the best route, last to first
  local steps, at = {}, 2
  while prev[at] do
    local u = prev[at]
    local st
    if NK[at] == "tele" and u == 1 then
      st = { kind = "tele", tele = NR[at], time = NR[at].cast + load }
    elseif NK[at] == "portalOut" and NK[u] == "portalIn" and at == u + 1 then
      st = { kind = "portal", portal = NR[u], time = PortalCost(NR[u]) }
    else
      local cost, d = FlyCost(NP[u], NP[at])
      st = { kind = "fly", dist = d, time = cost, to = { kind = NK[at], p = NP[at] } }
    end
    if not (st.kind == "fly" and (st.dist or 0) < 15) then table.insert(steps, 1, st) end
    at = u
  end
  local total = 0
  for _, st in ipairs(steps) do total = total + (st.time or 0) end
  return { reachable = true, steps = steps, total = total, direct = direct, goal = goal }
end

function Travel.FormatTime(sec)
  sec = math.max(0, math.floor((sec or 0) + 0.5))
  if sec < 60 then return sec .. "s" end
  if sec < 3600 then return string.format("%dm %02ds", math.floor(sec / 60), sec % 60) end
  return ns.Duration(sec)
end

-- Plan steps merged for display: "fly to the portal" + "take the portal"
-- become one step. Each: { text = "...", dist = yards or nil, step = raw }.
function Travel.DisplaySteps(plan)
  local out = {}
  if not (plan and plan.steps) then return out end
  local approach, approachTime
  for _, st in ipairs(plan.steps) do
    if st.kind == "fly" and st.to and st.to.kind == "portalIn" then
      approach, approachTime = st.dist, st.time
    elseif st.kind == "portal" then
      local pt = st.portal
      out[#out + 1] = {
        text = string.format("Portal in %s (%.0f, %.0f) » %s", pt.from.zone or "?",
          (pt.from.mx or 0) * 100, (pt.from.my or 0) * 100, pt.to.zone or "?"),
        dist = approach, step = st, time = (st.time or 0) + (approachTime or 0),
      }
      approach, approachTime = nil, nil
    elseif st.kind == "tele" then
      out[#out + 1] = { text = "Use " .. st.tele.label, step = st, time = st.time }
    elseif st.kind == "fly" then
      local target = st.to and st.to.kind
      out[#out + 1] = { text = target == "goal" and "Fly to the quest" or "Fly there", dist = st.dist, step = st, time = st.time }
    end
  end
  return out
end

-- One-line description of a step.
function Travel.Describe(st)
  if st.kind == "tele" then return "Use " .. st.tele.label end
  if st.kind == "portal" then
    return string.format("Take the portal in %s (%.0f, %.0f) » %s", st.portal.from.zone or "?",
      (st.portal.from.mx or 0) * 100, (st.portal.from.my or 0) * 100, st.portal.to.zone or "?")
  end
  if st.kind == "fly" then
    local target = st.to and st.to.kind
    local where = (target == "goal" and "the quest") or (target == "portalIn" and "the portal") or "there"
    return string.format("Fly %s to %s", ns.WQ.FormatDistance(st.dist), where)
  end
  return "?"
end

function Travel.SetPortalPin(pt)
  if not (pt and pt.from.map and C_Map.SetUserWaypoint and UiMapPoint) then return end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(pt.from.map, pt.from.mx, pt.from.my))
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
  ns.Print(string.format("Map pin set on the portal in %s.", pt.from.zone or "?"))
end

function Travel.Init()
  BuildHearthSpells()
  C_Timer.After(10, BuildHearthSpells) -- toy item data loads lazily
  ns.DB.migrated = ns.DB.migrated or {}
  -- (again once the built-in toys exist: old "portals" that were the Arcantina key)
  if not ns.DB.migrated.cleanPortals2 then
    C_Timer.After(12, function() CleanPortals(); ns.DB.migrated.cleanPortals, ns.DB.migrated.cleanPortals2 = true, true end)
  end
  C_Timer.NewTicker(1, Travel.Tick)
  if hooksecurefunc then
    if UseToy then hooksecurefunc("UseToy", function(id) Travel.OnItemUsed(id) end) end
    if C_ToyBox and C_ToyBox.UseToy then hooksecurefunc(C_ToyBox, "UseToy", function(id) Travel.OnItemUsed(id) end) end
    if C_Container and C_Container.UseContainerItem then
      hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID then Travel.OnItemUsed(info.itemID) end
      end)
    end
  end
end

function Travel.Forget()
  D().tele, D().portals = {}, {}
  for _, c in pairs(ns.DB.chars) do c.hearth = nil end
  ns.Print("Forgot all learned teleports and portals.")
  ns.Refresh()
end
