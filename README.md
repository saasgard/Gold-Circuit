# Gold Circuit

**Every gold-paying weekly, world quest and event across your whole alt army — tracked, routed and counted.**

Gold Circuit is built for World of Warcraft: Midnight. Log each alt once and it knows what every character has left this week, plans the fastest route for the one you're on, guides you there, and keeps a ledger of where your gold actually comes from.

<!-- Screenshots: dashboard (Route tab), compact tracker, World Quest Tracker, Alts tab -->

## Features

**Weekly tracking for every character**
- Apex Cache, Turn Back the Surge (Venom-Covered Chest), Harandar, Runestones, Abundance, Special Assignments and Crafting Orders — plus optional Aqir and Stormarion Assault. The Apex Cache counts its two kinds of quest ("Midnight:" weeklies and Trailing Xal'atath, each resetting every second week, a week apart); crafting orders count per crafting profession.
- Completion comes from the game's own quest flags, so it's right on every alt — including what you did before installing.
- Knows the rules: nothing below level 80, the Coiled Isle and some weeklies need 90, and Runestones / Harandar / Abundance open again at 90.
- Right-click anything to mark it done or not done yourself.

**Route and alt overview**
- **Route:** what's left on this character, grouped by zone and ordered by gold per minute, plus the next best alts to log.
- **Alts:** a grid of every character and activity, weekly net gold, gold left on the table, gold on hand and warband bank.
- **Compact tracker** on screen with what's left, and a minimap / addon-compartment button.

**World quests and Special Assignments**
- Every gold world quest in the Midnight zones with its reward (War Mode bonus included), time left and distance.
- The **World Quest Tracker** window: hover for objectives, right-click to skip a quest for the session or for good, sort by gold, distance, time or zone.
- Special Assignments with how many are up and how far each one is from unlocking.

**Aqir invasions**
- Running / next start / reward claimed straight from the map's Events tab — no more "active" for an invasion other players already finished.
- Knows when you've had this week's reward on each character, even for runs the addon didn't see.
- Optional reminder before it starts.

**Navigation**
- Directions to the quest you're tracking: fly directly, or use your Hearthstone, a teleport or a portal if that's faster. A **Use** button casts it.
- Learns your hearthstones (toys too), teleports and portals as you play. Setting your hearthstone at an innkeeper is enough; no need to use it first.
- Clicking a weekly pins its quest giver on the map.

**Cashflow ledger**
- Income and spending by source (quests, world quests, weekly caches, loot, crafting orders, auction house, vendors, repairs…), per character and per week.
- Filters by period, character, source and income/spending. Gold moved between your own characters and banks isn't counted as income.

**Crafting orders**
- Every patron / public / personal order priced with **TradeSkillMaster** or **Auctionator**: your mats, commission, rewards and profit.

## Getting started
1. Install, log in, and open it with `/gc` or the minimap coin.
2. Log each alt once so it shows up in the Alts grid.
3. Untick anything you don't do in the **Setup** tab.

The more you play, the better it gets: quest IDs, quest givers, reward averages and travel routes are learned automatically.

## Commands
| Command | |
|---|---|
| `/gc` | Open the dashboard |
| `/gc mini` | Show / hide the compact tracker |
| `/gc wqwin` | Show / hide the World Quest Tracker |
| `/gc route` | Print this character's route to chat |
| `/gc done <activity>` · `undo <activity>` | Mark done / not done (or right-click it) |
| `/gc unskip` | Bring back skipped world quests |
| `/gc travel` | List learned hearthstone, teleports and portals (`del <n>`, `forget`) |
| `/gc pin [activity]` | Show the map marker or pin you clicked; with an activity, save it as its spot (`/gc pin abundance`: this week's grotto, `/gc pin runestones`: where it's picked up) |
| `/gc events [activity]` · `/gc sa` | Event (Aqir, Abundance…) / Special Assignment diagnostics |
| `/gc help` | All commands |

Activity names: `apex venom harandar runestones abundance special aqir crafting stormarion`

## FAQ

**Does it work on non-English clients?**
Zone scanning, world quests, completion checks and navigation work in every language. Weekly and event names are matched in English, so on other clients activities are recognised by their built-in quest IDs and the ones learned while playing. A missing zone can be added with `/gc wqhere` while standing in it.

**An alt shows "?" or "~".**
That alt hasn't been logged in since its world quests / Special Assignments were recorded; "~" is an estimate from what's on the map now. Log in once to update it.

**A weekly was matched to the wrong quest.**
`/gc forget <activity>` clears it, `/gc learn <activity> <questID>` sets it, `/gc ids` lists what's learned.

**Something's wrong with an event (Aqir, Abundance) or Special Assignments.**
`/gc events <activity>` and `/gc sa` print exactly what the game reports — paste the output in a bug report.

## How it works (details)

**Quest detection.** Built-in quest IDs cover the Apex weeklies, Turn Back the Surge, Abundance, Runestones and Harandar. Everything else is matched by title the first time it's in your log or turned in; its ID is then learned for the whole account and checked on every alt with the game's completion flags. Gold estimates switch to your real average once you've opened that activity's cache (Setup: **Use avg** / type your own value).

**Aqir.** Completion counts when the event's reward quest is turned in, when you loot the Aqir Research Satchel, or when the event's hidden weekly flag is set on a character. The Events tab only lists events on the continent you're on; elsewhere the addon falls back to "starts every hour".

**World quests.** The Midnight zone maps are scanned at login, on zone change, when you open a window and every 5 minutes. Each alt remembers which were open when you last played it. A character too low for a quest is shown no reward, so its scans don't overwrite the gold for everyone.

**Quest givers.** Best first: the NPC you talked to that offered the weekly (exact spot and name), a quest hub on the map that offers it, or a "!" quest offer on the zone map. Aqir points to the Aqir Researchers between invasions and to the invasion while it runs.

**Navigation.** Distances are straight lines, so routes over mountains take a bit longer than estimated. Flying speed, loading-screen time and the minimum time a teleport must save are set in Setup. The Use button can't be set up during combat, so it hides then.

**Crafting orders.** Open a profession's Crafting Orders at its work table and browse the tabs; orders are read and priced automatically. Reagents are priced at the cheapest quality, so check an order's minimum quality before crafting. Price source and minimum profit are in Setup (`/gc tsmprice <source>` for TSM).

## Licence
MIT — see `LICENSE`.
