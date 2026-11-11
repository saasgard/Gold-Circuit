# Changelog

## 1.4.0

### New
- Compact tracker: an optional **hearthstone / teleport button** at the bottom (Setup > Windows, off by default). It shows while the World Quest Tracker is closed and uses the same hearthstone or teleport its directions would suggest. When that one is on cooldown, the button is greyed out and counts down until it's ready.
- **Key bindings** in their own **Gold Circuit** section of Options > Keybindings: use the hearthstone / teleport (works even while its button is hidden), and open or close the dashboard, Compact Tracker, World Quest Tracker and caches pop-up. Setup > Windows > **Set keys** opens them and shows the hearthstone key.
- Dashboard: a **Compact Tracker** button next to World Quest Tracker. Both light up while their window is open.
- **Caches pop-up**: lists every cache, bag and box in your bags that can be opened, with Gold Circuit's weekly caches first. Click a row to open one. It pops up when something openable lands in your bags (not in combat), closes when nothing is left, and Esc closes it. Open it any time with the dashboard's **Caches** button (it shows how many there are) or `/gc open`. Right-click an item to never show it there again. Setup > Windows turns the automatic pop-up off and brings hidden items back.
- **Learned travel window**: the hearthstone, teleports and portal links the addon has learned, each with a **Remove** button, so a wrong one is easy to get rid of. Hover a row for where it goes; click a portal link to pin its entrance on the map. Open it with `/gc travel` or Setup > World quests & travel > **Show list** (`/gc travel list` still prints it in chat).
- **Learned quest IDs window**: which quests count for each activity, with a **Remove** button for one that was matched to the wrong activity. A removed quest isn't learned again, and it's listed under Removed with a **Restore** button. Open it with `/gc ids` or Setup > Activities > **Show quest IDs** (`/gc ids list` still prints them in chat).
- **Trackers** options (Setup > Windows): **Hide in combat** hides the Compact Tracker and World Quest Tracker while you fight, and **Fade** makes them see-through while the mouse isn't over them (opacity is adjustable, 40% by default). Both are off by default.

### Changes
- The suggested hearthstone / teleport updates as soon as you track a quest or set a map pin, and every few seconds while you move.
- **Setup is split into sub-tabs**: Activities, Windows, World quests & travel, and Crafting orders. The last one you used is remembered.
- Setup: chat messages and the level filter moved to a new General section on the Windows sub-tab. The new options explain themselves when you hover them, and the hearthstone / teleport option is greyed out while the Compact Tracker is off.

### Fixes
- Navigation: equipping a trinket or other gear from your bags just before taking a teleport no longer teaches it as a teleport (it suggested "Use Effigy of Ula'tek's Faithful » Silvermoon City"). An item now only counts if its own spell was cast, and trinkets, weapons and armour never count. Gear learned this way is forgotten on login; a real teleport ring or cloak is learned again the next time you use it.
- Aqir: quests turned in during or just after an event (such as a nearby Special Assignment's "Tomes of Terror") no longer mark Aqir done or get learned as Aqir quests. Taking part without getting the reward (for example when the other faction tags the boss) no longer counts either. Aqir is done when you get the reward itself. Quests learned this way are forgotten on login, and the "done" and gold they gave are taken back.

## 1.3.1

### Fixes
- Harandar: the story quests (Wey'nan's Ward, Russula's Outreach, Aln'hara's Bloom, The Cauldron of Echoes, The Echoless Flame) are no longer counted. They stay completed once done, so characters that had finished them showed Harandar as done every week. Only the weekly "The Story of …" quests count now (all seven, so whichever one is up that week is recognised).

## 1.3.0

### New
- Navigation: the **Personal Key to the Arcantina** now counts as a way to Silvermoon City, through the portal next to where it lands.

### Fixes
- Harandar: quest 90739 ("Legends of the Haranir") is no longer counted. It stays completed after the weekly reset, so characters were shown as done every week.

## 1.2.0

### New
- Navigation: **Dundun's Abundant Travel Method** is offered as a teleport to the current Abundance spot when you own it and it's off cooldown.

### Fixes
- Navigation: mage portals are no longer learned as travel links while another mage is in your group. A portal you cast yourself on a mage is kept as that character's teleport, so other characters don't get it.
- Navigation: summons are no longer learned as travel links.
- Crafting Orders: gathering professions such as Mining no longer show up after opening their window. Saved empty entries are cleared on login.

## 1.1.2

### Fixes
- Special Assignments: Lairs (such as "Lair: Nymrissa Wavecaller") no longer count toward the unlock, in the progress, the world quests open in the zone or the SA tag in the World Quest Tracker.
- Special Assignments: the "complete" message counts the assignments on the map, like the tracker, instead of a saved number that could be too low.
- Special Assignments: an unlocked assignment's own objectives ("0/6 Altars destroyed") are no longer shown as world quests needed to unlock it.

## 1.1.1

### Fixes
- Abundance: directions follow the grotto when it changes during the week. A grotto marker you clicked now only holds until its slot ends, not until the weekly reset, and the running grotto beats an older marker still on the map.
- Abundance: the built-in spot for the Skinning Den is in Zul'Aman, not Harandar.

## 1.1.0

### Fixes
- Apex Cache: the "Saltheril's Soiree" world quest no longer counts as the Apex Cache (only "Midnight: Saltheril's Soiree" does). A false completion it caused is cleared on login.
- Abundance: directions go to this week's grotto, the one with a marker on the map, even when the map's Events tab lists another one. Every zone's quest giver offers the same quest, so the giver you talked to last is no longer used.

### Changes
- Clicking a weekly only gives directions; the World Quest Tracker no longer opens on its own (open it with its button, Shift-click on the minimap button or /gc wq).
- Directions track the event's map marker or the quest offer, like clicking it on the map, and the game's own arrow finds the way. Only when nothing can be tracked from another zone is the portal on the route marked first (the game's portal marker when there is one), then the spot once you're through.
- Clicking an Abundance grotto marker on the map makes it this week's spot until the reset.
- Compact tracker: the World Quests row sits under Special Assignments, apart from the weekly list.
- **/gc events [activity]** replaces /gc aqir (which still works): diagnostics for any event, e.g. /gc events abundance. Recent turn-ins show which character turned them in.

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
