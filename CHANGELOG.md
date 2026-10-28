# Changelog

## 1.0.1

### Fixes
- Abundance: only "Abundant Offerings" counts. The intro chain (The Abundant Life) and the grotto quests no longer show it as done or in your log.
- Abundance: this week's grotto is found even when the map's Events tab gives no map for it, on its own zone instead of a neighbouring one. Last week's quest giver is no longer used after the reset.
- Aqir: directions go to the invasion marker on the map, not to the Aqir Researchers in Silvermoon.
- Runestones: no longer marked done just by picking up the quest. Claiming Saltheril's Soiree's reward no longer marks the Apex Cache done.
- Map pins are placed on the version of the zone you're actually on (Eversong Woods has two).

### Changes
- Clicking a weekly tracks its quest offer when the quest giver is known, so the game's own arrow guides you there, through portals from another zone too (Runestones, Abundance).
- Gold from Special Assignment caches (Fabled Coiled Isle Veteran's Cache and the others) has its own "Special Assignment" line in the cashflow instead of "Weekly Cache".
- New **/gc pin [activity]**: shows the marker or pin you clicked on the map; with an activity, saves it as that activity's spot.

## 1.0.0 — first public release

Gold Circuit tracks every gold-paying activity across your whole alt army in World of Warcraft: Midnight, plans the best route for the character you're on, and keeps a detailed cashflow ledger.

### Tracking
- Weeklies: Apex Cache, Turn Back the Surge (Venom-Covered Chest), Harandar, Runestones, Abundance, Special Assignments, Crafting Orders; optional Aqir and Stormarion Assault.
- Apex Cache: its two kinds of quest are counted separately. The "Midnight:" weeklies and Trailing Xal'atath each reset every second week, a week apart, so one or both can be up (a fresh 90 has both). All 14 quests that reward it are built in.
- Crafting Orders count per crafting profession: a character with Tailoring and Enchanting has two to do.
- Level rules: nothing below 80; Apex Cache, Turn Back the Surge and Coiled Isle content need 90. Runestones, Harandar and Abundance open again when a character reaches 90.
- Quest IDs are learned automatically; completion is checked with the game's own quest flags on every character.
- Gold from reward chests (Venom-Covered Chest, Apex Cache, Fabled Veteran's Cache) counts toward its activity.
- Mark anything done or not done yourself: right-click it in the route, the compact tracker or the Alts grid.
- From the map's Events tab: Stormarion Assault (running, reward claimed = done), Saltheril's Soiree, and this week's Abundance zone and spot for its marker.
- Gold estimates start at about 2,000g per weekly (Aqir 1,000g) and switch to your real average once you've opened that activity's reward.

### Aqir
- Running / next start / reward claimed come from the map's Events tab, so an invasion other players finished early no longer shows as running.
- Done for the week from the event's reward quest and its hidden weekly flag, including runs the addon didn't see.
- Optional reminder before it starts (off by default).
- Directions to the Aqir Researchers between invasions, to the invasion while it runs.

### World quests and Special Assignments
- Gold world quests across the Midnight zones, with War Mode bonus, time left and distance.
- World Quest Tracker window: objectives on hover; skip a quest for the session or for good; sort by gold, distance, time or zone.
- A gold world quest found on a level-90 character is also suggested to your other level-90 alts that haven't done it.
- Special Assignments: how many are up, unlock progress, listed below the world quests. The hidden unlock step (completed with the 3rd world quest) marks an assignment ready, not done.

### Navigation
- Directions to the tracked quest or map pin, comparing flying with your Hearthstone, teleports and learned portals; a Use button casts the teleport.
- Learns hearthstones and toys (including channeled ones), teleport spells and items, and portals as you play.
- Pins weekly pickups on the quest-giving NPC (built-in spots for Apex Cache, Harandar and Runestones until you've met them). The pin removes itself once you've picked the weekly up or reached the spot.
- Can be turned off in Setup.

### Dashboard
- Route, Alts, Orders, Cashflow and Setup tabs; compact tracker; minimap and addon-compartment buttons.
- Cashflow filters: period, character, source, income/spending.
- Crafting orders priced with TradeSkillMaster or Auctionator.
- Gold shown the same way everywhere: whole gold with thousands separators (12,345g).
- Setup: "Chat messages" mutes everything the addon says on its own; replies to /gc commands and warnings still show.

### Notes
- Zone scanning works in every client language. Weekly and event names are matched in English, so on other clients activities are recognised by their built-in quest IDs (and those learned while playing).
- Light on memory when idle; `/gc mem` shows what each repeating job uses, for bug reports.
