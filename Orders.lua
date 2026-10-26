local ADDON, ns = ...

--[[
  Crafting orders: find the ones worth doing.

  While a profession's crafting-order screen is open, the orders the game
  has loaded (Patron / Public / Personal tabs) are read every couple of
  seconds and evaluated:
    * do you know the recipe?
    * mats you must supply = recipe's required basic reagents minus what
      the customer provided, priced at the cheapest quality
    * income = commission minus the Consortium's cut, plus patron rewards
      that have an auction price
    * profit = income - mats

  Prices come from TradeSkillMaster (if installed) or Auctionator.
  Results are stored per character and profession and shown on the
  Orders tab and in the route.
--]]

local Orders = {}
ns.Orders = Orders

local function S() return ns.DB.settings.orders end

------------------------------------------------------------------------
-- Prices
------------------------------------------------------------------------
local Prices = {}
ns.Prices = Prices

function Prices.HasTSM()
  return TSM_API and TSM_API.GetCustomPriceValue and true or false
end

function Prices.HasAuctionator()
  return Auctionator and Auctionator.API and Auctionator.API.v1
    and Auctionator.API.v1.GetAuctionPriceByItemID and true or false
end

-- Which addon prices come from right now ("TSM", "Auctionator" or nil).
function Prices.Source()
  local want = S().priceSource or "auto"
  if (want == "auto" or want == "tsm") and Prices.HasTSM() then return "TSM" end
  if (want == "auto" or want == "auctionator") and Prices.HasAuctionator() then return "Auctionator" end
  if want ~= "auto" then
    -- chosen addon not loaded: fall back to the other one
    if Prices.HasTSM() then return "TSM" end
    if Prices.HasAuctionator() then return "Auctionator" end
  end
end

-- Copper per item, or nil if unknown.
function Prices.Get(itemID)
  if not itemID then return end
  local src = Prices.Source()
  if src == "TSM" then
    local ok, v = pcall(TSM_API.GetCustomPriceValue, S().tsmPrice or "first(DBMinBuyout, DBMarket)", "i:" .. itemID)
    if ok and v and v > 0 then return v end
  elseif src == "Auctionator" then
    local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, ADDON, itemID)
    if ok and v and v > 0 then return v end
  end
end

------------------------------------------------------------------------
-- Evaluate one order
------------------------------------------------------------------------
local function Enumv(group, key, default)
  return (Enum and Enum[group] and Enum[group][key]) or default
end

local function TypeName(t)
  if t == Enumv("CraftingOrderType", "Npc", 3) then return "Patron" end
  if t == Enumv("CraftingOrderType", "Personal", 2) then return "Personal" end
  if t == Enumv("CraftingOrderType", "Guild", 1) then return "Guild" end
  return "Public"
end
Orders.TypeName = TypeName

local function ItemIDFromLink(link)
  if not link then return end
  if C_Item and C_Item.GetItemInfoInstant then
    local id = C_Item.GetItemInfoInstant(link)
    if id then return id end
  end
  return tonumber(link:match("item:(%d+)"))
end

function Orders.Evaluate(o)
  local e = {
    id = o.orderID, spellID = o.spellID, type = o.orderType, typeName = TypeName(o.orderType),
    tip = o.tipAmount or 0, cut = o.consortiumCut or 0, expires = o.expirationTime,
    minQuality = o.minQuality, customer = o.customerName,
  }
  local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(o.spellID)
  e.name = (info and info.name) or ("Recipe " .. tostring(o.spellID))
  e.known = info and info.learned and true or false

  -- reagents the customer supplied
  local provided = {}
  for _, r in ipairs(o.reagents or {}) do
    local id = (r.reagent and r.reagent.itemID) or r.itemID
    if id then provided[id] = true end
  end

  local cost, missing, mats = 0, false, {}
  local allProvided = o.reagentState == Enumv("CraftingOrderReagentsType", "All", 0)
  if not allProvided and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
    local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, o.spellID, o.isRecraft or false)
    local basic = Enumv("CraftingReagentType", "Basic", 1)
    for _, slot in ipairs(ok and sch and sch.reagentSlotSchematics or {}) do
      if slot.required and slot.reagentType == basic then
        local given, best, bestID = false, nil, nil
        for _, rg in ipairs(slot.reagents or {}) do
          if provided[rg.itemID] then given = true end
          local p = Prices.Get(rg.itemID)
          if p and (not best or p < best) then best, bestID = p, rg.itemID end
        end
        if not given then
          local qty = slot.quantityRequired or 1
          local firstID = slot.reagents and slot.reagents[1] and slot.reagents[1].itemID
          if best then
            cost = cost + best * qty
            mats[#mats + 1] = { itemID = bestID, qty = qty, price = best }
          else
            missing = true
            mats[#mats + 1] = { itemID = firstID, qty = qty }
          end
        end
      end
    end
  end

  -- patron rewards
  local rewardValue, rewards = 0, {}
  for _, rw in ipairs(o.npcOrderRewards or {}) do
    local count = rw.count or 1
    if rw.itemLink then
      local p = Prices.Get(ItemIDFromLink(rw.itemLink))
      if p then rewardValue = rewardValue + p * count end
      rewards[#rewards + 1] = { text = (count > 1 and (count .. "x ") or "") .. rw.itemLink, value = p and p * count }
    elseif rw.currencyType and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
      local ci = C_CurrencyInfo.GetCurrencyInfo(rw.currencyType)
      rewards[#rewards + 1] = { text = count .. "x " .. ((ci and ci.name) or "currency") }
    end
  end

  e.cost, e.missingPrices, e.mats = cost, missing, mats
  e.rewardValue, e.rewards = rewardValue, rewards
  e.income = e.tip - e.cut + rewardValue
  e.profit = e.income - cost
  return e
end

------------------------------------------------------------------------
-- Scanning while the profession window is open
------------------------------------------------------------------------
-- The game only fills GetCrafterOrders() after Blizzard's order screen asks
-- the server (clicking Patron / Public / Personal). So: watch the
-- profession window, hook those requests, and read the list shortly after.
local ticker, profAtOpen
local isOpen = false
local sessionSeen = 0          -- orders read since the window opened
local requestedThisSession = false
local lastSig
Orders.debug = { events = {} }

local function Note(what) Orders.debug.events[#Orders.debug.events + 1] = date("%H:%M:%S") .. " " .. what
  if #Orders.debug.events > 12 then table.remove(Orders.debug.events, 1) end end

local function CurrentProfession()
  if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
    local info = C_TradeSkillUI.GetBaseProfessionInfo()
    if info and info.professionName and info.professionName ~= "" then return info.professionName end
  end
  return "Profession"
end
Orders.CurrentProfession = CurrentProfession

local function OrdersPageShown()
  local pf = _G.ProfessionsFrame
  return pf and pf.OrdersPage and pf.OrdersPage.IsShown and pf.OrdersPage:IsShown() or false
end

function Orders.Store(c)
  c.craftOrders = c.craftOrders or {}
  return c.craftOrders
end

function Orders.Scan(force)
  local d = Orders.debug
  d.hasAPI = C_CraftingOrders and C_CraftingOrders.GetCrafterOrders and true or false
  if not d.hasAPI then return end
  -- don't trust a list left over from another profession
  if not (requestedThisSession or OrdersPageShown() or force) then return end
  local ok, list = pcall(C_CraftingOrders.GetCrafterOrders)
  if not ok or type(list) ~= "table" then d.lastError = tostring(list); return end
  d.lastCount, d.lastRead = #list, time()

  local sig = {}
  for _, o in ipairs(list) do sig[#sig + 1] = tostring(o.orderID) end
  sig = table.concat(sig, ",")
  if sig == lastSig and not force then return end
  lastSig = sig

  local c = ns.GetChar()
  local prof = CurrentProfession()
  local store = Orders.Store(c)
  local entry = store[prof] or { orders = {} }
  store[prof] = entry

  local seenTypes, seen = {}, {}
  for _, o in ipairs(list) do
    if o.orderID and o.spellID then
      seen[o.orderID] = true
      seenTypes[o.orderType or -1] = true
      local okE, e = pcall(Orders.Evaluate, o)
      if okE then entry.orders[o.orderID] = e else d.lastError = tostring(e) end
    end
  end
  -- orders of a tab we just looked at that aren't listed any more are gone
  for id, e in pairs(entry.orders) do
    if seenTypes[e.type or -1] and not seen[id] then entry.orders[id] = nil end
  end
  if #list > 0 then
    entry.scanned = time()
    sessionSeen = sessionSeen + #list
    Note(string.format("read %d %s orders", #list, prof))
  end
  ns.Refresh()
end

-- Blizzard's order screen asked the server for orders: read them shortly.
local function OnRequest()
  requestedThisSession = true
  Note("order list requested")
  C_Timer.After(1, Orders.Scan)
  C_Timer.After(3, Orders.Scan)
end

local hooked = false
function Orders.InstallHooks()
  if hooked then return end
  if C_CraftingOrders and C_CraftingOrders.RequestCrafterOrders then
    hooksecurefunc(C_CraftingOrders, "RequestCrafterOrders", OnRequest)
    hooked = true
  end
  Orders.HookOrdersPage()
end

-- Blizzard_Professions loads on demand; hook its orders page when it does.
local pageHooked = false
function Orders.HookOrdersPage()
  if pageHooked then return end
  local pf = _G.ProfessionsFrame
  if pf and pf.OrdersPage and pf.OrdersPage.HookScript then
    pf.OrdersPage:HookScript("OnShow", function()
      Note("orders page shown")
      requestedThisSession = true
      C_Timer.After(1, Orders.Scan)
      C_Timer.After(3, Orders.Scan)
    end)
    pageHooked = true
  end
end

function Orders.OnOpen()
  Orders.InstallHooks()
  if isOpen then return end -- already open (several events can signal it)
  isOpen = true
  Note("profession window opened (" .. CurrentProfession() .. ")")
  profAtOpen = CurrentProfession()
  sessionSeen, requestedThisSession, lastSig = 0, false, nil
  ticker = C_Timer.NewTicker(2, Orders.Scan)
  Orders.Scan()
end

function Orders.OnClose()
  if not isOpen then return end
  isOpen = false
  if ticker then ticker:Cancel(); ticker = nil end
  Note("profession window closed")
  Orders.Scan()
  requestedThisSession = false
  if sessionSeen > 0 and ns.DB.settings.announce then
    local list = Orders.List(ns.GetChar(), profAtOpen)
    local good, gold, noRecipe, unpriced = 0, 0, 0, 0
    for _, e in ipairs(list) do
      if e.verdict == "profit" then good = good + 1; gold = gold + e.profit
      elseif e.verdict == "recipe" then noRecipe = noRecipe + 1
      elseif e.verdict == "price" then unpriced = unpriced + 1 end
    end
    if #list > 0 then
      local extra = unpriced > 0 and string.format(", %d with unpriced mats", unpriced) or ""
      ns.Print(string.format("%s orders: %d worth doing (%s profit), %d missing the recipe%s, %d not worth it. See the Orders tab.",
        profAtOpen or "Crafting", good, ns.Money(gold), noRecipe, extra, #list - good - noRecipe - unpriced))
    end
  end
end

-- /gc orders: what the addon can see right now.
function Orders.Report()
  local d = Orders.debug
  ns.Print("Crafting orders diagnostics:")
  print("  Order API available: " .. tostring(C_CraftingOrders and C_CraftingOrders.GetCrafterOrders and true or false)
    .. "   request hook: " .. tostring(hooked) .. "   orders page hook: " .. tostring(pageHooked))
  print("  Profession window open: " .. tostring(isOpen) .. "   orders page shown: " .. tostring(OrdersPageShown())
    .. "   profession: " .. CurrentProfession())
  if C_CraftingOrders and C_CraftingOrders.GetCrafterOrders then
    local ok, list = pcall(C_CraftingOrders.GetCrafterOrders)
    print("  Orders the game has loaded right now: " .. (ok and type(list) == "table" and #list or ("error: " .. tostring(list))))
  end
  print("  Prices from: " .. tostring(ns.Prices.Source() or "none (install Auctionator or TSM)"))
  local n = 0
  for prof, entry in pairs(Orders.Store(ns.GetChar())) do
    local k = 0
    for _ in pairs(entry.orders or {}) do k = k + 1 end
    n = n + k
    print(string.format("  Saved: %s — %d orders, scanned %s", prof, k, entry.scanned and (ns.Duration(time() - entry.scanned) .. " ago") or "never"))
  end
  if n == 0 then print("  Saved: nothing yet on this character") end
  if d.lastError then print("  Last error: " .. d.lastError) end
  for _, ev in ipairs(d.events) do print("  " .. ev) end
end

function Orders.OnFulfilled(orderID)
  for _, entry in pairs(Orders.Store(ns.GetChar())) do
    if entry.orders then entry.orders[orderID] = nil end
  end
end

------------------------------------------------------------------------
-- Reading results
------------------------------------------------------------------------
-- verdict: "profit" | "loss" | "recipe" (not known) | "price" (mats unpriced)
local function Verdict(e)
  if not e.known then return "recipe" end
  if e.missingPrices then return "price" end
  if e.profit >= (S().minProfit or 0) * 10000 then return "profit" end
  return "loss"
end

-- Live orders for a character (optionally one profession), best first.
function Orders.List(c, onlyProf)
  local out, now = {}, time()
  for prof, entry in pairs(c.craftOrders or {}) do
    if not onlyProf or prof == onlyProf then
      for _, e in pairs(entry.orders or {}) do
        if not e.expires or e.expires > now then
          e.prof = prof
          e.verdict = Verdict(e)
          out[#out + 1] = e
        end
      end
    end
  end
  local rank = { profit = 1, price = 2, recipe = 3, loss = 4 }
  table.sort(out, function(a, b)
    if rank[a.verdict] ~= rank[b.verdict] then return rank[a.verdict] < rank[b.verdict] end
    return a.profit > b.profit
  end)
  return out
end

-- Profitable orders for the route: count, total profit, last scan time
-- (optionally of one profession).
function Orders.Summary(c, onlyProf)
  local n, gold, newest = 0, 0, nil
  for prof, entry in pairs(c.craftOrders or {}) do
    if (not onlyProf or prof == onlyProf) and entry.scanned and (not newest or entry.scanned > newest) then newest = entry.scanned end
  end
  for _, e in ipairs(Orders.List(c, onlyProf)) do
    if e.verdict == "profit" then n = n + 1; gold = gold + e.profit end
  end
  return n, gold, newest
end
