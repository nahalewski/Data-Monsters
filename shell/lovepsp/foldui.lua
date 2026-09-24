-- Launcher for Android foldables in the 3DS skin: the selected game's
-- cartridge fills the top screen, a tabbed panel (GAMES, MODS, FIND, ONLINE,
-- IMPORT) in the G1R Deluxe look the bottom screen.  It draws the shells and the bottom
-- panel into the runtime's overlay canvas and takes taps, the pad and the
-- sticks; the top screen is the launcher's own window, presented inside
-- the top frame's screen.  Everything behind the tabs is this port's own
-- functions: play / import a game, the mods list, installing mods from the
-- official index feed, the skin and theme options.
local M = {}

local lovepsp = love.lovepsp
local V = require("lovepsp.vitaui")
local SCREEN_W, PANEL_H = 480, 272
local TABS = { "GAMES", "MODS", "FIND", "ONLINE", "IMPORT" }
-- the port's own releases, for the update check
local RELEASES_API = "https://api.github.com/repos/nahalewski/gen1recomp-Fold/releases/latest"
local RELEASES_PAGE = "https://github.com/nahalewski/gen1recomp-Fold/releases/latest"

local state = {
  opts = nil, hud = nil, hudW = 0, hudH = 0,
  tab = 1, cursor = 1, scroll = 0, wasDown = false,
  feed = nil, feedRows = nil, feedStatus = nil, job = nil,
  update = nil, updateStatus = nil, updateJob = nil,
  prevButtons = 0, stick = {},
  carts = {}, base = 0, panel = { x = 0, y = 0, w = 0, h = 0 },
  message = nil, messageT = 0,
  modFilter = false, settings = nil, help = nil, setCursor = 1, setScroll = 0,
}

local function font(size) return state.opts.font(size) end
local function theme() return V.themeFor(state.opts.theme(), state.opts.version()) end

---------------------------------------------------------------- data

local function cart(version)
  if state.carts[version] == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/carts/" .. version .. ".png")
    state.carts[version] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return state.carts[version] or nil
end

local function modRows()
  local rows = {}
  for _, m in ipairs(state.opts.mods()) do rows[#rows + 1] = { kind = "mod", entry = m, label = m.name } end
  return rows
end


local function feedRows()
  if state.feedRows then return state.feedRows end
  if not state.feed then return {} end
  local installed = {}
  for _, m in ipairs(state.opts.mods()) do installed[m.id] = m end
  local rows = {}
  for _, e in ipairs(state.feed) do
    if type(e) == "table" and e.id and e.latest and type(e.latest.zip) == "table" and e.latest.zip.url then
      local have = installed[e.id]
      rows[#rows + 1] = { kind = "feed", entry = e, label = (e.title or e.id),
        version = e.latest.version or e.version or "", installed = have and have.version or nil }
    end
  end
  table.sort(rows, function(a, b) return a.label:lower() < b.label:lower() end)
  state.feedRows = rows
  return rows
end

local modsForFilter   -- defined with the MODS tab
local function rowsForTab()
  local t = TABS[state.tab]
  if t == "MODS" then return modsForFilter() end
  if t == "FIND" then return feedRows() end
  return {}
end

local function say(text)
  state.message, state.messageT = text, 4
end

---------------------------------------------------------------- actions

local function startFind()
  if state.job or state.feed then return end
  if not (lovepsp.network and lovepsp.network()) then state.feedStatus = "No network on this device" return end
  state.feedStatus = "Fetching the mod index..."
  state.job = coroutine.create(function()
    coroutine.yield()
    local feed, err = V.fetchFeed()
    if not feed then state.feedStatus = "Index: " .. tostring(err) return end
    state.feed = feed
    state.feedRows = nil
    state.feedStatus = ("%d mods in the index"):format(#feedRows())
  end)
end

local function installRow(row)
  if state.job or not row or row.kind ~= "feed" then return end
  state.feedStatus = "Installing " .. row.label .. "..."
  state.job = coroutine.create(function()
    coroutine.yield()
    local ok, err = V.installFromFeed(row.entry, row.entry.id, state.opts.token and state.opts.token())
    if ok then
      state.feedStatus = row.label .. " installed - enable it under MODS"
      state.feedRows = nil
      if state.opts.rescanMods then state.opts.rescanMods() end
    else
      state.feedStatus = "Install failed: " .. tostring(err):sub(1, 40)
    end
  end)
end

-- the port's update: the latest release of nahalewski/gen1recomp-Fold
local function checkUpdate()
  if state.updateJob then return end
  if not (lovepsp.network and lovepsp.network()) then state.updateStatus = "no network" return end
  state.updateStatus = "checking..."
  state.updateJob = coroutine.create(function()
    coroutine.yield()
    local Json = require("src.link.Json")
    local ok, err = lovepsp.http_get(RELEASES_API, "mods/.release.json", state.opts.token and state.opts.token())
    if not ok then
      state.updateStatus = tostring(err):find("22") and "no release yet" or ("check failed: " .. tostring(err):sub(1, 24))
      return
    end
    local raw = love.filesystem.read("mods/.release.json")
    love.filesystem.remove("mods/.release.json")
    local okj, rel = pcall(Json.decode, raw or "")
    if not okj or type(rel) ~= "table" or not rel.tag_name then state.updateStatus = "no release yet" return end
    local tag = tostring(rel.tag_name):gsub("^v", "")
    local mine = tostring(state.opts.portVersion or ""):gsub("^v", "")
    if tag ~= "" and tag ~= mine then
      state.update = { tag = tag, url = rel.html_url or RELEASES_PAGE }
      state.updateStatus = "update " .. tag .. " available"
    else
      state.update = nil
      state.updateStatus = "up to date (" .. mine .. ")"
    end
  end)
end

local function updateAction()
  if state.update then
    if not (lovepsp.openUrl and lovepsp.openUrl(state.update.url)) then say("Get it at " .. state.update.url) end
  else
    checkUpdate()
  end
end

local function activate(row)
  local t = TABS[state.tab]
  if t == "GAMES" then
    state.opts.primary()
  elseif row and row.kind == "mod" then
    state.opts.toggleMod(row.entry)
  elseif row and row.kind == "feed" then
    installRow(row)
  elseif t == "IMPORT" then
    state.opts.primary()
  end
end

local function setTab(i)
  state.tab = ((i - 1) % #TABS) + 1
  state.cursor, state.scroll = 1, 0
  if TABS[state.tab] == "FIND" then startFind() end
end

---------------------------------------------------------------- input

-- everything tappable registers a hit rectangle while it is drawn
local hits = {}
local function hit(x, y, w, h, fn) hits[#hits + 1] = { x = x, y = y, w = w, h = h, fn = fn } end

local ROW_H = 16
local function listRows() return math.max(1, math.floor((state.panel.h - 28 - 54 - 16 - 4) / ROW_H)) end
local function visibleRows() return listRows() end

local function clampScroll(n)
  local vis = visibleRows()
  if state.cursor < 1 then state.cursor = math.max(1, n) end
  if state.cursor > n then state.cursor = 1 end
  if state.cursor - 1 < state.scroll then state.scroll = state.cursor - 1 end
  if state.cursor > state.scroll + vis then state.scroll = state.cursor - vis end
  if state.scroll < 0 then state.scroll = 0 end
end

local REPEAT_FIRST, REPEAT_NEXT = 0.35, 0.12
local function stickStep(name, value, dt)
  local st = state.stick[name]
  if not st then st = { dir = 0, t = 0 } state.stick[name] = st end
  local dir = value < -0.5 and -1 or value > 0.5 and 1 or 0
  if dir == 0 then st.dir = 0 return 0 end
  if dir ~= st.dir then st.dir = dir st.t = REPEAT_FIRST return dir end
  st.t = st.t - dt
  if st.t <= 0 then st.t = REPEAT_NEXT return dir end
  return 0
end

-- the settings modal (the gear): the launcher's option rows with steppers
local SET_VIS = 4
local function optionRows() return state.opts.options and state.opts.options() or {} end
local function openSettings() state.settings = true state.setCursor, state.setScroll = 1, 0 end
local function closeSettings() state.settings = nil if state.opts.applyOptions then state.opts.applyOptions() end end
local function changeOption(i, dir)
  local row = optionRows()[i]
  if not row then return end
  row[3](dir)
  if state.opts.applyOptions then state.opts.applyOptions() end
end
local function setMove(d)
  local n = #optionRows()
  if n == 0 then return end
  state.setCursor = (state.setCursor - 1 + d) % n + 1
  if state.setCursor - 1 < state.setScroll then state.setScroll = state.setCursor - 1 end
  if state.setCursor > state.setScroll + SET_VIS then state.setScroll = state.setCursor - SET_VIS end
end

local function openPatchNotes()
  if not (lovepsp.openUrl and lovepsp.openUrl(RELEASES_PAGE)) then say("Patch notes: " .. RELEASES_PAGE) end
end

function M.press(button)
  if state.help then
    if button == "b" or button == "a" then state.help = nil end
    return true
  end
  if state.settings then
    if button == "b" then closeSettings() return true end
    if button == "dpup" then setMove(-1) return true end
    if button == "dpdown" then setMove(1) return true end
    if button == "dpleft" then changeOption(state.setCursor, -1) return true end
    if button == "dpright" then changeOption(state.setCursor, 1) return true end
    if button == "a" then changeOption(state.setCursor, 0) return true end
    return true
  end
  local rows = rowsForTab()
  if button == "leftshoulder" or button == "l" then setTab(state.tab - 1) return true end
  if button == "rightshoulder" or button == "r" then setTab(state.tab + 1) return true end
  if button == "start" then openSettings() return true end
  if TABS[state.tab] == "GAMES" or TABS[state.tab] == "IMPORT" or TABS[state.tab] == "ONLINE" then
    if button == "dpleft" then state.opts.moveGame(-1) return true end
    if button == "dpright" then state.opts.moveGame(1) return true end
    if button == "a" then activate() return true end
    if button == "y" then state.opts.rescan() return true end
  else
    if button == "dpup" then state.cursor = state.cursor - 1 clampScroll(#rows) return true end
    if button == "dpdown" then state.cursor = state.cursor + 1 clampScroll(#rows) return true end
    if button == "a" then activate(rows[state.cursor]) return true end
    if button == "y" and TABS[state.tab] == "MODS" then state.modFilter = not state.modFilter return true end
  end
  if button == "b" then setTab(1) return true end
  return false
end

-- taps: x, y in logical screen coordinates
local function tapAt(x, y)
  local p = state.panel
  if y < state.base then
    -- the top screen: the cartridge
    if TABS[state.tab] == "GAMES" and not state.settings and not state.help then state.opts.primary() end
    return
  end
  local lx, ly = x, y - state.base - p.y
  if lx < p.x or ly < 0 or lx >= p.x + p.w or ly >= p.h then return end
  for i = #hits, 1, -1 do
    local h = hits[i]
    if lx >= h.x and lx < h.x + h.w and ly >= h.y and ly < h.y + h.h then h.fn() return end
  end
  if state.help then state.help = nil end
end

local function controller(dt)
  local raw = lovepsp.rawInput
  local B = lovepsp.buttonBits
  if not raw or not B then return end
  local mv = stickStep("y", raw.ay or 0, dt)
  local mx = stickStep("x", raw.ax or 0, dt)
  if state.settings then
    if mv ~= 0 then setMove(mv) end
    if mx ~= 0 then changeOption(state.setCursor, mx) end
    return
  end
  local rows = rowsForTab()
  local t = TABS[state.tab]
  if mv ~= 0 and (t == "MODS" or t == "FIND") then state.cursor = state.cursor + mv clampScroll(#rows) end
  if mx ~= 0 and (t == "GAMES" or t == "IMPORT" or t == "ONLINE") then state.opts.moveGame(mx) end
end

---------------------------------------------------------------- drawing

-- the G1R Deluxe look: near-black navy, outlined rounded cards, blue
-- primary buttons, yellow badges; the theme tints the background and the
-- buttons.  The runtime's small font is an 8x8 bitmap (10 px lines), so
-- the panel (about 260 x 174 logical px) holds 32 characters a line.
local UI = {
  bg = { 0.07, 0.08, 0.11 }, card = { 0.10, 0.12, 0.16 }, line = { 1, 1, 1, 0.18 },
  text = { 0.94, 0.95, 0.97 }, dim = { 0.62, 0.65, 0.72 }, mute = { 0.42, 0.45, 0.52 },
  blue = { 0.13, 0.42, 0.75 }, yellow = { 0.98, 0.80, 0.10 }, green = { 0.45, 0.90, 0.55 },
  white = { 0.94, 0.95, 0.97 }, dark = { 0.07, 0.08, 0.11 },
}
local CART_COLOR = { red = { 0.90, 0.20, 0.22 }, blue = { 0.25, 0.45, 0.90 }, yellow = { 0.98, 0.80, 0.10 }, green = { 0.25, 0.70, 0.35 },
  gold = { 0.86, 0.66, 0.18 }, silver = { 0.75, 0.78, 0.83 }, crystal = { 0.35, 0.75, 0.90 }, firered = { 0.95, 0.36, 0.14 }, leafgreen = { 0.45, 0.80, 0.32 } }
local F = 8       -- the small font (any size below 18 is the same bitmap)
local CW, LH = 8, 10

local function rr(mode, x, y, w, h, r) love.graphics.rectangle(mode, x, y, w, h, r or 3, r or 3, 3) end
local function card(x, y, w, h, fill)
  love.graphics.setColor(fill or UI.card)
  rr("fill", x, y, w, h)
  love.graphics.setColor(UI.line)
  rr("line", x, y, w, h)
end
local function clip(text, n) text = tostring(text) return #text > n and text:sub(1, n - 1) .. "." or text end
local function label(text, x, y, color, w, align)
  love.graphics.setFont(font(F))
  love.graphics.setColor(color or UI.text)
  if w then love.graphics.printf(text, x, y, w, align or "left") else love.graphics.print(text, x, y) end
end
local function button(x, y, w, h, text, fill, textColor, fn, outline)
  love.graphics.setColor(fill)
  rr("fill", x, y, w, h)
  if outline then
    love.graphics.setColor(UI.line)
    rr("line", x, y, w, h)
  end
  label(text, x, y + math.floor((h - LH) / 2) + 1, textColor or UI.white, w, "center")
  if fn then hit(x, y, w, h, fn) end
end
local function badge(x, y, text, fill, color)
  local w = #text * CW + 6
  love.graphics.setColor(fill)
  rr("fill", x, y, w, LH, 3)
  label(text, x, y + 1, color or UI.dark, w, "center")
  return w
end

-- tiny line icons, drawn into a box at x, y of size s
local function icon(kind, x, y, s, color)
  love.graphics.setColor(color)
  love.graphics.setLineWidth(1.2)
  local c = s / 2
  if kind == "mods" then          -- puzzle piece: a square with two knobs
    love.graphics.rectangle("line", x + 3, y + 5, s - 8, s - 8)
    love.graphics.circle("fill", x + c - 1, y + 4.5, 2)
    love.graphics.circle("fill", x + s - 4.5, y + c + 1, 2)
  elseif kind == "find" then      -- magnifier
    love.graphics.circle("line", x + c - 1.5, y + c - 1.5, s / 3.4)
    love.graphics.line(x + c + 1, y + c + 1, x + s - 3, y + s - 3)
  elseif kind == "online" then    -- globe
    love.graphics.circle("line", x + c, y + c, s / 2.7)
    love.graphics.ellipse("line", x + c, y + c, s / 6.5, s / 2.7)
    love.graphics.line(x + c - s / 2.7, y + c, x + c + s / 2.7, y + c)
  elseif kind == "import" then    -- download arrow on a tray
    love.graphics.line(x + c, y + 3, x + c, y + s - 6)
    love.graphics.line(x + c - 3, y + s - 9, x + c, y + s - 6, x + c + 3, y + s - 9)
    love.graphics.line(x + 4, y + s - 3.5, x + s - 4, y + s - 3.5)
  elseif kind == "swap" then      -- two arrows
    love.graphics.line(x + 3, y + c - 2, x + s - 3, y + c - 2)
    love.graphics.line(x + s - 6, y + c - 5, x + s - 3, y + c - 2, x + s - 6, y + c + 1)
    love.graphics.line(x + 3, y + c + 3, x + s - 3, y + c + 3)
    love.graphics.line(x + 6, y + c, x + 3, y + c + 3, x + 6, y + c + 6)
  elseif kind == "gear" then      -- ring with teeth
    love.graphics.circle("line", x + c, y + c, s / 4.2)
    for i = 0, 7 do
      local a = i * math.pi / 4
      love.graphics.line(x + c + math.cos(a) * s / 3.4, y + c + math.sin(a) * s / 3.4, x + c + math.cos(a) * s / 2.4, y + c + math.sin(a) * s / 2.4)
    end
  elseif kind == "close" then
    love.graphics.line(x + 4, y + 4, x + s - 4, y + s - 4)
    love.graphics.line(x + s - 4, y + 4, x + 4, y + s - 4)
  end
  love.graphics.setLineWidth(1)
end

local function drawHeader(p)
  -- the logo: G1R in yellow with a blue edge, then the port's name
  love.graphics.setFont(font(F))
  for dx = -1, 1 do for dy = -1, 1 do
    love.graphics.setColor(0.18, 0.30, 0.55, 1)
    love.graphics.print("G1R", p.x + 7 + dx, 5 + dy)
  end end
  love.graphics.setColor(UI.yellow)
  love.graphics.print("G1R", p.x + 7, 5)
  label("Ports", p.x + 7 + 3 * CW + 4, 5, UI.white)
  -- swap game / settings / close
  local bx = p.x + p.w - 6 - 3 * 20 + 2
  local kinds = { { "swap", function() state.opts.moveGame(1) end }, { "gear", openSettings },
                  { "close", function() love.event.quit() end } }
  for i, k in ipairs(kinds) do
    local x = bx + (i - 1) * 20
    card(x, 3, 18, 15)
    icon(k[1], x + 2, 3, 14, UI.text)
    hit(x - 1, 2, 20, 17, k[2])
  end
end

local TAB_ICON = { GAMES = "games", MODS = "mods", FIND = "find", ONLINE = "online", IMPORT = "import" }
local TAB_Y, TAB_H = 21, 17
local function tabWidth(name) return #name * CW + 4 end
local function drawTabs(p)
  local total = -4
  for _, name in ipairs(TABS) do total = total + tabWidth(name) + 4 end
  local x = p.x + math.floor((p.w - total) / 2)
  local g = state.opts.game()
  for i, name in ipairs(TABS) do
    local sel = i == state.tab
    local w = tabWidth(name)
    -- the icon box: white when selected
    love.graphics.setColor(sel and UI.white or UI.card)
    rr("fill", x, TAB_Y, w, TAB_H)
    love.graphics.setColor(name == "GAMES" and (CART_COLOR[g.version] or UI.line) or UI.line)
    rr("line", x, TAB_Y, w, TAB_H)
    if name == "GAMES" then
      label(g.name:gsub("^Pokemon ", ""):sub(1, 1), x + 8, TAB_Y + 4, CART_COLOR[g.version] or UI.text)
      love.graphics.setColor(sel and UI.dark or UI.text)
      love.graphics.polygon("fill", x + w - 15, TAB_Y + 6, x + w - 5, TAB_Y + 6, x + w - 10, TAB_Y + 11)
    else
      icon(TAB_ICON[name], x + math.floor(w / 2) - 8, TAB_Y + 1, 16, sel and UI.dark or UI.text)
    end
    if name == "ONLINE" then badge(x + w - 26, TAB_Y + 9, "N/A", UI.yellow) end
    label(name, x - 2, TAB_Y + TAB_H + 2, sel and UI.white or UI.dim, w + 4, "center")
    hit(x - 2, TAB_Y - 1, w + 4, TAB_H + 14, function() setTab(i) end)
    x = x + w + 4
  end
  love.graphics.setColor(UI.line)
  love.graphics.line(p.x, TAB_Y + TAB_H + 13, p.x + p.w, TAB_Y + TAB_H + 13)
end
local BODY_Y = TAB_Y + TAB_H + 16     -- 54
local FOOT_H = 28
local function bodyH(p) return p.h - FOOT_H - BODY_Y end

local function drawFooter(p)
  local y = p.h - FOOT_H + 2
  love.graphics.setColor(UI.line)
  love.graphics.line(p.x, y - 2, p.x + p.w, y - 2)
  -- the upstream credit chip, the update button and the release notes
  local x = p.x + 6
  button(x, y, 76, 13, "BOIS CLUB", { 0, 0, 0, 1 }, UI.white, function()
    if lovepsp.openUrl then lovepsp.openUrl("https://github.com/bryanthaboi/gen1recomp") end
  end)
  local st = state.updateStatus or ""
  local ul = state.update and ("Update v" .. clip(state.update.tag, 5))
    or (st:find("no release") and "No release" or st:find("up to date") and "Up to date" or st:find("check") and "Checking"
        or st:find("network") and "Offline" or st ~= "" and "Retry" or "Updates")
  button(x + 80, y, 88, 13, ul, state.update and UI.yellow or UI.card, state.update and UI.dark or UI.text, updateAction, not state.update)
  button(x + 172, y, p.w - 12 - 172, 13, "Notes", UI.card, UI.text, openPatchNotes, true)
  label(clip("Ported by nahalewski " .. (state.opts.portVersion and state.opts.portVersion ~= "" and ("v" .. state.opts.portVersion) or ""), 32), p.x + 4, p.h - LH - 2, UI.mute, p.w - 8, "center")
end

local function drawGamesTab(p)
  local g = state.opts.game()
  local y = BODY_Y
  card(p.x + 6, y, p.w - 12, 36)
  label(clip(g.name, 22), p.x + 12, y + 3, UI.text)
  local st, sc = g.ready and { "Ready to play", UI.green } or g.rom and { "ROM found - import it", UI.yellow } or { "No ROM found", { 0.90, 0.35, 0.35 } }
  label(st[1], p.x + 12, y + 13, st[2])
  label(g.save and "Save found - CONTINUE" or "No save yet", p.x + 12, y + 23, UI.dim)
  button(p.x + p.w - 68, y + 9, 56, 18, g.ready and "Play" or g.rom and "Import" or "No ROM",
    g.ready and UI.blue or g.rom and UI.yellow or UI.mute, g.rom and not g.ready and UI.dark or UI.white, state.opts.primary)
  y = y + 42
  button(p.x + 6, y, 14, 13, "<", UI.card, UI.text, function() state.opts.moveGame(-1) end, true)
  card(p.x + 22, y, 100, 13)
  label(clip(g.name:gsub("^Pokemon ", ""), 12), p.x + 22, y + 2, UI.text, 100, "center")
  button(p.x + 124, y, 14, 13, ">", UI.card, UI.text, function() state.opts.moveGame(1) end, true)
  button(p.x + p.w - 70, y, 64, 13, "Rescan", UI.card, UI.text, state.opts.rescan, true)
  y = y + 17
  label(g.ready and "Tap the cart or press X to play." or g.rom and "Tap Import to build the game." or "Put the ROM next to the app.", p.x + 6, y + 2, UI.dim, p.w - 12, "center")
end

modsForFilter = function()
  local rows = modRows()
  if not state.modFilter then return rows end
  local v = state.opts.game().version
  local out = {}
  for _, r in ipairs(rows) do
    local games = r.entry.games
    local ok = type(games) ~= "table" or #games == 0
    if not ok then for _, gv in ipairs(games) do if gv == v then ok = true end end end
    if ok then out[#out + 1] = r end
  end
  return out
end

local function drawRows(p, y, h, rows, kind)
  card(p.x + 6, y, p.w - 12, h)
  local vis = math.max(1, math.floor((h - 4) / ROW_H))
  if #rows == 0 then
    local text = kind == "mod" and "No mods installed.\nInstall one from FIND, or copy\na mod into mods/ via USB."
      or (state.feedStatus or "")
    label(text, p.x + 12, y + math.floor(h / 2) - 15, UI.dim, p.w - 24, "center")
    return
  end
  if state.scroll > math.max(0, #rows - vis) then state.scroll = math.max(0, #rows - vis) end
  local ry = y + 2
  local more = #rows > vis
  local rw = p.w - 16 - (more and 14 or 0)
  for i = state.scroll + 1, math.min(#rows, state.scroll + vis) do
    local row = rows[i]
    local sel = i == state.cursor
    if sel then
      love.graphics.setColor(1, 1, 1, 0.08)
      rr("fill", p.x + 8, ry, rw, ROW_H - 1, 2)
    end
    if kind == "mod" then
      local on = row.entry.enabled
      love.graphics.setColor(on and UI.blue or UI.mute)
      rr("fill", p.x + 12, ry + 4, 16, 8, 4)
      love.graphics.setColor(UI.white)
      love.graphics.circle("fill", on and p.x + 24 or p.x + 16, ry + 8, 3)
      label(clip(row.label, 18), p.x + 34, ry + 3, UI.text)
      label(clip("v" .. tostring(row.entry.version or ""), 6), p.x + 8 + rw - 52, ry + 3, UI.dim, 48, "right")
    else
      label(clip(row.label, 16), p.x + 12, ry + 3, UI.text)
      local tag = row.installed and (row.installed == row.version and "Installed" or "Update") or "Install"
      local fill = row.installed == row.version and UI.card or UI.blue
      button(p.x + 8 + rw - 80, ry + 1, 76, ROW_H - 3, tag, fill, UI.white, nil, fill == UI.card)
    end
    hit(p.x + 8, ry, rw, ROW_H, function() state.cursor = i activate(row) end)
    ry = ry + ROW_H
  end
  -- scroll arrows on the right edge
  if more then
    button(p.x + p.w - 18, y + 2, 10, 12, "^", UI.card, UI.text, function() state.scroll = math.max(0, state.scroll - vis) end, true)
    button(p.x + p.w - 18, y + h - 14, 10, 12, "v", UI.card, UI.text, function() state.scroll = math.min(math.max(0, #rows - vis), state.scroll + vis) end, true)
  end
end

local function drawModsTab(p)
  local y = BODY_Y
  local g = state.opts.game()
  label("Show:", p.x + 6, y + 2, UI.dim)
  button(p.x + 48, y, 32, 13, "All", state.modFilter and UI.card or UI.white, state.modFilter and UI.text or UI.dark, function() state.modFilter = false end, state.modFilter)
  button(p.x + 84, y, 76, 13, clip(g.name:gsub("^Pokemon ", ""), 9), state.modFilter and UI.white or UI.card, state.modFilter and UI.dark or UI.text, function() state.modFilter = true end, not state.modFilter)
  button(p.x + p.w - 70, y, 64, 13, "Rescan", UI.blue, UI.white, state.opts.rescanMods)
  local rows = modsForFilter()
  y = y + 16
  drawRows(p, y, bodyH(p) - 16, rows, "mod")
end

local function drawFindTab(p)
  local y = BODY_Y
  local rows = feedRows()
  if #rows == 0 then
    local h = bodyH(p)
    card(p.x + 6, y, p.w - 12, h)
    local net = lovepsp.network and lovepsp.network()
    label(net and (state.job and "Fetching the index" or "Mod index") or "No network", p.x + 12, y + 4, UI.text, p.w - 24, "center")
    label(net and (state.feedStatus or "The official mod index lists\nmods you can install from\ntheir authors' releases.")
      or "Connect to the internet\nto browse the mod index.", p.x + 12, y + 16, UI.dim, p.w - 24, "center")
    if net and not state.job then
      button(p.x + math.floor(p.w / 2) - 44, y + h - 18, 88, 14, "Fetch", UI.blue, UI.white, function() state.feed = nil state.feedRows = nil startFind() end)
    end
    return
  end
  label(clip(state.feedStatus or "", 32), p.x + 6, y, UI.dim, p.w - 12, "center")
  drawRows(p, y + 12, bodyH(p) - 12, rows, "feed")
end

local function drawOnlineTab(p)
  local y = BODY_Y
  card(p.x + 6, y, p.w - 12, 36)
  label("Display name", p.x + 12, y + 3, UI.dim)
  label(state.opts.trainer and state.opts.trainer() or "PLAYER", p.x + 12, y + 14, UI.text)
  badge(p.x + 12, y + 24, "OFFLINE", UI.bg, UI.dim)
  button(p.x + p.w - 76, y + 10, 64, 16, "Connect", UI.mute, UI.dark)
  y = y + 40
  local cards = { "Play", "Watch", "Trade" }
  local ch = math.floor((bodyH(p) - 40) / 3)
  for _, c in ipairs(cards) do
    card(p.x + 6, y, p.w - 12, ch - 3)
    label(c, p.x + 12, y + math.floor((ch - 3 - LH) / 2) + 1, UI.mute)
    label("desktop build only", p.x + 12, y + math.floor((ch - 3 - LH) / 2) + 1, UI.mute, p.w - 24, "right")
    y = y + ch
  end
end

local function drawImportTab(p)
  local g = state.opts.game()
  local y = BODY_Y
  card(p.x + 6, y, p.w - 12, 48)
  label(clip(g.name, 20), p.x + 12, y + 3, UI.text)
  badge(p.x + 12 + math.min(#g.name, 20) * CW + 4, y + 3, "ROM", UI.bg, UI.dim)
  label(g.ready and "Imported" or g.rom and clip("Found: " .. g.rom, 30) or "No ROM found", p.x + 12, y + 14, g.ready and UI.green or g.rom and UI.yellow or { 0.90, 0.35, 0.35 })
  label("Put the ROM next to the app.", p.x + 12, y + 24, UI.dim)
  button(p.x + 12, y + 34, 88, 12, g.ready and "Imported" or g.rom and "Import" or "No ROM", g.rom and not g.ready and UI.blue or UI.mute, UI.white, state.opts.primary)
  y = y + 52
  card(p.x + 6, y, p.w - 12, bodyH(p) - 52)
  label("Mods", p.x + 12, y + 3, UI.text)
  button(p.x + p.w - 60, y + 2, 48, 12, "Scan", UI.card, UI.text, state.opts.rescanMods, true)
  label("mods/ next to the ROM, or FIND", p.x + 12, y + 15, UI.dim)
end

local function drawSettings(p)
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", p.x, 0, p.w, p.h)
  local x, y, w, h = p.x + 4, 4, p.w - 8, p.h - 8
  card(x, y, w, h)
  hit(x, y, w, h, function() end)
  label("Settings", x + 8, y + 4, UI.text)
  label("saved automatically", x + 8 + 9 * CW, y + 4, UI.dim)
  card(x + w - 24, y + 3, 18, 15)
  icon("close", x + w - 22, y + 3, 14, UI.text)
  hit(x + w - 26, y + 1, 24, 19, closeSettings)
  local rows = optionRows()
  local rh = 25
  local ry = y + 20
  for i = state.setScroll + 1, math.min(#rows, state.setScroll + SET_VIS) do
    local row = rows[i]
    local sel = i == state.setCursor
    card(x + 4, ry, w - 8, rh - 2, sel and { 0.14, 0.17, 0.23 } or UI.card)
    label(clip(row[1], 30), x + 8, ry + 2, sel and UI.text or UI.dim)
    button(x + 8, ry + 12, 14, 10, "<", UI.card, UI.text, function() state.setCursor = i changeOption(i, -1) end, true)
    label(clip(row[2](), 24), x + 22, ry + 12, UI.text, w - 44, "center")
    button(x + w - 22, ry + 12, 14, 10, ">", UI.card, UI.text, function() state.setCursor = i changeOption(i, 1) end, true)
    ry = ry + rh
  end
  local fy = y + h - 17
  if #rows > SET_VIS then
    button(x + 4, fy, 20, 13, "^", UI.card, UI.text, function() setMove(-SET_VIS) end, true)
    button(x + 26, fy, 20, 13, "v", UI.card, UI.text, function() setMove(SET_VIS) end, true)
  end
  button(x + 52, fy, 96, 13, "Instructions", UI.card, UI.text, function() state.help = true end, true)
  button(x + w - 56, fy, 52, 13, "Done", UI.blue, UI.white, closeSettings)
end

local HELP = {
  "L / R, or tap: switch tabs",
  "Stick / D-pad: move",
  "X (A): play, import, toggle a",
  "  mod, install from FIND",
  "O (B): back to GAMES",
  "START or the gear: settings",
  "Left / right: change the game",
  "Y on MODS: all games / this game",
  "Open the phone flat for one",
  "  screen; fold it for the DS",
}
local function drawHelp(p)
  love.graphics.setColor(0, 0, 0, 0.7)
  love.graphics.rectangle("fill", p.x, 0, p.w, p.h)
  local x, y, w, h = p.x + 4, 4, p.w - 8, p.h - 8
  card(x, y, w, h)
  label("Instructions", x + 8, y + 4, UI.text)
  local ly = y + 18
  for _, line in ipairs(HELP) do
    label(line, x + 8, ly, UI.text)
    ly = ly + LH + 2
  end
  button(x + w - 56, y + h - 17, 52, 13, "Done", UI.blue, UI.white, function() state.help = nil end)
  hit(x, y, w, h, function() end)
end

local function drawPanel()
  local p = state.panel
  local t = theme()
  hits = {}
  -- the theme tints the background; the panel keeps the Deluxe navy
  love.graphics.setColor(t.bg[1] * 0.5 + UI.bg[1] * 0.5, t.bg[2] * 0.5 + UI.bg[2] * 0.5, t.bg[3] * 0.5 + UI.bg[3] * 0.5, 1)
  love.graphics.rectangle("fill", p.x, 0, p.w, p.h)
  UI.blue = { t.accent[1] * 0.5 + 0.13 * 0.5, t.accent[2] * 0.5 + 0.42 * 0.5, t.accent[3] * 0.5 + 0.75 * 0.5 }
  drawHeader(p)
  drawTabs(p)
  local tab = TABS[state.tab]
  if tab == "GAMES" then drawGamesTab(p)
  elseif tab == "MODS" then drawModsTab(p)
  elseif tab == "FIND" then drawFindTab(p)
  elseif tab == "ONLINE" then drawOnlineTab(p)
  elseif tab == "IMPORT" then drawImportTab(p) end
  drawFooter(p)
  if state.settings then drawSettings(p) end
  if state.help then drawHelp(p) end
  if state.message then
    love.graphics.setColor(0, 0, 0, 0.8)
    rr("fill", p.x + 10, math.floor(p.h / 2) - 12, p.w - 20, 24)
    label(clip(state.message, 30), p.x + 12, math.floor(p.h / 2) - 5, UI.white, p.w - 24, "center")
  end
end

local function render()
  local sw, sh = lovepsp.screen()
  if not state.hud or state.hudW ~= sw or state.hudH ~= sh then
    state.hud = love.graphics.newCanvas(sw, sh)
    state.hudW, state.hudH = sw, sh
  end
  love.graphics.push("all")
  love.graphics.setCanvas(state.hud)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("alpha")
  local skin = state.opts.skin()
  local top = V.SKIN_TOP[skin]
  local img = top and V.skinImage(top.file)
  if img then
    local ox, sc = V.framePlacement(img)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, ox, 0, 0, sc, sc)
  end
  img = V.skinImage(V.SKIN_BOTTOM.file)
  if img then
    local ox, sc = V.framePlacement(img)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, ox, state.base, 0, sc, sc)
    -- the shell's button sprites (unpressed)
    local sheet = V.skinImage(V.SKIN_BOTTOM.sheet)
    if sheet then
      local shw, shh = sheet:getDimensions()
      for _, b in ipairs(V.SKIN_BOTTOM.buttons) do
        b.quad = b.quad or love.graphics.newQuad(b.sprite[1], b.sprite[2], b.sprite[3], b.sprite[4], shw, shh)
        local target = b.r * 2 * sc
        local qw, qh = b.sprite[3], b.sprite[4]
        local scale = (b.wide and (target * 2 / qw)) or (target / math.max(qw, qh))
        love.graphics.draw(sheet, b.quad, ox + b.x * sc - qw * scale / 2, state.base + b.y * sc - qh * scale / 2, 0, scale, scale)
      end
    end
  end
  love.graphics.translate(0, state.base + state.panel.y)
  drawPanel()
  love.graphics.setCanvas()
  love.graphics.pop()
  lovepsp.setOverlay(state.hud)
end

---------------------------------------------------------------- public

function M.attach(opts)
  state.opts = opts
  state.tab, state.cursor, state.scroll = 1, 1, 0
end

-- the top screen: the selected game's cartridge on a themed glow
function M.drawTop()
  local t = theme()
  local g = state.opts.game()
  love.graphics.clear(0.03, 0.03, 0.04, 1)
  local img = cart(g.version)
  if img then
    local iw, ih = img:getDimensions()
    local s = math.max(SCREEN_W / iw, PANEL_H / ih)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, (SCREEN_W - iw * s) / 2, (PANEL_H - ih * s) / 2, 0, s, s)
  else
    love.graphics.setColor(t.accent)
    love.graphics.rectangle("fill", 170, 40, 140, 190)
    love.graphics.setColor(t.title)
    love.graphics.setFont(font(14))
    love.graphics.printf(g.name, 170, 120, 140, "center")
  end
  love.graphics.setColor(1, 1, 1, 0.85)
  love.graphics.setFont(font(20))
  love.graphics.print("<", 12, 122)
  love.graphics.print(">", SCREEN_W - 26, 122)
  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", 0, PANEL_H - 22, SCREEN_W, 22)
  love.graphics.setColor(0.85, 0.85, 0.9, 1)
  love.graphics.setFont(font(6))
  love.graphics.printf("Based on the Pokemon Gen 1 Recompilation Project\nby BOIS CLUB GAMES, LLC - github.com/bryanthaboi/gen1recomp", 0, PANEL_H - 19, SCREEN_W, "center")
end

function M.update(dt)
  if not state.opts then return end
  local skin = state.opts.skin()
  local top = V.SKIN_TOP[skin]
  -- halves take the frames' heights (same as the in-game skin)
  if lovepsp.layout and top then
    lovepsp.layout(nil, V.frameHeight(top.file), V.frameHeight(V.SKIN_BOTTOM.file))
  end
  local topH = lovepsp.split()
  state.base = topH
  -- the bottom screen is the panel
  local bimg = V.skinImage(V.SKIN_BOTTOM.file)
  if bimg then
    local ox, sc = V.framePlacement(bimg)
    local c = V.SKIN_BOTTOM.cut
    state.panel = { x = ox + c[1] * sc, y = c[2] * sc, w = c[3] * sc, h = c[4] * sc }
  end
  -- the launcher window sits in the top screen
  local timg = top and V.skinImage(top.file)
  if timg and lovepsp.gameRect then
    local ox, sc = V.framePlacement(timg)
    local c = top.cut
    local cx, cy, cw, ch = ox + c[1] * sc, c[2] * sc, c[3] * sc, c[4] * sc
    local s = math.min(cw / SCREEN_W, ch / PANEL_H)
    local w, h = math.floor(SCREEN_W * s), math.floor(PANEL_H * s)
    lovepsp.gameRect(math.floor(cx + (cw - w) / 2), math.floor(cy + (ch - h) / 2), w, h)
  end
  if lovepsp.touchPad then lovepsp.touchPad(false) end
  -- input
  local ok, touches = pcall(lovepsp.touches)
  local t = ok and touches and touches[1]
  if t and not state.wasDown then tapAt(t.x, t.y) end
  state.wasDown = t ~= nil and t ~= false
  controller(dt)
  if state.job then
    local okr, err = coroutine.resume(state.job)
    if not okr then state.feedStatus = "Error: " .. tostring(err):sub(1, 40) end
    if coroutine.status(state.job) == "dead" then state.job = nil end
  end
  if state.updateJob then
    local okr, err = coroutine.resume(state.updateJob)
    if not okr then state.updateStatus = "error" end
    if coroutine.status(state.updateJob) == "dead" then state.updateJob = nil end
  end
  if not state.updateStatus and not state.updateJob then checkUpdate() end
  if state.message then
    state.messageT = state.messageT - dt
    if state.messageT <= 0 then state.message = nil end
  end
  render()
end

function M.detach()
  if lovepsp.setOverlay then lovepsp.setOverlay(nil) end
  if lovepsp.gameRect then lovepsp.gameRect() end
end

M.say = say
-- the touch that opened the lid must not also tap the panel
function M.swallowTouch() state.wasDown = true end
return M
