local ADDON, ns = ...

--[[
  Activity definitions.

  Quest IDs are NOT hardcoded: they change between patches and differ for
  rotating quests (Special Assignments). Instead each activity has title
  patterns (plain, case-insensitive substring match). The first time a
  matching quest enters your quest log or is turned in, its quest ID is
  learned account-wide, after which completion is detected with
  C_QuestLog.IsQuestFlaggedCompleted on every character.

  Learned IDs can be reviewed / cleared in the Setup tab or with
  /gc forget <key>, and set manually with /gc learn <key> <questID>.

  gold    = default estimated gold per completion (replaced automatically by
            the real average once you've opened a cache / turned one in)
  minutes = your estimated time per completion (used for gold/minute routing)
  count   = completions available per week
  caches  = names of the reward container(s); gold looted from these is
            attributed to the activity
  cacheIDs = item IDs of those containers (more reliable than the name)
  cacheSource = cashflow line for gold from its caches (default "Weekly Cache")
  zone    = default zone; overwritten by the zone you actually turn it in
  minLevel = character level needed to pick it up (default 80)
  backlog = how many can be up at once after skipping weeks
  families = kinds of quest that each reset every second week, a week
            apart ({ kind = { [questID] = true } }; the activity's other
            quests are the "main" kind): one completion per kind
  eventTab = names it has in the map's Events tab: where it is (marker,
            zone), whether it's running, and reward claimed = done
            (eventDone = false: location only; eventMarker: clicking it
            goes to the event's spot; pickupMoves: a quest giver you
            talked to only counts the week you talked to them)
  again90 = a level-90 version is offered on reaching 90, even if the
            80-89 one was done this week
  remind  = default minutes before an event starts to remind you (0 = off)
  pickup  = { mapID, x, y }: where the quest giver stands, until the addon
            learns it in game (then the learned spot wins)
--]]

ns.ACTIVITIES = {
  -- Apex Cache: two kinds of quest take turns. A "Midnight: X" weekly from
  -- Lady Liadrin in Silvermoon (Unity Against the Void, or Saltheril's
  -- Soiree) and Trailing Xal'atath each reset every second week, a week
  -- apart. Both are up on a fresh 90, or after two weeks without them.
  { key = "apex", name = "Apex Cache", short = "Apex",
    desc = "A 'Midnight:' weekly (Unity Against the Void) and Trailing Xal'atath each give an Apex Cache. Each resets every second week, a week apart, so one or both can be up.",
    -- the second kind of quest; every other Apex quest is the "Midnight:" kind
    families = { xalatath = { [98172] = true } },
    -- not "Saltheril": the "Saltheril's Soiree" world quest has nothing to
    -- do with it ("Midnight: Saltheril's Soiree" is matched by "Midnight:")
    patterns = { "Unity Against the Void", "Midnight:" },
    caches = { "Apex Cache" }, cacheIDs = { [279527] = true },
    ids = {
      [93912] = "Midnight: Raid", [93911] = "Midnight: Dungeons",
      [94457] = "Midnight: Battlegrounds", [93769] = "Midnight: Housing",
      [93910] = "Midnight: Prey", [93913] = "Midnight: World Boss",
      [93767] = "Midnight: Arcantina", [93890] = "Midnight: Abundance",
      [93889] = "Midnight: Saltheril's Soiree", [98232] = "Midnight: Vaults of Atal'Utek",
      [93909] = "Midnight: Delves", [93766] = "Midnight: World Quests",
      [95843] = "Midnight: Ritual Sites", [95842] = "Midnight: Void Assaults",
      [98172] = "Trailing Xal'atath", -- no "Midnight:" in its name, so only known by ID
    },
    -- (every quest Wowhead lists as rewarding the Apex Cache, item 279527)
    pickup = { 2393, 0.49, 0.65 }, -- Silvermoon City
    gold = 2000, minutes = 10, count = 1, enabled = true, minLevel = 90 },

  { key = "venom", name = "Turn Back the Surge", short = "Surge",
    desc = "Weekly quest, rewards the Venom-Covered Chest",
    patterns = { "Turn Back the Surge" },
    caches = { "Venom-Covered Chest" }, cacheIDs = { [275911] = true },
    ids = { [96995] = "Turn Back the Surge" },
    gold = 2000, minutes = 15, count = 1, enabled = true, minLevel = 90 },

  { key = "harandar", name = "Harandar", short = "Hrnd",
    desc = "Legends of the Haranir weekly",
    patterns = { "Legends of the Haranir", "Haranir" },
    caches = { "Avid Learner's Supply Pack" }, cacheIDs = { [269703] = true, [279525] = true }, zone = "Harandar",
    -- pick one of these each week
    ids = { [88993] = "Legends of the Haranir", [88994] = "Legends of the Haranir",
            [88995] = "Legends of the Haranir", [88996] = "Legends of the Haranir",
            [88997] = "Legends of the Haranir", [90739] = "Legends of the Haranir",
            [92720] = "Legends of the Haranir" },
    pickup = { 2413, 0.54, 0.53 }, -- Harandar
    gold = 2000, minutes = 5, count = 1, enabled = true, again90 = true },

  -- Pick one of four runestone quests each week, picked up at Saltheril's
  -- Soiree. The Soiree's Events-tab entry isn't used: its "reward claimed"
  -- is set by just picking up the quest, and clicking Runestones tracks the
  -- quest offer instead of its marker (only quests get the game's arrow
  -- through portals from another zone).
  { key = "runestones", name = "Runestones", short = "Rune",
    desc = "Pick one of the four runestone weeklies",
    patterns = { "Runestone" },
    caches = { "Surplus Bag of Party Favors" }, cacheIDs = { [269701] = true, [279522] = true },
    ids = { [90573] = "Runestone", [90574] = "Runestone", [90575] = "Runestone", [90576] = "Runestone" },
    pickup = { 2395, 0.43, 0.47 }, -- Eversong Woods
    gold = 2000, minutes = 5, count = 1, enabled = true, again90 = true },

  -- Abundant Offerings: one of four zones each week. The map's Events tab
  -- lists this week's one ("Abundance: Herbalism Grotto") with its zone,
  -- which is where the marker goes.
  { key = "abundance", name = "Abundance", short = "Abund",
    desc = "Abundant Offerings (one zone per week)",
    -- only the exact name: "Abundance: <grotto>", the intro chain etc. aren't the weekly
    patterns = { "Abundant Offerings" },
    caches = { "Overflowing Abundant Satchel" }, cacheIDs = { [269702] = true, [279523] = true },
    eventTab = { "Abundance" },
    eventDone = false, -- a grotto's reward isn't the weekly; only its location is used
    eventMarker = true, -- clicking it goes to this week's spot
    pickupMoves = true, -- the quest giver is in that week's zone
    ids = { [89507] = "Abundant Offerings" },
    gold = 2000, minutes = 3, count = 1, enabled = true, again90 = true },

  -- How many are up comes from the map (up to 3 if you haven't done any
  -- in a while); Coiled Isle ones need level 90.
  { key = "special", name = "Special Assignments", short = "SA",
    desc = "Unlock after 3 world quests in their zone; up to 3 at a time. Rewards the Fabled Veteran's Cache.",
    patterns = { "Special Assignment" },
    caches = { "Fabled Veteran's Cache", "Fabled Coiled Isle Veteran's Cache", "Fabled Adventurer's Cache" },
    cacheIDs = { [279520] = true },
    cacheSource = "Special Assignment", -- its own cashflow line, not "Weekly Cache"
    gold = 2000, minutes = 15, count = 3, enabled = true },

  -- World event on the map. Its reward shows whether this week is done:
  -- an epic bag = not done yet, a token = already done.
  { key = "aqir", name = "Aqir", short = "Aqir", mapEvent = true,
    desc = "Aqir world event (done when it offers a token, not the epic bag)",
    patterns = { "Aqir Invasion", "Aqir Assault" },
    -- names that only appear for the live event (map marker, scenario, area objective)
    eventNames = { "Aqir" },
    -- the NPCs that are always on the map (go there between invasions);
    -- not the event itself
    hubNames = { "Aqir Researchers" },
    ids = { [57565] = "Aqir Assault", [84215] = "Aqir weekly", [84216] = "Aqir weekly" },
    caches = { "Aqir Research Satchel" },  -- weekly reward from the final boss
    -- hidden quest turned in when you finish a run: done for the week
    doneQuests = { [97316] = "Reward Quest (DNT)" },
    -- hidden quest the game completes with the week's first reward (found
    -- by the addon's flag learning, 12.1.5): any character with it completed
    -- has done Aqir this week, even if the addon didn't see the run
    weeklyFlags = { [97456] = true },
    -- starts every whole hour; questID is used to see if it's running now
    -- (the map's Events tab is used instead when the game provides it)
    schedule = { every = 3600, offset = 0, questID = 57565 },
    gold = 1000, minutes = 15, count = 1, enabled = false, remind = 0 },

  { key = "crafting", name = "Crafting Orders", short = "CO", kind = "crafting",
    desc = "Fulfil patron/public orders (per crafting profession: done after 1 order with it this week)",
    patterns = {}, caches = {},
    gold = 500, minutes = 5, count = 1, enabled = true },

  -- Optional extra (off by default, enable in Setup). An event in the map's
  -- Events tab, tracked from there like Aqir: running, and reward claimed.
  { key = "stormarion", name = "Stormarion Assault", short = "Storm",
    desc = "Weekly event in Voidstorm (map Events tab)",
    -- the cache comes from completing the event (that's where the gold is)
    patterns = { "Stormarion" }, caches = { "Victorious Stormarion Pinnacle Cache" }, cacheIDs = { [279526] = true },
    cacheDone = true, -- receiving the cache = done for the week
    eventTab = { "Stormarion Assault" },
    eventMarker = true,
    gold = 2000, minutes = 20, count = 1, enabled = false },
}

-- Activities taken out (little gold) or merged (the Soiree is an Apex Cache
-- quest); their saved data is moved or cleared on load.
ns.REMOVED_ACTIVITIES = { soiree = "apex", prey = false, amani = false }

-- Quests whose titles match a pattern above but are not weeklies.
ns.NOT_WEEKLY = {
  [95245] = true, -- Midnight: World Tour (campaign, not an Apex weekly)
  [91966] = true, -- Saltheril's Soiree (world quest, not the Apex weekly)
  -- Abundance quests learned by the old broad "Abundance"/"Abundant" match
  [94361] = true, -- The Abundant Life (intro chain)
  [97625] = true, -- Glorious Abundance
  [91457] = true, -- Abundance: Watha'nan Crypts
  [91302] = true, -- Abundance: Abundant Grove
}

-- Events-tab markers by area POI ID, for when the game doesn't place one
-- on the map: { mapID, x, y, name }. A spot seen in game wins.
ns.EVENT_SPOTS = {
  [8525] = { 2413, 0.660, 0.616, "Abundance: Skinning Den" }, -- Harandar
}

-- IDs that were wrong in earlier data (NPC IDs, not quests); removed on load.
ns.BAD_IDS = { [241928] = true, [248658] = true, [257632] = true, [257633] = true }

-- Level below which nothing is tracked (Midnight starts at 80).
ns.MIN_LEVEL = 80

ns.ACT_BY_KEY = {}
for _, a in ipairs(ns.ACTIVITIES) do ns.ACT_BY_KEY[a.key] = a end

-- Any opened container whose name contains one of these (and isn't mapped
-- above) is logged as "Container" income rather than plain loot.
ns.GENERIC_CONTAINER_WORDS = { "Cache", "Chest", "Satchel", "Coffer", "Pack", "Bag of" }

-- Cashflow source categories (display order)
ns.SOURCES = {
  "Quest", "World Quest", "Weekly Cache", "Special Assignment", "Container", "Loot", "Crafting Order", "Auction",
  "Vendor", "Repair", "Mail", "Trade", "Flight", "Trainer", "Other", "Transfer",
}

ns.SOURCE_COLORS = {
  ["Quest"] = { 1.00, 0.82, 0.00 },
  ["World Quest"] = { 0.95, 0.95, 0.45 },
  ["Weekly Cache"] = { 1.00, 0.55, 0.10 },
  ["Special Assignment"] = { 1.00, 0.40, 0.25 },
  ["Container"] = { 0.90, 0.70, 0.30 },
  ["Loot"] = { 0.60, 0.80, 0.30 },
  ["Crafting Order"] = { 0.40, 0.75, 1.00 },
  ["Auction"] = { 0.75, 0.50, 1.00 },
  ["Vendor"] = { 0.70, 0.70, 0.70 },
  ["Repair"] = { 0.90, 0.35, 0.35 },
  ["Mail"] = { 0.50, 0.90, 0.90 },
  ["Trade"] = { 0.95, 0.60, 0.80 },
  ["Flight"] = { 0.60, 0.60, 0.90 },
  ["Trainer"] = { 0.80, 0.80, 0.50 },
  ["Other"] = { 0.55, 0.55, 0.55 },
  ["Transfer"] = { 0.40, 0.40, 0.40 },
}
