local ADDON, ns = ...

--[[
  One look for every window. The dashboard, the compact tracker and the
  world quest tracker build their frames, title bars, section headers,
  rows, buttons and dropdowns from these, so they stay the same.
--]]
local Style = {}
ns.Style = Style

local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Muted bronze for the frame itself; bright gold is kept for what matters
-- (gold amounts, titles, the active waypoint).
Style.BG        = { 0.04, 0.04, 0.05, 0.92 }
Style.BORDER    = { 0.45, 0.38, 0.22, 0.75 }
Style.GOLD      = { 0.70, 0.58, 0.32 }      -- tints: title bar, sections, lines
Style.ACCENT    = { 0.72, 0.60, 0.34 }      -- section edge, tracked rows
Style.ACTIVE    = { 0.35, 0.85, 0.45 }      -- active waypoint / selected
Style.HOVER     = { 1, 0.92, 0.7, 0.07 }
Style.TITLE_H   = 26
Style.TITLE_A   = 0.10
Style.SECTION_A = 0.06
Style.STRIPE_A  = 0.025
Style.LINE_A    = 0.22
Style.SECTION_TEXT = "|cffc9b27a"           -- section header labels
Style.MEDIA     = "Interface\\AddOns\\GoldCircuit\\Media\\"
Style.ICON      = Style.MEDIA .. "icon"     -- the Gold Circuit logo
Style.GLYPH     = { 0.79, 0.70, 0.48 }      -- button glyphs (white textures, tinted)
Style.GLYPH_HI  = { 1, 0.86, 0.47 }
Style.CLOSE_HI  = { 1, 0.52, 0.45 }         -- the X turns soft red on hover

local G = Style.GOLD

function Style.Window(f)
  f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  f:SetBackdropColor(unpack(Style.BG))
  f:SetBackdropBorderColor(unpack(Style.BORDER))
end

-- Tinted bar along the top with the coin icon and a title.
function Style.TitleBar(f, text)
  local bar = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  bar:SetPoint("TOPLEFT", 1, -1)
  bar:SetPoint("TOPRIGHT", -1, -1)
  bar:SetHeight(Style.TITLE_H)
  bar:SetColorTexture(G[1], G[2], G[3], Style.TITLE_A)
  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetSize(16, 16)
  icon:SetPoint("TOPLEFT", 8, -6)
  icon:SetTexture(Style.ICON)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
  title:SetText(text)
  return bar, icon, title
end

-- Small framed square with a glyph (Media\close, Media\refresh...):
-- brighter on hover, the glyph shifts a pixel while pressed.
local function GlyphButton(parent, glyph, size, hoverTint)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(size, size)
  b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  local function Look(hover)
    b:SetBackdropColor(1, 1, 1, hover and 0.10 or 0.04)
    b:SetBackdropBorderColor(G[1], G[2], G[3], hover and 0.85 or 0.45)
    b.glyph:SetVertexColor(unpack(hover and (hoverTint or Style.GLYPH_HI) or Style.GLYPH))
  end
  b.glyph = b:CreateTexture(nil, "ARTWORK")
  b.glyph:SetTexture(Style.MEDIA .. glyph)
  b.glyph:SetSize(size - 6, size - 6)
  b.glyph:SetPoint("CENTER")
  Look(false)
  b:SetScript("OnEnter", function() Look(true) end)
  b:SetScript("OnLeave", function() Look(false) end)
  b:SetScript("OnMouseDown", function(s) s.glyph:SetPoint("CENTER", 1, -1) end)
  b:SetScript("OnMouseUp", function(s) s.glyph:SetPoint("CENTER", 0, 0) end)
  return b
end
Style.GlyphButton = GlyphButton

-- Close button, centred in the title bar.
function Style.Close(f, onClick)
  local size = 18
  local close = GlyphButton(f, "close", size, Style.CLOSE_HI)
  local pad = (Style.TITLE_H - size) / 2 + 1
  close:SetPoint("TOPRIGHT", -pad, -pad)
  close:SetScript("OnClick", onClick or function() f:Hide() end)
  return close
end

-- Divider across the window, y pixels below the top.
function Style.Line(f, y)
  local t = f:CreateTexture(nil, "ARTWORK")
  t:SetPoint("TOPLEFT", 8, -y)
  t:SetPoint("TOPRIGHT", -8, -y)
  t:SetHeight(1)
  t:SetColorTexture(G[1], G[2], G[3], Style.LINE_A)
  return t
end

-- Small down arrow for dropdowns.
function Style.Arrow(parent)
  local a = parent:CreateTexture(nil, "OVERLAY")
  a:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
  a:SetSize(10, 10)
  a:SetRotation(-math.pi / 2)
  a:SetVertexColor(0.8, 0.8, 0.8)
  return a
end

-- Flat button: tinted background, brighter on hover. A template (e.g. the
-- secure action one) can be given; the look is the same.
function Style.Button(parent, w, text, onClick, template, name)
  local b = CreateFrame("Button", name, parent, template)
  b:SetSize(w, 20)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(G[1], G[2], G[3], 0.12)
  b.edge = b:CreateTexture(nil, "BORDER")
  b.edge:SetPoint("BOTTOMLEFT")
  b.edge:SetPoint("BOTTOMRIGHT")
  b.edge:SetHeight(1)
  b.edge:SetColorTexture(G[1], G[2], G[3], 0.4)
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("CENTER", 0, 0)
  b:SetFontString(fs)
  b:SetText(text or "")
  b:HookScript("OnEnter", function(s) s.bg:SetColorTexture(G[1], G[2], G[3], 0.24) end)
  b:HookScript("OnLeave", function(s) s.bg:SetColorTexture(G[1], G[2], G[3], 0.12) end)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

-- "Label: value v" dropdown: a faint box with a down arrow.
function Style.Dropdown(parent, w, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, 18)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(1, 1, 1, 0.07)
  b.arrow = Style.Arrow(b)
  b.arrow:SetPoint("RIGHT", -5, 0)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("RIGHT", b.arrow, "LEFT", -4, 0)
  b.text:SetJustifyH("RIGHT")
  b:SetScript("OnEnter", function(s) s.bg:SetColorTexture(1, 1, 1, 0.14) end)
  b:SetScript("OnLeave", function(s) s.bg:SetColorTexture(1, 1, 1, 0.07) end)
  b:SetScript("OnClick", onClick)
  return b
end

-- Slim scrollbar for a plain ScrollFrame: up / down glyph buttons, a
-- tinted track and a gold thumb sized to the visible part. Mouse wheel
-- scrolls; it hides when there's nothing to scroll.
local STEP = 40
function Style.ScrollBar(parent, scroll)
  local up = GlyphButton(parent, "arrow", 14)
  up:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
  local down = GlyphButton(parent, "arrow", 14)
  down:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
  down.glyph:SetTexCoord(0, 1, 1, 0) -- arrow pointing down

  local track = CreateFrame("Frame", nil, parent)
  track:SetPoint("TOP", up, "BOTTOM", 0, -3)
  track:SetPoint("BOTTOM", down, "TOP", 0, 3)
  track:SetWidth(6)
  local bg = track:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(G[1], G[2], G[3], 0.10)

  local bar = CreateFrame("Slider", nil, track)
  bar:SetAllPoints()
  bar:SetOrientation("VERTICAL")
  bar:SetMinMaxValues(0, 0)
  bar:SetValueStep(1)
  bar:SetObeyStepOnDrag(true)
  local thumb = bar:CreateTexture(nil, "OVERLAY")
  thumb:SetColorTexture(1, 1, 1, 1)
  thumb:SetVertexColor(unpack(Style.GLYPH))
  thumb:SetSize(6, 30)
  bar:SetThumbTexture(thumb)
  bar:SetScript("OnEnter", function() thumb:SetVertexColor(unpack(Style.GLYPH_HI)) end)
  bar:SetScript("OnLeave", function() thumb:SetVertexColor(unpack(Style.GLYPH)) end)

  local syncing = false
  bar:SetScript("OnValueChanged", function(_, v)
    if not syncing then scroll:SetVerticalScroll(v) end
  end)
  local function Range() return scroll:GetVerticalScrollRange() or 0 end
  local function Update()
    local range = Range()
    local shown = range > 0.5
    up:SetShown(shown); down:SetShown(shown); track:SetShown(shown)
    bar:SetMinMaxValues(0, range)
    local view = scroll:GetHeight() or 1
    local h = track:GetHeight() or 1
    thumb:SetHeight(math.max(20, h * view / (view + range)))
    syncing = true
    bar:SetValue(math.min(scroll:GetVerticalScroll() or 0, range))
    syncing = false
  end
  local function Scroll(delta)
    local v = math.max(0, math.min(Range(), (scroll:GetVerticalScroll() or 0) - delta * STEP))
    scroll:SetVerticalScroll(v)
  end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
  scroll:SetScript("OnScrollRangeChanged", Update)
  scroll:SetScript("OnVerticalScroll", function(s, offset)
    syncing = true
    bar:SetValue(offset)
    syncing = false
  end)
  scroll:HookScript("OnSizeChanged", Update)
  up:SetScript("OnClick", function() Scroll(1) end)
  down:SetScript("OnClick", function() Scroll(-1) end)
  Update()
  return { Update = Update, bar = bar }
end

------------------------------------------------------------------------
-- Menus (dropdowns and right-click menus) in the same look. Built like
-- Blizzard's MenuUtil: Style.Menu(owner, function(owner, root) ... end)
-- with root:CreateTitle / CreateButton / CreateCheckbox / CreateRadio /
-- CreateDivider. Opens below the owner, or at the cursor; a click outside
-- or Escape closes it.
------------------------------------------------------------------------
local MENU_ROW, MENU_DIV = 18, 7
local menu

local function MenuFrame()
  if menu then return menu end
  -- invisible full-screen catcher: a click anywhere else closes the menu
  local catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("FULLSCREEN_DIALOG")
  catcher:RegisterForClicks("AnyUp")
  catcher:Hide()
  local m = CreateFrame("Frame", "GoldCircuitMenu", UIParent, "BackdropTemplate")
  m:SetFrameStrata("FULLSCREEN_DIALOG")
  m:SetFrameLevel(catcher:GetFrameLevel() + 10)
  m:SetClampedToScreen(true)
  m:EnableMouse(true)
  Style.Window(m)
  m:Hide()
  m.rows, m.catcher = {}, catcher
  catcher:SetScript("OnClick", function() m:Hide() end)
  m:SetScript("OnHide", function() catcher:Hide() end)
  tinsert(UISpecialFrames, "GoldCircuitMenu") -- Escape closes it
  menu = m
  return m
end

local function MenuRow(m, i)
  local r = m.rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, m)
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(unpack(Style.HOVER))
  r.edge = r:CreateTexture(nil, "ARTWORK")      -- section edge on titles
  r.edge:SetPoint("TOPLEFT"); r.edge:SetPoint("BOTTOMLEFT"); r.edge:SetWidth(2)
  r.box = CreateFrame("Frame", nil, r, "BackdropTemplate")  -- checkbox / radio
  r.box:SetSize(10, 10)
  r.box:SetPoint("LEFT", 8, 0)
  r.box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  r.box:SetBackdropColor(0, 0, 0, 0.4)
  r.box:SetBackdropBorderColor(G[1], G[2], G[3], 0.8)
  r.mark = r.box:CreateTexture(nil, "OVERLAY")
  r.mark:SetColorTexture(1, 1, 1, 1)
  r.mark:SetVertexColor(unpack(Style.GLYPH_HI))
  r.line = r:CreateTexture(nil, "ARTWORK")      -- divider
  r.line:SetHeight(1)
  r.line:SetPoint("LEFT", 8, 0); r.line:SetPoint("RIGHT", -8, 0)
  r.line:SetColorTexture(G[1], G[2], G[3], Style.LINE_A)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.text:SetJustifyH("LEFT")
  r.text:SetWordWrap(false)
  r:SetScript("OnClick", function(self)
    m:Hide()
    if self.fn then self.fn() end
  end)
  m.rows[i] = r
  return r
end

function Style.Menu(owner, build, atCursor)
  local m = MenuFrame()
  local items = {}
  local root = {}
  function root:CreateTitle(t) items[#items + 1] = { kind = "title", text = t } end
  function root:CreateButton(t, fn) items[#items + 1] = { kind = "button", text = t, fn = fn } end
  function root:CreateCheckbox(t, get, set) items[#items + 1] = { kind = "check", text = t, get = get, fn = set } end
  function root:CreateRadio(t, get, set) items[#items + 1] = { kind = "radio", text = t, get = get, fn = set } end
  function root:CreateDivider() items[#items + 1] = { kind = "divider" } end
  build(owner, root)
  if #items == 0 then return end

  local y, width = 4, 120
  for i, it in ipairs(items) do
    local r = MenuRow(m, i)
    local h = it.kind == "divider" and MENU_DIV or MENU_ROW
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 1, -y)
    r:SetPoint("TOPRIGHT", -1, -y)
    r:SetHeight(h)
    local toggle = it.kind == "check" or it.kind == "radio"
    r.line:SetShown(it.kind == "divider")
    r.box:SetShown(toggle)
    r.edge:SetShown(it.kind == "title")
    r.text:SetShown(it.kind ~= "divider")
    r:EnableMouse(it.kind ~= "title" and it.kind ~= "divider")
    r.fn = it.fn
    r.text:ClearAllPoints()
    r.text:SetPoint("LEFT", toggle and 24 or 10, 0)
    if it.kind == "title" then
      r.bg:SetColorTexture(Style.SectionColors())
      r.edge:SetColorTexture(Style.ACCENT[1], Style.ACCENT[2], Style.ACCENT[3], 1)
      r.text:SetText(Style.SECTION_TEXT .. (it.text or "") .. "|r")
    else
      r.bg:SetColorTexture(0, 0, 0, 0)
      r.text:SetText(it.text or "")
    end
    if toggle then
      local on = it.get and it.get() and true or false
      r.mark:ClearAllPoints()
      r.mark:SetPoint("CENTER")
      r.mark:SetSize(it.kind == "radio" and 4 or 6, it.kind == "radio" and 4 or 6)
      r.mark:SetShown(on)
      r.box:SetBackdropBorderColor(G[1], G[2], G[3], on and 1 or 0.6)
    end
    if it.kind ~= "divider" then width = math.max(width, r.text:GetStringWidth() + (toggle and 36 or 22)) end
    r:Show()
    y = y + h
  end
  for i = #items + 1, #m.rows do m.rows[i]:Hide() end
  m:SetSize(width + 2, y + 4)

  m:ClearAllPoints()
  if atCursor or not owner then
    local scale = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale + 4, cy / scale - 4)
  else
    m:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
  end
  m.catcher:Show()
  m:Show()
end

-- Small glyph button with a tooltip (e.g. rescan: glyph "refresh").
function Style.IconButton(parent, glyph, tip, onClick)
  local b = GlyphButton(parent, glyph, 18)
  b:SetScript("OnClick", onClick)
  b:HookScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_TOP")
    GameTooltip:AddLine(tip, 1, 1, 1)
    GameTooltip:Show()
  end)
  b:HookScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

-- Section header colours (drawn by each window's own row code).
function Style.SectionColors()
  return G[1], G[2], G[3], Style.SECTION_A
end
