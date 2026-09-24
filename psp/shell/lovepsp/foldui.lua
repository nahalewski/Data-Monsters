-- Launcher for Android foldables in the 3DS skin: the selected game's
-- cartridge fills the top screen, a tabbed panel (GAMES, MODS, FIND, ONLINE,
-- SKINS, IMPORT) the bottom screen.  It draws the shells and the bottom
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

local function rowsForTab()
  local t = TABS[state.tab]
  if t == "MODS" then return modRows() end
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

local ROW_H = 18
local function visibleRows() return math.max(1, math.floor((state.panel.h - 60) / ROW_H)) end

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

function M.press(button)
  local rows = rowsForTab()
  if button == "leftshoulder" or button == "l" then setTab(state.tab - 1) return true end
  if button == "rightshoulder" or button == "r" then setTab(state.tab + 1) return true end
  if TABS[state.tab] == "GAMES" or TABS[state.tab] == "IMPORT" then
    if button == "dpleft" then state.opts.moveGame(-1) return true end
    if button == "dpright" then state.opts.moveGame(1) return true end
    if button == "a" then activate() return true end
    if button == "y" then state.opts.rescan() return true end
  else
    if button == "dpup" then state.cursor = state.cursor - 1 clampScroll(#rows) return true end
    if button == "dpdown" then state.cursor = state.cursor + 1 clampScroll(#rows) return true end
    if button == "a" then activate(rows[state.cursor]) return true end
  end
  if button == "b" then setTab(1) return true end
  return false
end

-- taps: x, y in logical screen coordinates
local function tapAt(x, y)
  local p = state.panel
  if y < state.base then
    -- the top screen: the cartridge
    if TABS[state.tab] == "GAMES" then state.opts.primary() end
    return
  end
  local lx, ly = x - p.x, y - state.base - p.y
  if lx < 0 or ly < 0 or lx >= p.w or ly >= p.h then return end
  -- tab bar
  if ly < 30 then
    local i = math.floor(lx / (p.w / #TABS)) + 1
    if TABS[i] then setTab(i) end
    return
  end
  local t = TABS[state.tab]
  if t == "GAMES" then
    if ly >= 56 and ly < 76 then state.opts.primary() return end
    if ly >= 30 and ly < 56 then
      if lx < p.w * 0.25 then state.opts.moveGame(-1) elseif lx > p.w * 0.75 then state.opts.moveGame(1) end
      return
    end
    if ly >= p.h - 24 then
      if lx < p.w / 2 then updateAction() else state.opts.rescan() end
      return
    end
  elseif t == "IMPORT" then
    if ly >= p.h - 44 and ly < p.h - 22 then state.opts.primary() return end
    if ly >= p.h - 22 then state.opts.rescan() return end
  elseif t == "ONLINE" then
    return
  else
    local rows = rowsForTab()
    if ly >= p.h - 22 then
      if lx < 40 then state.scroll = math.max(0, state.scroll - visibleRows())
      elseif lx < 80 then state.scroll = math.min(math.max(0, #rows - visibleRows()), state.scroll + visibleRows()) end
      return
    end
    local i = math.floor((ly - 34) / ROW_H) + 1 + state.scroll
    if rows[i] then
      state.cursor = i
      activate(rows[i])
    end
  end
end

local function controller(dt)
  local raw = lovepsp.rawInput
  local B = lovepsp.buttonBits
  if not raw or not B then return end
  local rows = rowsForTab()
  local mv = stickStep("y", raw.ay or 0, dt)
  if mv ~= 0 and TABS[state.tab] ~= "GAMES" then state.cursor = state.cursor + mv clampScroll(#rows) end
  local mx = stickStep("x", raw.ax or 0, dt)
  if mx ~= 0 and (TABS[state.tab] == "GAMES" or TABS[state.tab] == "IMPORT") then state.opts.moveGame(mx) end
end

---------------------------------------------------------------- drawing

local function button(x, y, w, h, label, fill, textColor, size)
  love.graphics.setColor(fill)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(textColor or { 1, 1, 1, 1 })
  love.graphics.setFont(font(size or 9))
  love.graphics.printf(label, x, y + (h - (size or 9)) / 2 - 1, w, "center")
end

local function drawTabs(p, t)
  local tw = p.w / #TABS
  for i, name in ipairs(TABS) do
    local x = p.x + (i - 1) * tw
    local sel = i == state.tab
    love.graphics.setColor(sel and t.accent or { t.text[1], t.text[2], t.text[3], 0.10 })
    love.graphics.rectangle("fill", x + 2, 3, tw - 4, 24)
    love.graphics.setColor(sel and t.title or t.text)
    love.graphics.setFont(font(6))
    love.graphics.printf(name, x, 14, tw, "center")
    -- a little glyph above the label
    local g = ({ "[]", "*", "?", "@", "v" })[i]
    love.graphics.printf(g, x, 5, tw, "center")
    if name == "ONLINE" then
      love.graphics.setColor(0.95, 0.8, 0.2, 1)
      love.graphics.rectangle("fill", x + tw - 22, 4, 20, 6)
      love.graphics.setColor(0, 0, 0, 1)
      love.graphics.setFont(font(5))
      love.graphics.printf("N/A", x + tw - 22, 4, 20, "center")
    end
  end
end

local function drawGamesTab(p, t)
  local g = state.opts.game()
  local short = g.name:gsub("^Pokemon ", "")
  love.graphics.setColor(t.text)
  love.graphics.setFont(font(14))
  love.graphics.print(short:sub(1, 9), p.x + 14, 33)
  local badge, bc
  if g.ready then badge, bc = "Ready", { 0.3, 0.85, 0.45, 1 }
  elseif g.rom then badge, bc = "Import", { 0.95, 0.8, 0.2, 1 }
  else badge, bc = "No ROM", { 0.85, 0.3, 0.3, 1 } end
  love.graphics.setColor(bc)
  love.graphics.rectangle("line", p.x + 96, 35, 56, 13)
  love.graphics.setFont(font(7))
  love.graphics.printf(badge, p.x + 96, 38, 56, "center")
  love.graphics.setColor(t.dim)
  love.graphics.setFont(font(6))
  love.graphics.print(g.ready and "(PRESS THE CART TO PLAY)" or g.rom and "(PRESS THE CART TO IMPORT)" or "(PUT THE ROM NEXT TO THE APP)", p.x + 14, 50)
  love.graphics.setFont(font(9))
  love.graphics.print("<", p.x + 3, 36)
  love.graphics.print(">", p.x + p.w - 10, 36)
  button(p.x + 8, 60, p.w - 16, 16, g.ready and "PLAY" or g.rom and "IMPORT ROM" or "NO ROM FOUND",
    g.ready and { 0.2, 0.45, 0.9, 1 } or g.rom and { 0.95, 0.8, 0.2, 1 } or { 0.35, 0.35, 0.4, 1 },
    g.rom and not g.ready and { 0, 0, 0, 1 } or nil, 9)
  -- SAVE box
  love.graphics.setColor(t.text[1], t.text[2], t.text[3], 0.08)
  love.graphics.rectangle("fill", p.x + 8, 80, p.w - 16, 44)
  love.graphics.setColor(t.text)
  love.graphics.setFont(font(9))
  love.graphics.print("SAVE", p.x + 14, 83)
  love.graphics.setFont(font(6))
  love.graphics.setColor(t.dim)
  love.graphics.print(g.save and "Save found: CONTINUE on the title screen" or "No saves yet - start a new game", p.x + 14, 96)
  button(p.x + 14, 106, p.w - 28, 13, g.save and ("SAVE: " .. g.save) or "+ NEW GAME (title screen)", g.save and { 0.3, 0.75, 0.45, 1 } or { 0.25, 0.6, 0.4, 1 }, { 0, 0, 0, 1 }, 6)
  -- footer: version, update, rescan (the credit line is on the top screen)
  love.graphics.setColor(t.dim)
  love.graphics.setFont(font(5))
  love.graphics.printf("Ported by nahalewski  -  " .. (state.opts.versionLabel or ""), p.x + 6, p.h - 30, p.w - 12, "center")
  local st = state.updateStatus or ""
  local ul = state.update and ("UPDATE " .. state.update.tag)
    or (st:find("no release") and "NO RELEASE YET" or st:find("up to date") and "UP TO DATE" or st:find("check") and "CHECKING..."
        or st:find("network") and "NO NETWORK" or st ~= "" and "CHECK FAILED" or "CHECK UPDATES")
  button(p.x + 8, p.h - 20, p.w / 2 - 12, 14, ul, state.update and { 0.95, 0.8, 0.2, 1 } or { t.text[1], t.text[2], t.text[3], 0.15 }, state.update and { 0, 0, 0, 1 } or t.text, 6)
  button(p.x + p.w / 2 + 4, p.h - 20, p.w / 2 - 12, 14, "RESCAN ROMS", { t.text[1], t.text[2], t.text[3], 0.15 }, t.text, 6)
end

local function drawList(p, t, rows, kind)
  local vis = visibleRows()
  local y = 34
  love.graphics.setFont(font(8))
  for i = state.scroll + 1, math.min(#rows, state.scroll + vis) do
    local row = rows[i]
    local sel = i == state.cursor
    love.graphics.setColor(t.text[1], t.text[2], t.text[3], sel and 0.16 or 0.06)
    love.graphics.rectangle("fill", p.x + 6, y, p.w - 12, ROW_H - 2)
    if sel then
      love.graphics.setColor(t.accent)
      love.graphics.rectangle("fill", p.x + 6, y, 3, ROW_H - 2)
    end
    if kind == "mod" then
      local on = row.entry.enabled
      love.graphics.setColor(on and t.accent or t.dim)
      love.graphics.rectangle("fill", p.x + 12, y + 3, 18, 10)
      love.graphics.setColor(on and t.title or t.bg)
      love.graphics.rectangle("fill", on and p.x + 22 or p.x + 14, y + 5, 6, 6)
      love.graphics.setColor(t.text)
      love.graphics.setFont(font(7))
      love.graphics.print(tostring(row.label):sub(1, 26), p.x + 36, y + 5)
      love.graphics.setColor(t.dim)
      love.graphics.setFont(font(6))
      love.graphics.print("v" .. tostring(row.entry.version or ""), p.x + p.w - 60, y + 6)
      love.graphics.setFont(font(8))
    elseif kind == "feed" then
      love.graphics.setColor(t.text)
      love.graphics.setFont(font(7))
      love.graphics.print(tostring(row.label):sub(1, 22), p.x + 12, y + 5)
      local tag = row.installed and (row.installed == row.version and "INSTALLED" or "UPDATE " .. row.version) or "INSTALL " .. row.version
      love.graphics.setColor(row.installed == row.version and t.dim or t.accent)
      love.graphics.setFont(font(6))
      love.graphics.printf(tag, p.x + p.w - 86, y + 6, 78, "right")
      love.graphics.setFont(font(8))
    else
      love.graphics.setColor(t.text)
      love.graphics.print(row.label, p.x + 12, y + 1)
      love.graphics.setColor(t.dim)
      love.graphics.setFont(font(6))
      love.graphics.print(tostring(row.row[2]()):sub(1, 44), p.x + 12, y + 10)
      love.graphics.setFont(font(8))
    end
    y = y + ROW_H
  end
  -- strip
  button(p.x + 6, p.h - 20, 32, 14, "UP", { t.text[1], t.text[2], t.text[3], 0.15 }, t.text, 7)
  button(p.x + 42, p.h - 20, 32, 14, "DN", { t.text[1], t.text[2], t.text[3], 0.15 }, t.text, 7)
  love.graphics.setColor(t.dim)
  love.graphics.setFont(font(6))
  local note = kind == "feed" and (state.feedStatus or "") or kind == "mod" and ("%d mods - X toggles"):format(#rows) or "X changes a setting"
  love.graphics.printf(note, p.x + 80, p.h - 16, p.w - 86, "left")
end

local function drawPanel()
  local p = state.panel
  local t = theme()
  love.graphics.setColor(t.bg[1], t.bg[2], t.bg[3], 1)
  love.graphics.rectangle("fill", p.x, 0, p.w, p.h)
  drawTabs(p, t)
  local tab = TABS[state.tab]
  if tab == "GAMES" then drawGamesTab(p, t)
  elseif tab == "MODS" then drawList(p, t, modRows(), "mod")
  elseif tab == "FIND" then
    local rows = feedRows()
    if #rows == 0 then
      love.graphics.setColor(t.text)
      love.graphics.setFont(font(8))
      love.graphics.printf(state.feedStatus or "", p.x + 10, 60, p.w - 20, "center")
    else
      drawList(p, t, rows, "feed")
    end
  elseif tab == "ONLINE" then
    love.graphics.setColor(t.text)
    love.graphics.setFont(font(9))
    love.graphics.printf("Online play is not part of this port.\n\nThe engine's Gen1Online / link features need the desktop build.", p.x + 12, 50, p.w - 24, "center")
  elseif tab == "IMPORT" then
    local g = state.opts.game()
    love.graphics.setColor(t.text)
    love.graphics.setFont(font(9))
    love.graphics.printf("Put your own US cartridge dump in\n" .. (state.opts.romDir or "the app's files folder") .. "\n(or roms/ under it), any file name.", p.x + 10, 36, p.w - 20, "center")
    love.graphics.setFont(font(8))
    love.graphics.setColor(t.dim)
    love.graphics.printf(g.name .. ": " .. (g.ready and "imported, ready to play" or g.rom and ("ROM found: " .. g.rom) or "no ROM found"), p.x + 10, 90, p.w - 20, "center")
    button(p.x + 8, p.h - 44, p.w - 16, 18, g.ready and "ALREADY IMPORTED" or g.rom and ("IMPORT " .. g.name:upper()) or "NO ROM TO IMPORT",
      g.rom and not g.ready and { 0.95, 0.8, 0.2, 1 } or { 0.35, 0.35, 0.4, 1 }, g.rom and not g.ready and { 0, 0, 0, 1 } or nil, 9)
    button(p.x + 8, p.h - 20, p.w - 16, 14, "RESCAN", { t.text[1], t.text[2], t.text[3], 0.15 }, t.text, 7)
  end
  if state.message then
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", p.x + 10, p.h / 2 - 10, p.w - 20, 20)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(8))
    love.graphics.printf(state.message, p.x + 12, p.h / 2 - 5, p.w - 24, "center")
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
return M
