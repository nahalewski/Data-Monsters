-- Touch UI for a running game (Vita, Android, any touch build).
--
-- Two floating buttons appear at the edges when the screen is touched; the
-- left one slides in a MODS panel (enable / disable, update from GitHub,
-- apply with a restart), the right one a menu that replaces the game's
-- START menu -- POKeMON, ITEM, the trainer card, SAVE, GAME OPTION, this
-- port's OPTIONS, MODS and QUIT (back to the launcher).  While a panel is
-- open the game shrinks between the panels and keeps running under the
-- physical controls.
--
-- In the DS layout (lovepsp.layout("ds"): a double-height logical screen,
-- the game in the top half) the bottom half is the control surface: the
-- touch pad, two labelled buttons, and a panel takes that whole half when
-- open -- the second screen of a dual-screen or folded phone.
--
-- The panels are drawn into a screen-sized canvas that the runtime
-- composites over the presented frame (lovepsp.setOverlay), so the game's
-- 160x144 canvas and its renderer are untouched.  Gen 1 menu rows reuse the
-- engine's own START menu items (src/ui/StartMenu.lua) and therefore also
-- carry rows added by mods; Gen 2 keeps its own START menu (opened from the
-- panel) because its rows are bound to that screen's state machine.
local M = {}

local lovepsp = love.lovepsp
local SCREEN_W, PANEL_H = 480, 272
local SIDE_W = 150
local ROW_H = 24
local CIRCLE_R = 13
local CIRCLE_Y = 30
local SHOW_SECONDS = 4
local FEED = "https://bryanthaboi.github.io/gen1recomp-mod-index/data/index.json"

local state -- the panel state table, defined below the themes

-- Themes: the panels' colours in the style of each game's box art / Game
-- Boy, drawn like a Game Boy text box (double-line border, square rows,
-- the runtime's pixel font).  "auto" follows the game being played.
local THEMES = {
  { id = "auto", name = "AUTO (match the game)" },
  { id = "gameboy", name = "GAME BOY", accent = { 0.55, 0.67, 0.06 }, bg = { 0.06, 0.22, 0.06 }, text = { 0.88, 0.97, 0.60 }, title = { 0.06, 0.22, 0.06 }, dim = { 0.60, 0.72, 0.35 } },
  { id = "red", name = "RED", accent = { 0.86, 0.18, 0.18 }, bg = { 0.14, 0.04, 0.04 }, text = { 1, 0.92, 0.88 }, title = { 1, 1, 1 }, dim = { 0.80, 0.55, 0.55 } },
  { id = "green", name = "GREEN", accent = { 0.18, 0.62, 0.30 }, bg = { 0.03, 0.12, 0.06 }, text = { 0.90, 1, 0.90 }, title = { 1, 1, 1 }, dim = { 0.55, 0.78, 0.60 } },
  { id = "blue", name = "BLUE", accent = { 0.22, 0.42, 0.88 }, bg = { 0.04, 0.06, 0.16 }, text = { 0.90, 0.94, 1 }, title = { 1, 1, 1 }, dim = { 0.60, 0.68, 0.90 } },
  { id = "yellow", name = "YELLOW", accent = { 0.96, 0.80, 0.16 }, bg = { 0.16, 0.13, 0.03 }, text = { 1, 0.97, 0.85 }, title = { 0.16, 0.13, 0.03 }, dim = { 0.85, 0.78, 0.50 } },
  { id = "gold", name = "GOLD", accent = { 0.86, 0.66, 0.18 }, bg = { 0.15, 0.11, 0.03 }, text = { 1, 0.96, 0.85 }, title = { 0.15, 0.11, 0.03 }, dim = { 0.82, 0.72, 0.50 } },
  { id = "silver", name = "SILVER", accent = { 0.72, 0.75, 0.80 }, bg = { 0.10, 0.11, 0.13 }, text = { 0.95, 0.96, 1 }, title = { 0.10, 0.11, 0.13 }, dim = { 0.65, 0.68, 0.74 } },
  { id = "crystal", name = "CRYSTAL", accent = { 0.32, 0.74, 0.90 }, bg = { 0.03, 0.10, 0.16 }, text = { 0.90, 0.98, 1 }, title = { 0.03, 0.10, 0.16 }, dim = { 0.55, 0.78, 0.88 } },
  { id = "firered", name = "FIRERED", accent = { 0.95, 0.36, 0.14 }, bg = { 0.16, 0.06, 0.02 }, text = { 1, 0.94, 0.88 }, title = { 1, 1, 1 }, dim = { 0.85, 0.60, 0.48 } },
  { id = "leafgreen", name = "LEAFGREEN", accent = { 0.45, 0.80, 0.32 }, bg = { 0.05, 0.14, 0.04 }, text = { 0.92, 1, 0.90 }, title = { 0.05, 0.14, 0.04 }, dim = { 0.62, 0.82, 0.55 } },
}
local THEME_BY_ID = {}
for _, t in ipairs(THEMES) do THEME_BY_ID[t.id] = t end

local ACCENT = { 0.25, 0.55, 1.0 }
local PANEL_BG = { 0.09, 0.10, 0.14, 0.94 }

local function currentTheme()
  local id = state.opts and state.opts.theme and state.opts.theme() or "auto"
  if id == "auto" then
    local v = state.opts and state.opts.version or nil
    id = (v and THEME_BY_ID[v]) and v or "gameboy"
  end
  local t = THEME_BY_ID[id] or THEME_BY_ID.gameboy
  ACCENT[1], ACCENT[2], ACCENT[3] = t.accent[1], t.accent[2], t.accent[3]
  PANEL_BG[1], PANEL_BG[2], PANEL_BG[3] = t.bg[1], t.bg[2], t.bg[3]
  return t
end

function M.themeFor(id, version)
  if id == "auto" or id == nil then id = (version and THEME_BY_ID[version]) and version or "gameboy" end
  return THEME_BY_ID[id] or THEME_BY_ID.gameboy
end
M.THEMES = THEMES

local function cycleTheme()
  local id = state.opts.theme and state.opts.theme() or "auto"
  local idx = 1
  for i, t in ipairs(THEMES) do if t.id == id then idx = i end end
  local nxt = THEMES[idx % #THEMES + 1]
  if state.opts.setTheme then state.opts.setTheme(nxt.id) end
end

state = {
  game = nil, opts = nil, attached = false,
  left = false, right = false, rightPage = "menu",
  circleTimer = 0, hud = nil, hudW = 0, hudH = 0, wasDown = false,
  rows = {}, modRows = {}, modScroll = 0, modsChanged = false,
  passthrough = false, message = nil, messageTimer = 0,
  progress = nil, updater = nil,
  sw = SCREEN_W, sh = PANEL_H, ds = false, base = 0,
  leftPage = "mods", leftCursor = 1, rightCursor = 1,
  prevButtons = 0, stick = {}, -- controller edge/repeat state
  skin = nil, held = 0, homeDown = false, -- skin: active top frame, injected buttons
  rightScroll = 0,
  panelY = 0, panelH = PANEL_H, -- panel area inside the bottom half
}

local HELP = {
  "CONTROLLER (Vita, Razer Kishi, any pad)",
  "START: open/close the MENU panel.",
  "SELECT: open/close this MODS panel.",
  "Right stick: move in MENU. R1 select, R2 back.",
  "Left stick: move in MODS. L1 select, L2 back.",
  "D-pad, X, O: the game keeps playing.",
  "Select+R / Select+L: screen mode.",
  "TOUCH: tap a row; tap X to close; tap the MODS / MENU buttons after touching the game.",
}

-- 3DS skin (shell/assets/skin3ds, the player's art): frames drawn around
-- the two halves of the DS layout; the game sits in the top frame's screen
-- cutout, the panels in the bottom one's, and the frame's own buttons are
-- the touch controls.  Source-pixel geometry of the half-size images.
local SKIN_TOP = {
  gbc = { file = "top_gbc.png", cut = { 159, 98, 419, 232 } }, -- sticker + Game Boy Color border (default)
  sticker = { file = "top_sticker.png", cut = { 113, 74, 519, 277 } },
  plain = { file = "top_plain.png", cut = { 109, 66, 471, 267 } },
  small = { file = "top_small.png", cut = { 205, 80, 281, 239 } },
}
-- bottom shell without buttons (bottom_empty.png) plus the button sprites
-- cut from the sheet (buttons.png, half size): each sprite is drawn into its
-- socket and pressed ones are drawn darker and nudged, like a real press.
-- cut = the screen area; sockets in half-size source pixels of the shell.
local SKIN_BOTTOM = {
  file = "bottom_empty.png", cut = { 159, 79, 378, 252 },
  sheet = "buttons.png",
  buttons = {
    -- name, socket centre x/y, socket radius (hit + draw size), sprite rect in the sheet, kind or pad bits
    { name = "stick", x = 68, y = 134, r = 50, sprite = { 270, 228, 181, 182 }, kind = "dpad" },
    { name = "pad", x = 68, y = 249, r = 48, sprite = { 37, 228, 184, 186 }, kind = "dpad" },
    { name = "x", x = 620, y = 126, r = 21, sprite = { 381, 57, 133, 134 }, bits = "cross" },
    { name = "y", x = 583, y = 164, r = 21, sprite = { 560, 58, 133, 133 }, bits = "circle" },
    { name = "a", x = 656, y = 164, r = 21, sprite = { 35, 58, 132, 133 }, bits = "cross" },
    { name = "b", x = 620, y = 201, r = 21, sprite = { 209, 58, 132, 133 }, bits = "circle" },
    { name = "start", x = 586, y = 271, r = 14, sprite = { 515, 256, 62, 62 }, bits = "start" },
    { name = "select", x = 586, y = 316, r = 14, sprite = { 515, 340, 62, 63 }, bits = "select" },
    { name = "home", x = 342, y = 365, r = 25, sprite = { 288, 427, 144, 86 }, kind = "menu", wide = true },
  },
}
local skinImages = {}
local function skinImage(file)
  if skinImages[file] == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/skin3ds/" .. file)
    skinImages[file] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return skinImages[file] or nil
end

-- a frame fills the width of its half: the two shells meet at the hinge
-- like a real 3DS (the art is trimmed to its shells: top 480x280, bottom 480x273)
local function framePlacement(img)
  local iw = img:getDimensions()
  local sc = SCREEN_W / iw
  return 0, sc
end

local function frameHeight(file)
  local img = skinImage(file)
  if not img then return PANEL_H end
  local _, ih = img:getDimensions()
  local _, sc = framePlacement(img)
  return math.floor(ih * sc + 0.5)
end

---------------------------------------------------------------- HD overlay
-- The logical frame is 480 px wide (the PSP's), so on a phone the shell
-- and the menus would be blown up four times.  The overlay canvas can be
-- an integer multiple of the frame instead: the runtime blends it over the
-- frame at the display's resolution.  The shell art then comes from the
-- full-size copies in assets/skin3ds/hd and text from a TrueType font.
local hdK = 1
local function hudScale()
  if not lovepsp.display then return 1 end
  local ok, dw = pcall(lovepsp.display)
  if not ok or not dw or dw <= 0 then return 1 end
  return math.max(1, math.min(3, math.floor(dw / SCREEN_W)))
end
M.hudScale = hudScale

-- the two halves fill the display: the hinge is its middle line
local function fullSplit()
  if not lovepsp.display then return nil end
  local ok, dw, dh = pcall(lovepsp.display)
  if not ok or not dw or dw <= 0 or not dh or dh <= 0 then return nil end
  local lh = math.floor(SCREEN_W * dh / dw + 0.5)
  if lh < 2 * 64 or lh > 720 then return nil end
  local top = math.floor(lh / 2)
  return top, lh - top
end
M.fullSplit = fullSplit

-- the frames, placed: the top frame's bottom edge sits on the hinge (a
-- shorter half crops the frame's top), the bottom frame hangs from it
local function placeTop(skin, topH)
  local top = SKIN_TOP[skin]
  local img = top and skinImage(top.file)
  if not img then return nil end
  local ox, sc = framePlacement(img)
  local _, ih = img:getDimensions()
  local y0 = 0
  if fullSplit() and topH then y0 = topH - math.floor(ih * sc + 0.5) end
  return ox, sc, y0, img, top
end
local function placeBottom()
  local img = skinImage(SKIN_BOTTOM.file)
  if not img then return nil end
  local ox, sc = framePlacement(img)
  return ox, sc, 0, img
end
M.placeTop, M.placeBottom = placeTop, placeBottom

local hdImages = {}
local function skinImageHD(file)
  if hdImages[file] == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/skin3ds/hd/" .. file)
    hdImages[file] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return hdImages[file] or nil
end
-- draws a skin file at x, y with the half-size scale sc, from the HD copy
-- when the overlay is scaled
local function drawSkin(file, x, y, sc)
  local img = skinImage(file)
  if not img then return end
  local hd = hdK > 1 and skinImageHD(file)
  love.graphics.setColor(1, 1, 1, 1)
  if hd then
    love.graphics.draw(hd, x, y, 0, sc * img:getWidth() / hd:getWidth())
  else
    love.graphics.draw(img, x, y, 0, sc, sc)
  end
end
M.drawSkin = drawSkin
-- a sprite from the button sheet (rect in half-size sheet pixels)
local function drawSprite(x, y, rect, scale, tint)
  local sheet = skinImage(SKIN_BOTTOM.sheet)
  if not sheet then return end
  local hd = hdK > 1 and skinImageHD(SKIN_BOTTOM.sheet)
  local img, f = sheet, 1
  if hd then img, f = hd, hd:getWidth() / sheet:getWidth() end
  local w, h = img:getDimensions()
  rect.hdq = rect.hdq or {}
  local q = rect.hdq[f]
  if not q then
    q = love.graphics.newQuad(rect[1] * f, rect[2] * f, rect[3] * f, rect[4] * f, w, h)
    rect.hdq[f] = q
  end
  love.graphics.setColor(tint or { 1, 1, 1, 1 })
  love.graphics.draw(img, q, x, y, 0, scale / f, scale / f)
end
M.drawSprite = drawSprite

-- text: the bitmap font below size 18 is one 8x8 face; on a scaled
-- overlay the same calls draw a TrueType face at the display's resolution
local realPrint, realPrintf = love.graphics.print, love.graphics.printf
local ttfFonts = {}
local function ttf(px)
  if ttfFonts[px] == nil then
    local ok, f = pcall(love.graphics.newFont, "assets/fonts/Vera.ttf", px)
    ttfFonts[px] = ok and f or false
  end
  return ttfFonts[px] or nil
end
local function hdPx(size) return (size >= 18 and size or 9) * hdK end
local function hdPrint(text, x, y, r, sx, sy)
  local f = ttf(hdPx(M.curFontSize or 8))
  if not f then return realPrint(text, x, y, r, sx, sy) end
  local bmp = love.graphics.getFont()
  love.graphics.setFont(f)
  love.graphics.push()
  love.graphics.scale(1 / hdK, 1 / hdK)
  realPrint(text, (x or 0) * hdK, (y or 0) * hdK, r or 0, sx or 1, sy or sx or 1)
  love.graphics.pop()
  love.graphics.setFont(bmp)
end
local function hdPrintf(text, x, y, limit, align)
  local f = ttf(hdPx(M.curFontSize or 8))
  if not f then return realPrintf(text, x, y, limit, align) end
  local bmp = love.graphics.getFont()
  love.graphics.setFont(f)
  love.graphics.push()
  love.graphics.scale(1 / hdK, 1 / hdK)
  realPrintf(text, (x or 0) * hdK, (y or 0) * hdK, (limit or SCREEN_W) * hdK, align)
  love.graphics.pop()
  love.graphics.setFont(bmp)
end
-- begin / end a scaled overlay pass: the caller has set its canvas
function M.hdBegin(k)
  hdK = k or 1
  if hdK > 1 then
    love.graphics.scale(hdK, hdK)
    love.graphics.print, love.graphics.printf = hdPrint, hdPrintf
  end
end
function M.hdEnd()
  love.graphics.print, love.graphics.printf = realPrint, realPrintf
  hdK = 1
end
-- an overlay canvas of the screen at the HD scale (recreated on change)
function M.hdCanvas(holder, sw, sh, k)
  if not holder.hud or holder.hudW ~= sw * k or holder.hudH ~= sh * k then
    holder.hud = love.graphics.newCanvas(sw * k, sh * k)
    holder.hudW, holder.hudH = sw * k, sh * k
  end
  return holder.hud
end

local function font(size) M.curFontSize = size return state.opts.font(size) end
local visibleRows -- rows that fit a panel (defined with the input code below)
local function log(msg) if state.opts.log then state.opts.log(msg) end end

-- geometry of the two panels for the current layout
local function panelRect(side)
  if state.ds and state.skin then
    local ox, sc = placeBottom()
    if ox then
      local c = SKIN_BOTTOM.cut
      return ox + c[1] * sc, c[3] * sc
    end
  end
  if state.ds then return 0, SCREEN_W end
  if side == "left" then return 0, SIDE_W end
  return SCREEN_W - SIDE_W, SIDE_W
end

---------------------------------------------------------------- rows

local function ascii(label)
  return (tostring(label):gsub("[\194-\244][\128-\191]*", "e"))
end

local function buildMenuRows()
  local game, opts = state.game, state.opts
  local rows = {}
  local Strings = require("src.core.Strings")
  local function push(label, action, keep)
    rows[#rows + 1] = { label = ascii(label), action = action, keep = keep }
  end
  if opts.generation == 1 then
    local ok, menu = pcall(function() return require("src.ui.StartMenu").new(game) end)
    if ok and menu and menu.items then
      local optionLabel, modsLabel, quitLabel = Strings("OPTION"), Strings("MODS"), Strings("QUIT")
      for _, item in ipairs(menu.items) do
        if item.label == optionLabel then
          push("GAME OPTION", function() item.onSelect() end)
        elseif item.label == modsLabel or item.label == quitLabel then
          -- replaced by the panel's own rows below
        else
          push(item.label, function() item.onSelect() end)
        end
      end
    else
      log("vitaui: start menu items unavailable: " .. tostring(menu))
    end
  else
    push("START MENU", function()
      state.passthrough = true
      local Screens = require("src.ui.Screens")
      pcall(Screens.push, game, "StartMenu")
      state.passthrough = false
    end)
  end
  push("OPTIONS", function() state.rightPage = "options" state.rightCursor = 1 state.rightScroll = 0 end, true)
  push("MODS", function() M.openLeft() end, true)
  push("QUIT", function() state.rightPage = "quit" end, true)
  return rows
end

local function buildOptionRows()
  local rows = {}
  for _, row in ipairs(state.opts.optionRows or {}) do
    rows[#rows + 1] = {
      label = row[1], value = row[2], action = function()
        row[3](0)
        if state.opts.applyOptions then state.opts.applyOptions() end
      end, keep = true }
  end
  rows[#rows + 1] = { label = "< BACK", action = function() state.rightPage = "menu" state.rightCursor = 1 state.rightScroll = 0 end, keep = true }
  return rows
end

local startUpdate -- defined with the updater below

local function buildModRows()
  local rows = {}
  local status = state.game and state.game.modStatus
  local byId = {}
  for _, m in ipairs(status and status.available or {}) do byId[m.id] = m end
  local list = state.opts.mods and state.opts.mods() or {}
  for _, entry in ipairs(list) do
    local m = byId[entry.id]
    rows[#rows + 1] = {
      entry = entry,
      label = entry.name or entry.id,
      state = m and (m.error and "error" or m.state) or nil,
      error = m and m.error and tostring(m.error) or nil,
    }
  end
  -- actions at the bottom of the list, reachable with the stick as well
  if lovepsp.network and lovepsp.network() then
    rows[#rows + 1] = { action = "update", label = "UPDATE FROM GITHUB" }
  end
  rows[#rows + 1] = { action = "apply", label = "APPLY (RESTART THE GAME)" }
  rows[#rows + 1] = { action = "theme", label = "THEME" }
  rows[#rows + 1] = { action = "help", label = "INSTRUCTIONS" }
  return rows
end

local function activateModRow(row)
  if not row then return end
  if row.action == "update" then startUpdate()
  elseif row.action == "apply" then
    if state.modsChanged and state.opts.restart then state.opts.restart(state.opts.version)
    else state.progress = "Nothing changed yet" end
  elseif row.action == "help" then state.leftPage = "help"
  elseif row.action == "theme" then cycleTheme()
  elseif row.entry and state.opts.toggleMod then
    state.opts.toggleMod(row.entry)
    state.modsChanged = true
  end
end

---------------------------------------------------------------- updater

local function removeTree(path)
  if state.opts.removeTree then return state.opts.removeTree(path) end
end

local function findManifestDir(root, wantId, depth)
  local raw = love.filesystem.read(root .. "/manifest.json")
  if raw then
    local ok, Json = pcall(require, "src.link.Json")
    if ok then
      local okd, m = pcall(Json.decode, raw)
      if okd and type(m) == "table" and (not wantId or m.id == wantId) then return root end
    end
  end
  if depth <= 0 then return nil end
  for _, item in ipairs(love.filesystem.getDirectoryItems(root)) do
    local sub = root .. "/" .. item
    if love.filesystem.getInfo(sub, "directory") then
      local found = findManifestDir(sub, wantId, depth - 1)
      if found then return found end
    end
  end
end

-- fetch the mod index feed -> table of entries, or nil, err
function M.fetchFeed()
  local Json = require("src.link.Json")
  local feedUrl = (love._env and love._env.LOVEPSP_MOD_FEED) or FEED
  local ok, err = lovepsp.http_get(feedUrl, "mods/.index.json")
  if not ok then return nil, tostring(err) end
  local raw = love.filesystem.read("mods/.index.json")
  love.filesystem.remove("mods/.index.json")
  local okj, feed = pcall(Json.decode, raw or "")
  if not okj or type(feed) ~= "table" then return nil, "bad JSON" end
  return feed.mods or feed
end

-- download a feed entry's latest zip and install it as mods/<dir>; returns ok, err
function M.installFromFeed(entry, dir, token)
  local latest = entry and entry.latest
  local url = latest and type(latest.zip) == "table" and latest.zip.url
  if not url then return false, "no release zip" end
  removeTree("mods/.update")
  love.filesystem.remove("mods/.dl.zip")
  local okd, derr = lovepsp.http_get(url, "mods/.dl.zip", token)
  if not okd then return false, tostring(derr) end
  local n, uerr = lovepsp.unzip("mods/.dl.zip", "mods/.update")
  love.filesystem.remove("mods/.dl.zip")
  if not n then removeTree("mods/.update") return false, tostring(uerr) end
  local found = findManifestDir("mods/.update", entry.id, 3)
  if not found then removeTree("mods/.update") return false, "no manifest for " .. tostring(entry.id) end
  removeTree("mods/" .. dir)
  local okm = lovepsp.rename(found, "mods/" .. dir)
  removeTree("mods/.update")
  if not okm then return false, "cannot move into place" end
  if state.opts and state.opts.invalidateMods then state.opts.invalidateMods() end
  return true
end

-- one mod per resume: the panel redraws its progress line between steps
local function updateAll()
  local Json = require("src.link.Json")
  local feedUrl = (love._env and love._env.LOVEPSP_MOD_FEED) or FEED
  local token = state.opts.token and state.opts.token() or nil
  state.progress = "Fetching mod index..."
  coroutine.yield()
  local ok, err = lovepsp.http_get(feedUrl, "mods/.index.json")
  if not ok then state.progress = "Index: " .. tostring(err):sub(1, 40) return end
  local raw = love.filesystem.read("mods/.index.json")
  local okj, feed = pcall(Json.decode, raw or "")
  love.filesystem.remove("mods/.index.json")
  if not okj or type(feed) ~= "table" then state.progress = "Index: bad JSON" return end
  local byId = {}
  for _, m in ipairs(feed.mods or feed) do if type(m) == "table" and m.id then byId[m.id] = m end end
  local todo = {}
  for _, row in ipairs(state.modRows) do
    local f = byId[row.entry.id]
    local latest = f and f.latest
    if latest and type(latest.zip) == "table" and latest.zip.url and latest.version
        and latest.version ~= row.entry.version then
      todo[#todo + 1] = { entry = row.entry, url = latest.zip.url, version = latest.version }
    end
  end
  if #todo == 0 then state.progress = "All mods are up to date" return end
  local updated, failed = 0, 0
  for i, t in ipairs(todo) do
    state.progress = ("Updating %s %s (%d/%d)"):format(t.entry.name:sub(1, 14), t.version, i, #todo)
    coroutine.yield()
    removeTree("mods/.update")
    love.filesystem.remove("mods/.dl.zip")
    local okd, derr = lovepsp.http_get(t.url, "mods/.dl.zip", token)
    local why
    if okd then
      local n, uerr = lovepsp.unzip("mods/.dl.zip", "mods/.update")
      log(("mod update %s: unzip -> %s files %s"):format(t.entry.id, tostring(n), tostring(uerr or "")))
      if n then
        local dir = findManifestDir("mods/.update", t.entry.id, 3)
        if dir then
          local dest = "mods/" .. (t.entry.dir or t.entry.id)
          removeTree(dest)
          if lovepsp.rename(dir, dest) then updated = updated + 1 else why = "cannot move into place" end
        else
          why = "no manifest for " .. t.entry.id .. " in the zip"
        end
      else
        why = uerr
      end
    else
      why = derr
    end
    if why then
      failed = failed + 1
      log(("mod update %s: %s"):format(t.entry.id, tostring(why)))
    end
    love.filesystem.remove("mods/.dl.zip")
    removeTree("mods/.update")
  end
  if state.opts.invalidateMods then state.opts.invalidateMods() end
  state.modRows = buildModRows()
  state.modsChanged = state.modsChanged or updated > 0
  state.progress = ("%d updated, %d failed"):format(updated, failed)
end

startUpdate = function()
  if state.updater then return end
  if not (lovepsp.network and lovepsp.network() and lovepsp.http_get) then
    state.progress = "No network on this console"
    return
  end
  state.updater = coroutine.create(function()
    local ok, err = pcall(updateAll)
    if not ok then state.progress = "Update failed" log("mod update: " .. tostring(err)) end
  end)
end

---------------------------------------------------------------- panels

local function openRight()
  if state.ds then state.left = false end
  state.right = true
  state.rightPage = "menu"
  state.rows = buildMenuRows()
  state.rightCursor = 1
  state.rightScroll = 0
end

local function rightRows()
  return state.rightPage == "options" and buildOptionRows() or state.rows
end

local function clampRightScroll()
  local visible = visibleRows()
  local n = #rightRows()
  if state.rightCursor > n then state.rightCursor = math.max(1, n) end
  if state.rightCursor - 1 < state.rightScroll then state.rightScroll = state.rightCursor - 1 end
  if state.rightCursor > state.rightScroll + visible then state.rightScroll = state.rightCursor - visible end
  if state.rightScroll < 0 then state.rightScroll = 0 end
end

local function closeRight()
  state.right = false
  state.rightPage = "menu"
end

function M.openLeft()
  if state.ds then closeRight() end
  state.left = true
  state.leftPage = "mods"
  state.modRows = buildModRows()
  state.modScroll = 0
  state.leftCursor = 1
end

local function closeLeft()
  state.left = false
  state.leftPage = "mods"
end

local function applyBars()
  if state.ds then
    -- bars do not move the game in the DS layout, but 0,0 hides the pad
    -- while a panel covers the bottom half
    if lovepsp.setBars then
      if state.left or state.right then lovepsp.setBars(0, 0) else lovepsp.setBars(-1, -1) end
    end
    return
  end
  local l = state.left and SIDE_W or -1
  local r = state.right and SIDE_W or -1
  if lovepsp.setBars then lovepsp.setBars(l, r) end
end

---------------------------------------------------------------- input

visibleRows = function() return math.max(1, math.floor((state.panelH - 36 - 30) / ROW_H)) end

local function tapRight(x, y)
  local px, pw = panelRect("right")
  if y < 30 then closeRight() return end
  local rows = rightRows()
  if state.rightPage == "quit" then
    if y >= 120 and y < 150 then
      if x < px + pw / 2 then
        if state.opts.restart then state.opts.restart(nil) end
      else
        state.rightPage = "menu"
      end
    end
    return
  end
  local visible = visibleRows()
  if #rows > visible and y >= state.panelH - 30 then
    -- bottom strip: UP / DN page the list for touch
    if x < px + 40 then state.rightScroll = math.max(0, state.rightScroll - visible)
    elseif x < px + 80 then state.rightScroll = math.min(math.max(0, #rows - visible), state.rightScroll + visible) end
    return
  end
  local i = math.floor((y - 36) / ROW_H) + 1 + state.rightScroll
  local row = rows[i]
  if not row then return end
  state.rightCursor = i
  local ok, err = pcall(row.action)
  if not ok then
    log("vitaui: " .. tostring(err))
    state.message, state.messageTimer = "That did not work: " .. tostring(err):sub(1, 60), 4
  end
  if not row.keep then closeRight() end
end

local function rightBack()
  if state.rightPage ~= "menu" then state.rightPage = "menu" else closeRight() end
end

local function leftBack()
  if state.leftPage ~= "mods" then state.leftPage = "mods" else closeLeft() end
end

local function tapLeft(x, y)
  local px, pw = panelRect("left")
  if y < 30 then leftBack() return end
  if state.leftPage == "help" then return end
  local visible = visibleRows()
  if y >= state.panelH - 30 then
    -- bottom strip: UP / DN page the list for touch
    if x < px + 40 then state.modScroll = math.max(0, state.modScroll - visible)
    elseif x < px + 80 then state.modScroll = math.min(math.max(0, #state.modRows - visible), state.modScroll + visible)
    end
    return
  end
  local i = math.floor((y - 36) / ROW_H) + 1 + state.modScroll
  local row = state.modRows[i]
  if not row then return end
  state.leftCursor = i
  activateModRow(row)
end

---------------------------------------------------------------- controller

local REPEAT_FIRST, REPEAT_NEXT = 0.35, 0.12

-- stick direction with key-repeat: returns -1 / 1 on the frames a move fires
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

local function clampScroll()
  local visible = visibleRows()
  if state.leftCursor < 1 then state.leftCursor = #state.modRows end
  if state.leftCursor > #state.modRows then state.leftCursor = 1 end
  if state.leftCursor - 1 < state.modScroll then state.modScroll = state.leftCursor - 1 end
  if state.leftCursor > state.modScroll + visible then state.modScroll = state.leftCursor - visible end
end

local function controller(dt)
  local raw = lovepsp.rawInput
  local B = lovepsp.buttonBits
  if not raw or not B then return end
  local buttons = raw.buttons or 0
  local pressed = buttons & ~state.prevButtons
  state.prevButtons = buttons
  if love._env and love._env.LOVEPSP_TRACE_PAD == "1" and (pressed ~= 0 or math.abs(raw.ry or 0) > 0.5 or math.abs(raw.ay or 0) > 0.5 or (raw.lt or 0) > 0.5 or (raw.rt or 0) > 0.5) then
    log(("pad: t=%.2f buttons=%d pressed=%d ay=%.1f ry=%.1f right=%s left=%s"):format(love.timer.getTime(), buttons, pressed, raw.ay or 0, raw.ry or 0, tostring(state.right), tostring(state.left)))
  end
  -- START / SELECT toggle the panels (the game's own START menu is replaced)
  if pressed & B.start ~= 0 then
    if state.right then closeRight() else openRight() end
  end
  if pressed & B.select ~= 0 and buttons & (B.l | B.r) == 0 then
    if state.left then closeLeft() else M.openLeft() end
  end
  -- triggers as edges
  local l2 = (raw.lt or 0) > 0.5 and 1 or 0
  local r2 = (raw.rt or 0) > 0.5 and 1 or 0
  local l2Pressed = l2 == 1 and state.stick.l2 ~= 1
  local r2Pressed = r2 == 1 and state.stick.r2 ~= 1
  state.stick.l2, state.stick.r2 = l2, r2

  if state.right then
    local rows = rightRows()
    local move = stickStep("ry", raw.ry or 0, dt)
    if state.rightPage == "quit" then
      if move ~= 0 then state.rightCursor = state.rightCursor == 1 and 2 or 1 end
      if pressed & B.r ~= 0 then
        if state.rightCursor == 1 and state.opts.restart then state.opts.restart(nil) else state.rightPage = "menu" end
      end
    else
      if move ~= 0 then
        state.rightCursor = ((state.rightCursor - 1 + move) % math.max(1, #rows)) + 1
        clampRightScroll()
      end
      if pressed & B.r ~= 0 then
        local row = rows[state.rightCursor]
        if row then
          local ok, err = pcall(row.action)
          if not ok then log("vitaui: " .. tostring(err)) end
          if not row.keep then closeRight() end
        end
      end
    end
    if r2Pressed then rightBack() end
  end
  if state.left then
    if state.leftPage == "help" then
      if l2Pressed or pressed & B.l ~= 0 then leftBack() end
    else
      local move = stickStep("ly", raw.ay or 0, dt)
      if move ~= 0 then
        state.leftCursor = state.leftCursor + move
        clampScroll()
      end
      if pressed & B.l ~= 0 then activateModRow(state.modRows[state.leftCursor]) end
      if l2Pressed then leftBack() end
    end
  end
end

local function tapAt(x, y)
  y = y - state.base
  if y < 0 then
    -- the game half in the DS layout
    state.circleTimer = SHOW_SECONDS
    return
  end
  if state.skin then
    -- inside the bottom screen the panels take taps; elsewhere the shell's
    -- buttons do (see skinButtons); START / SELECT / HOME open the panels
    local px, pw = panelRect("left")
    local inScreen = x >= px and x < px + pw and y >= state.panelY and y < state.panelY + state.panelH
    if not inScreen then return end
    y = y - state.panelY
  end
  if state.left then
    local px, pw = panelRect("left")
    if x >= px and x < px + pw then return tapLeft(x, y) end
  end
  if state.right then
    local px, pw = panelRect("right")
    if x >= px and x < px + pw then return tapRight(x, y) end
  end
  if state.ds or state.circleTimer > 0 or state.left or state.right then
    if not state.left and x < 40 and math.abs(y - CIRCLE_Y) < 24 then M.openLeft() return end
    if not state.right and x > SCREEN_W - 40 and math.abs(y - CIRCLE_Y) < 24 then openRight() return end
  end
  state.circleTimer = SHOW_SECONDS
end

---------------------------------------------------------------- skin

-- the frame's drawn buttons under the fingers -> injected pad buttons
local function skinButtons(touches)
  local ox, sc = placeBottom()
  if not ox then return 0 end
  local B = lovepsp.buttonBits
  local mask, home = 0, false
  for _, t in ipairs(touches or {}) do
    local x, y = t.x, t.y - state.base
    if y >= 0 then
      for _, b in ipairs(SKIN_BOTTOM.buttons) do
        local cx, cy, r = ox + b.x * sc, b.y * sc, b.r * sc
        local dx, dy = x - cx, y - cy
        if b.kind == "dpad" then
          local ax, ay = math.abs(dx), math.abs(dy)
          if ax <= r * 1.3 and ay <= r * 1.3 and (ax > r * 0.2 or ay > r * 0.2) then
            if ax >= ay * 0.45 then mask = mask | (dx < 0 and B.left or B.right) end
            if ay >= ax * 0.45 then mask = mask | (dy < 0 and B.up or B.down) end
          end
        elseif dx * dx + dy * dy <= (r * 1.25) * (r * 1.25) then
          if b.kind == "menu" then home = true else mask = mask | (B[b.bits] or 0) end
        end
      end
    end
  end
  if home and not state.homeDown then
    if state.right then closeRight() else openRight() end
  end
  state.homeDown = home
  return mask
end

local function drawSkinFrames()
  local ox, sc, y0, img, top = placeTop(state.skin, state.base)
  if img then drawSkin(top.file, ox, y0 - state.base, sc) end
  ox, sc, y0, img = placeBottom()
  if img then
    drawSkin(SKIN_BOTTOM.file, ox, y0, sc)
    local B = lovepsp.buttonBits
    for _, b in ipairs(SKIN_BOTTOM.buttons) do
      local lit = false
      if b.kind == "dpad" then lit = state.held & (B.up | B.down | B.left | B.right) ~= 0
      elseif b.kind == "menu" then lit = state.homeDown
      else lit = state.held & (B[b.bits] or 0) ~= 0 end
      -- the sprite fills the socket: width 2r (a pill keeps its aspect)
      local target = b.r * 2 * sc
      local qw, qh = b.sprite[3], b.sprite[4]
      local scale = (b.wide and (target * 2 / qw)) or (target / math.max(qw, qh))
      local cx, cy = ox + b.x * sc, y0 + b.y * sc
      -- the sheet has no pressed frames: a press sinks the sprite (smaller,
      -- darker, pushed down); the stick and the pad lean the way they are held
      local dx, dy = 0, 0
      if b.kind == "dpad" and lit then
        local lean = b.r * sc * 0.12
        if state.held & B.left ~= 0 then dx = dx - lean end
        if state.held & B.right ~= 0 then dx = dx + lean end
        if state.held & B.up ~= 0 then dy = dy - lean end
        if state.held & B.down ~= 0 then dy = dy + lean end
      end
      local press = lit and 0.93 or 1
      local ps = scale * press
      drawSprite(cx - qw * ps / 2 + dx, cy - qh * ps / 2 + dy + (lit and 1.5 or 0), b.sprite, ps,
        lit and { 0.68, 0.68, 0.72, 1 } or nil)
    end
  end
end

-- the bottom screen while no panel is open: the game's Pokemon animated
-- (assets/idle, one-row sprite sheets); Yellow's Pikachu surfs
local idle = { sheets = {}, manifest = nil }
local function idleAnim(version)
  if idle.manifest == nil then
    local ok, m = pcall(function() return love.filesystem.load("assets/idle/manifest.lua")() end)
    idle.manifest = ok and type(m) == "table" and m or false
  end
  local entry = idle.manifest and idle.manifest[version]
  if not entry then return nil end
  if idle.sheets[version] == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/idle/" .. entry.file)
    if ok then
      img:setFilter("nearest", "nearest")
      local w, h = img:getDimensions()
      local fw = math.floor(w / entry.frames)
      local quads = {}
      for i = 0, entry.frames - 1 do quads[i + 1] = love.graphics.newQuad(i * fw, 0, fw, h, w, h) end
      idle.sheets[version] = { img = img, quads = quads, fw = fw, fh = h, fps = entry.fps or 5, frames = entry.frames }
    else
      idle.sheets[version] = false
    end
  end
  return idle.sheets[version] or nil
end

local function drawIdle()
  local ox, sc, y0 = placeBottom()
  if not ox then return end
  local c = SKIN_BOTTOM.cut
  local x, y, w, h = ox + c[1] * sc, y0 + c[2] * sc, c[3] * sc, c[4] * sc
  local version = (lovepsp.env and lovepsp.env.LOVEPSP_IDLE) or (state.opts and state.opts.version) or "red"
  local t = love.timer.getTime()
  local ct = currentTheme()
  love.graphics.setColor(ct.bg[1], ct.bg[2], ct.bg[3], 1)
  love.graphics.rectangle("fill", x, y, w, h)
  local anim = idleAnim(version)
  local surf = version == "yellow"
  if surf then
    -- the sea: three bands of waves rolling under Pikachu
    for band = 0, 2 do
      local by = y + h * (0.62 + band * 0.12)
      love.graphics.setColor(0.16 + band * 0.06, 0.40 + band * 0.08, 0.85 - band * 0.10, 1)
      love.graphics.rectangle("fill", x, by, w, h - (by - y))
      love.graphics.setColor(0.85, 0.93, 1, 0.9)
      local step = 14
      for wx = x - step, x + w, step do
        local px = wx + (t * (30 + band * 12)) % step
        local py = by + math.sin((px + t * 40) / 9) * 2
        if px >= x and px + 6 <= x + w then love.graphics.rectangle("fill", px, py - 1, 6, 2) end
      end
    end
  end
  if not anim then return end
  local scale = math.max(1, math.floor((h * 0.55) / anim.fh))
  if anim.fh * scale > h * 0.7 then scale = math.max(1, scale - 1) end
  local frame = math.floor(t * anim.fps) % anim.frames + 1
  local dx = x + (w - anim.fw * scale) / 2
  local dy = y + (h - anim.fh * scale) / 2
  if surf then dy = y + h * 0.62 - anim.fh * scale + 14 + math.sin(t * 2.5) * 3 end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(anim.img, anim.quads[frame], math.floor(dx), math.floor(dy), 0, scale, scale)
end

-- the game goes into the top frame's screen cutout (aspect fit)
local function applyGameRect()
  local top = state.skin and SKIN_TOP[state.skin]
  local img = top and skinImage(top.file)
  if not (state.ds and img) then
    if lovepsp.gameRect then lovepsp.gameRect() end
    return
  end
  local ox, sc, y0 = placeTop(state.skin, state.base)
  local c = top.cut
  local cx, cy, cw, ch = ox + c[1] * sc, y0 + c[2] * sc, c[3] * sc, c[4] * sc
  local gw, gh = 160, 144
  local s = math.min(cw / gw, ch / gh)
  local w, h = math.floor(gw * s), math.floor(gh * s)
  lovepsp.gameRect(math.floor(cx + (cw - w) / 2), math.floor(cy + (ch - h) / 2), w, h)
end

---------------------------------------------------------------- drawing

-- text clipped to a width; when it does not fit and the row is active it
-- scrolls sideways (marquee) so long mod names stay readable in a side panel
local function marquee(text, x, y, width, active)
  text = tostring(text)
  local f = love.graphics.getFont()
  local tw = f:getWidth(text)
  if tw <= width then
    love.graphics.print(text, x, y)
    return
  end
  local sx, sy = x, y + state.base + state.panelY + (state.clipDy or 0)
  love.graphics.setScissor(sx, sy, width, f:getHeight() + 2)
  if active then
    local gap = 24
    local off = (love.timer.getTime() * 35) % (tw + gap)
    love.graphics.print(text, x - off, y)
    love.graphics.print(text, x - off + tw + gap, y)
  else
    love.graphics.print(text, x, y)
  end
  love.graphics.setScissor()
end

local function circle(x, y, label)
  love.graphics.setColor(0, 0, 0, 0.45)
  love.graphics.circle("fill", x, y, CIRCLE_R + 3)
  love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.95)
  love.graphics.circle("fill", x, y, CIRCLE_R)
  love.graphics.setColor(1, 1, 1, 1)
  if label == "menu" then
    for i = -1, 1 do love.graphics.rectangle("fill", x - 6, y + i * 4 - 1, 12, 2) end
  else
    love.graphics.setFont(font(12))
    love.graphics.print("M", x - 4, y - 7)
  end
  if state.ds then
    love.graphics.setFont(font(8))
    love.graphics.setColor(0.8, 0.85, 0.95, 1)
    love.graphics.printf(label == "menu" and "MENU" or "MODS", x - 24, y + CIRCLE_R + 4, 48, "center")
  end
end

local function panel(x, w, title)
  local t = currentTheme()
  love.graphics.setColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], 0.96)
  love.graphics.rectangle("fill", x, 0, w, state.panelH)
  -- Game Boy text-box border: a thick outer line and a thin inner one
  love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  love.graphics.rectangle("fill", x, 0, w, 3)
  love.graphics.rectangle("fill", x, state.panelH - 3, w, 3)
  love.graphics.rectangle("fill", x, 0, 3, state.panelH)
  love.graphics.rectangle("fill", x + w - 3, 0, 3, state.panelH)
  love.graphics.rectangle("fill", x + 5, 5, w - 10, 1)
  love.graphics.rectangle("fill", x + 5, state.panelH - 6, w - 10, 1)
  love.graphics.rectangle("fill", x + 5, 5, 1, state.panelH - 10)
  love.graphics.rectangle("fill", x + w - 6, 5, 1, state.panelH - 10)
  -- title bar
  love.graphics.rectangle("fill", x + 3, 3, w - 6, 24)
  love.graphics.setColor(t.title)
  love.graphics.setFont(font(13))
  love.graphics.print(title, x + 10, 8)
  love.graphics.print("X", x + w - 18, 8)
end

local function drawRows(x, w, rows, scroll, cursor, selectedFn)
  love.graphics.setFont(font(11))
  local y = 36
  local visible = visibleRows()
  for i = scroll + 1, math.min(#rows, scroll + visible) do
    local row = rows[i]
    local t = currentTheme()
    love.graphics.setColor(t.text[1], t.text[2], t.text[3], i == cursor and 0.16 or 0.06)
    love.graphics.rectangle("fill", x + 8, y - 2, w - 16, ROW_H - 4)
    if i == cursor then
      love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
      love.graphics.rectangle("fill", x + 8, y - 2, 3, ROW_H - 4) -- the cursor: a pixel arrow bar
      love.graphics.rectangle("line", x + 8, y - 2, w - 16, ROW_H - 4)
    end
    if selectedFn then selectedFn(row, x, y, w, i) end
    y = y + ROW_H
  end
end

local function drawRight()
  local x, w = panelRect("right")
  if state.rightPage == "options" then
    panel(x, w, "OPTIONS")
    drawRows(x, w, buildOptionRows(), state.rightScroll, state.rightCursor, function(row, rx, ry, rw, rowIndex)
      love.graphics.setColor(currentTheme().text)
      marquee(row.label, rx + 10, ry, rw - 20, false)
      if row.value then
        love.graphics.setColor(currentTheme().dim)
        love.graphics.setFont(font(9))
        marquee(row.value(), rx + 10, ry + 11, rw - 20, state.rightCursor == rowIndex)
        love.graphics.setFont(font(11))
      end
    end)
  elseif state.rightPage == "quit" then
    panel(x, w, "QUIT")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(11))
    love.graphics.printf("Back to the launcher?\nUnsaved progress is lost.", x + 8, 50, w - 16, "center")
    love.graphics.setColor(0.8, 0.25, 0.25, 1)
    love.graphics.rectangle("fill", x + 10, 120, w / 2 - 15, 30, 5, 5)
    love.graphics.setColor(0.3, 0.3, 0.36, 1)
    love.graphics.rectangle("fill", x + w / 2 + 5, 120, w / 2 - 15, 30, 5, 5)
    love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    if state.rightCursor == 1 then love.graphics.rectangle("line", x + 10, 120, w / 2 - 15, 30, 5, 5)
    else love.graphics.rectangle("line", x + w / 2 + 5, 120, w / 2 - 15, 30, 5, 5) end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("YES", x + 10, 129, w / 2 - 15, "center")
    love.graphics.printf("NO", x + w / 2 + 5, 129, w / 2 - 15, "center")
  else
    panel(x, w, "MENU")
    drawRows(x, w, state.rows, state.rightScroll, state.rightCursor, function(row, rx, ry, rw, rowIndex)
      love.graphics.setColor(currentTheme().text)
      marquee(row.label, rx + 10, ry + 4, rw - 20, state.rightCursor == rowIndex)
    end)
  end
  if state.rightPage ~= "quit" and #rightRows() > visibleRows() then
    local sy = state.panelH - 28
    love.graphics.setColor(1, 1, 1, 0.12)
    love.graphics.rectangle("fill", x + 6, sy, 32, 22, 4, 4)
    love.graphics.rectangle("fill", x + 42, sy, 32, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(11))
    love.graphics.print("UP", x + 12, sy + 5)
    love.graphics.print("DN", x + 48, sy + 5)
  end
end

local function drawLeft()
  local x, w = panelRect("left")
  if state.leftPage == "help" then
    panel(x, w, "INSTRUCTIONS")
    love.graphics.setColor(currentTheme().text)
    local f = font(w > 200 and 10 or 8)
    love.graphics.setFont(f)
    local y = 34
    local lineH = f:getHeight() + 2
    for _, line in ipairs(HELP) do
      local _, lines = f:getWrap(line, w - 16)
      love.graphics.printf(line, x + 8, y, w - 16)
      y = y + lineH * math.max(1, #lines) + 2
    end
    love.graphics.setColor(0.6, 0.6, 0.66, 1)
    love.graphics.print("L2 / tap X: back", x + 8, state.panelH - 16)
    return
  end
  panel(x, w, "MODS")
  drawRows(x, w, state.modRows, state.modScroll, state.leftCursor, function(row, rx, ry, rw, rowIndex)
    local active = state.leftCursor == rowIndex
    if row.action then
      local t = currentTheme()
      love.graphics.setColor(row.action == "apply" and not state.modsChanged and t.dim or t.text)
      local label = row.label
      if row.action == "theme" then
        local id = state.opts.theme and state.opts.theme() or "auto"
        label = "THEME: " .. ((THEME_BY_ID[id] or THEMES[1]).name) .. (id == "auto" and (" > " .. t.name) or "")
      end
      marquee(label, rx + 10, ry + 4, rw - 20, active)
      return
    end
    local on = row.entry.enabled
    love.graphics.setColor(on and ACCENT or currentTheme().dim)
    love.graphics.rectangle("fill", rx + 10, ry + 3, 22, 12)
    love.graphics.setColor(on and currentTheme().title or currentTheme().bg)
    love.graphics.rectangle("fill", on and rx + 22 or rx + 12, ry + 5, 8, 8)
    love.graphics.setColor(currentTheme().text)
    marquee(row.label, rx + 38, ry + 1, rw - 48, active)
    love.graphics.setFont(font(8))
    if row.state == "error" then
      love.graphics.setColor(1, 0.45, 0.4, 1)
      marquee((row.error or "error"):gsub("\n", " "), rx + 38, ry + 12, rw - 48, active)
    else
      love.graphics.setColor(currentTheme().dim)
      marquee((row.state or "") .. "  v" .. tostring(row.entry.version or ""), rx + 38, ry + 12, rw - 48, active)
    end
    love.graphics.setFont(font(11))
  end)
  -- bottom strip: UP / DN for touch paging, progress text beside them
  local sy = state.panelH - 28
  love.graphics.setColor(1, 1, 1, 0.12)
  love.graphics.rectangle("fill", x + 6, sy, 32, 22, 4, 4)
  love.graphics.rectangle("fill", x + 42, sy, 32, 22, 4, 4)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(11))
  love.graphics.print("UP", x + 12, sy + 5)
  love.graphics.print("DN", x + 48, sy + 5)
  love.graphics.setFont(font(8))
  love.graphics.setColor(0.85, 0.9, 1, 1)
  local note = state.progress or (state.updater and "updating..." or ("%d mods"):format(#state.modRows - 2 - ((lovepsp.network and lovepsp.network()) and 1 or 0)))
  love.graphics.printf(note, x + 80, sy + 2, w - 86, "left")
end

local function render()
  local sw, sh = state.sw, state.sh
  local k = state.skin and hudScale() or 1
  M.hdCanvas(state, sw, sh, k)
  love.graphics.push("all")
  love.graphics.setCanvas(state.hud)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("alpha")
  M.hdBegin(k)
  love.graphics.translate(0, state.base)
  if state.skin then
    drawSkinFrames()
    if not state.left and not state.right then drawIdle() end
  end
  if not state.skin and (state.ds or state.circleTimer > 0 or state.left or state.right) then
    if not state.left then circle(18, CIRCLE_Y, "mods") end
    if not state.right then circle(SCREEN_W - 18, CIRCLE_Y, "menu") end
  end
  love.graphics.translate(0, state.panelY)
  if state.left then drawLeft() end
  if state.right then drawRight() end
  love.graphics.translate(0, -state.panelY)
  if state.message then
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 120, state.panelH - 40, 240, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(9))
    love.graphics.printf(state.message, 124, state.panelH - 35, 232, "center")
  end
  M.hdEnd()
  love.graphics.setCanvas()
  love.graphics.pop()
  lovepsp.setOverlay(state.hud)
end

---------------------------------------------------------------- public

function M.attach(game, opts)
  state.game, state.opts = game, opts
  state.left, state.right, state.circleTimer = false, false, 0
  state.progress, state.updater, state.modsChanged = nil, nil, false
  state.prevButtons = lovepsp.rawInput and lovepsp.rawInput.buttons or 0
  state.stick = {}
  state.attached = lovepsp and lovepsp.setOverlay and lovepsp.touches and true or false
  if not state.attached then return false end
  local Screens = require("src.ui.Screens")
  if not Screens._vitaPush then
    Screens._vitaPush = Screens.push
    Screens.push = function(g, id, ...)
      if id == "StartMenu" and state.attached and not state.passthrough then
        -- swallowed: the START press itself toggles the panel (controller())
        return nil
      end
      return Screens._vitaPush(g, id, ...)
    end
  end
  return true
end

function M.detach()
  state.attached = false
  state.skin = nil
  if lovepsp.layout then lovepsp.layout(nil, PANEL_H, PANEL_H) end
  if lovepsp.gameRect then lovepsp.gameRect() end
  if lovepsp.inject then lovepsp.inject(0) end
  state.left, state.right = false, false
  if lovepsp.setOverlay then lovepsp.setOverlay(nil) end
  if lovepsp.setBars then lovepsp.setBars(-1, -1) end
end

function M.isOpen() return state.left or state.right end
function M.relayout() state.skin = nil end

function M.update(dt)
  if not state.attached then return end
  if lovepsp.screen then
    state.sw, state.sh = lovepsp.screen()
    state.ds = state.sh > PANEL_H
    if lovepsp.split and state.ds then local top = lovepsp.split() state.base = top
    else state.base = state.sh - PANEL_H end
  end
  -- a display change (cover screen <-> inner screen) re-applies the layout
  if lovepsp.display then
    local okD, dw, dh = pcall(lovepsp.display)
    if okD and (dw ~= state.dispW or dh ~= state.dispH) then
      state.dispW, state.dispH = dw, dh
      state.skin = nil
    end
  end
  -- skin: only in the DS layout; the drawn pad gives way to the frame
  -- the 3DS skin is for Android foldables: only there, only in the DS layout
  local wantSkin = (state.ds and love._os == "Android" and state.opts.skin) and state.opts.skin() or "off"
  local newSkin = (wantSkin ~= "off" and SKIN_TOP[wantSkin]) and wantSkin or nil
  if newSkin ~= state.skin then
    state.skin = newSkin
    if lovepsp.touchPad then lovepsp.touchPad(not newSkin and (state.opts.padDefault and state.opts.padDefault() or false) or false) end
    -- the halves take the frames' heights so both shells fill the width
    if lovepsp.layout then
      local ft, fb = fullSplit()
      if newSkin and ft then lovepsp.layout(nil, ft, fb)
      elseif newSkin then lovepsp.layout(nil, frameHeight(SKIN_TOP[newSkin].file), frameHeight(SKIN_BOTTOM.file))
      else lovepsp.layout(nil, PANEL_H, PANEL_H) end
    end
    if lovepsp.screen then
      state.sw, state.sh = lovepsp.screen()
      state.ds = state.sh > PANEL_H
    end
    if lovepsp.split then local top = lovepsp.split() state.base = top end
    applyGameRect()
  end
  if state.skin then
    local _, sc, y0 = placeBottom()
    state.panelY, state.panelH = y0 + SKIN_BOTTOM.cut[2] * sc, SKIN_BOTTOM.cut[4] * sc
  else
    state.panelY, state.panelH = 0, PANEL_H
  end
  local ok, touches = pcall(lovepsp.touches)
  local t = ok and touches and touches[1]
  if t and not state.wasDown then tapAt(t.x, t.y) end
  state.wasDown = t ~= nil and t ~= false
  if state.skin and lovepsp.inject then
    state.held = skinButtons(ok and touches or {})
    lovepsp.inject(state.held)
  elseif state.held ~= 0 and lovepsp.inject then
    state.held = 0
    lovepsp.inject(0)
  end
  if state.circleTimer > 0 and not (state.left or state.right) then
    state.circleTimer = state.circleTimer - dt
  end
  if state.message then
    state.messageTimer = state.messageTimer - dt
    if state.messageTimer <= 0 then state.message = nil end
  end
  controller(dt)
  if state.updater then
    local okr, err = coroutine.resume(state.updater)
    if not okr then log("mod update: " .. tostring(err)) end
    if coroutine.status(state.updater) == "dead" then state.updater = nil end
  end
  applyBars()
  if state.ds or state.left or state.right or state.circleTimer > 0 or state.message then
    render()
  else
    lovepsp.setOverlay(nil)
  end
end

-- shared with the foldable launcher (foldui.lua)
M.SKIN_TOP, M.SKIN_BOTTOM = SKIN_TOP, SKIN_BOTTOM
M.skinImage, M.framePlacement, M.frameHeight = skinImage, framePlacement, frameHeight

return M
