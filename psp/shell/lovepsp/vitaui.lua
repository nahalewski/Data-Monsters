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

local ACCENT = { 0.25, 0.55, 1.0 }
local PANEL_BG = { 0.09, 0.10, 0.14, 0.94 }

local state = {
  game = nil, opts = nil, attached = false,
  left = false, right = false, rightPage = "menu",
  circleTimer = 0, hud = nil, hudW = 0, hudH = 0, wasDown = false,
  rows = {}, modRows = {}, modScroll = 0, modsChanged = false,
  passthrough = false, message = nil, messageTimer = 0,
  progress = nil, updater = nil,
  sw = SCREEN_W, sh = PANEL_H, ds = false, base = 0,
}

local function font(size) return state.opts.font(size) end
local function log(msg) if state.opts.log then state.opts.log(msg) end end

-- geometry of the two panels for the current layout
local function panelRect(side)
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
  push("OPTIONS", function() state.rightPage = "options" end, true)
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
  rows[#rows + 1] = { label = "< BACK", action = function() state.rightPage = "menu" end, keep = true }
  return rows
end

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
  return rows
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

local function startUpdate()
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
end

local function closeRight()
  state.right = false
  state.rightPage = "menu"
end

function M.openLeft()
  if state.ds then closeRight() end
  state.left = true
  state.modRows = buildModRows()
  state.modScroll = 0
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

local function visibleRows() return math.floor((PANEL_H - 36 - 58) / ROW_H) end

local function tapRight(x, y)
  local px, pw = panelRect("right")
  if y < 30 then closeRight() return end
  local rows = state.rightPage == "options" and buildOptionRows() or state.rows
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
  local i = math.floor((y - 36) / ROW_H) + 1
  local row = rows[i]
  if not row then return end
  local ok, err = pcall(row.action)
  if not ok then
    log("vitaui: " .. tostring(err))
    state.message, state.messageTimer = "That did not work: " .. tostring(err):sub(1, 60), 4
  end
  if not row.keep then closeRight() end
end

local function tapLeft(x, y)
  local px, pw = panelRect("left")
  if y < 30 then state.left = false return end
  local visible = visibleRows()
  if y >= PANEL_H - 30 then
    -- bottom strip: UP, DN, APPLY
    if x < px + 40 then state.modScroll = math.max(0, state.modScroll - visible)
    elseif x < px + 80 then state.modScroll = math.min(math.max(0, #state.modRows - visible), state.modScroll + visible)
    elseif x >= px + pw - 64 and state.modsChanged and state.opts.restart then
      state.opts.restart(state.opts.version)
    end
    return
  elseif y >= PANEL_H - 56 then
    startUpdate()
    return
  end
  local i = math.floor((y - 36) / ROW_H) + 1 + state.modScroll
  local row = state.modRows[i]
  if not row then return end
  if state.opts.toggleMod then
    state.opts.toggleMod(row.entry)
    state.modsChanged = true
  end
end

local function tapAt(x, y)
  y = y - state.base
  if y < 0 then
    -- the game half in the DS layout
    state.circleTimer = SHOW_SECONDS
    return
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

---------------------------------------------------------------- drawing

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
  love.graphics.setColor(PANEL_BG)
  love.graphics.rectangle("fill", x, 0, w, PANEL_H)
  love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  love.graphics.rectangle("fill", x, 0, w, 26)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(13))
  love.graphics.print(title, x + 10, 6)
  love.graphics.print("X", x + w - 18, 6)
end

local function drawRows(x, w, rows, scroll, selectedFn)
  love.graphics.setFont(font(11))
  local y = 36
  local visible = visibleRows()
  for i = scroll + 1, math.min(#rows, scroll + visible) do
    local row = rows[i]
    love.graphics.setColor(1, 1, 1, 0.08)
    love.graphics.rectangle("fill", x + 6, y - 2, w - 12, ROW_H - 4, 4, 4)
    if selectedFn then selectedFn(row, x, y, w) end
    y = y + ROW_H
  end
end

local function drawRight()
  local x, w = panelRect("right")
  if state.rightPage == "options" then
    panel(x, w, "OPTIONS")
    drawRows(x, w, buildOptionRows(), 0, function(row, rx, ry, rw)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print(row.label, rx + 10, ry)
      if row.value then
        love.graphics.setColor(0.6, 0.85, 1, 1)
        love.graphics.setFont(font(9))
        love.graphics.print(tostring(row.value()):sub(1, state.ds and 60 or 26), rx + 10, ry + 11)
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
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("YES", x + 10, 129, w / 2 - 15, "center")
    love.graphics.printf("NO", x + w / 2 + 5, 129, w / 2 - 15, "center")
  else
    panel(x, w, "MENU")
    drawRows(x, w, state.rows, 0, function(row, rx, ry)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print(tostring(row.label), rx + 10, ry + 4)
    end)
  end
end

local function drawLeft()
  local x, w = panelRect("left")
  panel(x, w, "MODS")
  drawRows(x, w, state.modRows, state.modScroll, function(row, rx, ry, rw)
    local on = row.entry.enabled
    love.graphics.setColor(on and { 0.35, 0.9, 0.5, 1 } or { 0.5, 0.5, 0.56, 1 })
    love.graphics.rectangle("fill", rx + 10, ry + 3, 22, 12, 6, 6)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", on and rx + 26 or rx + 16, ry + 9, 5)
    love.graphics.print(tostring(row.label):sub(1, state.ds and 40 or 17), rx + 38, ry + 1)
    love.graphics.setFont(font(8))
    if row.state == "error" then
      love.graphics.setColor(1, 0.45, 0.4, 1)
      love.graphics.print((row.error or "error"):gsub("\n", " "):sub(1, state.ds and 70 or 30), rx + 38, ry + 12)
    else
      love.graphics.setColor(0.6, 0.6, 0.66, 1)
      love.graphics.print((row.state or "") .. "  v" .. tostring(row.entry.version or ""), rx + 38, ry + 12)
    end
    love.graphics.setFont(font(11))
  end)
  -- bottom strip: UP DN UPDATE APPLY
  local sy = PANEL_H - 28
  love.graphics.setColor(1, 1, 1, 0.12)
  love.graphics.rectangle("fill", x + 6, sy, 32, 22, 4, 4)
  love.graphics.rectangle("fill", x + 42, sy, 32, 22, 4, 4)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(11))
  love.graphics.print("UP", x + 12, sy + 5)
  love.graphics.print("DN", x + 48, sy + 5)
  if state.modsChanged then
    love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    love.graphics.rectangle("fill", x + w - 64, sy, 58, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(9))
    love.graphics.printf("APPLY", x + w - 64, sy + 6, 58, "center")
  end
  -- second strip: UPDATE FROM GITHUB (full width) with the progress line above
  if lovepsp.network and lovepsp.network() then
    love.graphics.setColor(0.3, 0.6, 0.5, 1)
    love.graphics.rectangle("fill", x + 6, sy - 26, w - 12, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(9))
    love.graphics.printf(state.updater and "UPDATING..." or "UPDATE FROM GITHUB", x + 6, sy - 20, w - 12, "center")
  end
  if state.progress then
    love.graphics.setColor(0.85, 0.9, 1, 1)
    love.graphics.setFont(font(8))
    love.graphics.printf(state.progress, x + 6, sy - 38, w - 12, "center")
  end
end

local function render()
  local sw, sh = state.sw, state.sh
  if not state.hud or state.hudW ~= sw or state.hudH ~= sh then
    state.hud = love.graphics.newCanvas(sw, sh)
    state.hudW, state.hudH = sw, sh
  end
  love.graphics.push("all")
  love.graphics.setCanvas(state.hud)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("alpha")
  love.graphics.translate(0, state.base)
  if state.ds or state.circleTimer > 0 or state.left or state.right then
    if not state.left then circle(18, CIRCLE_Y, "mods") end
    if not state.right then circle(SCREEN_W - 18, CIRCLE_Y, "menu") end
  end
  if state.left then drawLeft() end
  if state.right then drawRight() end
  if state.message then
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 120, PANEL_H - 40, 240, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(9))
    love.graphics.printf(state.message, 124, PANEL_H - 35, 232, "center")
  end
  love.graphics.setCanvas()
  love.graphics.pop()
  lovepsp.setOverlay(state.hud)
end

---------------------------------------------------------------- public

function M.attach(game, opts)
  state.game, state.opts = game, opts
  state.left, state.right, state.circleTimer = false, false, 0
  state.progress, state.updater, state.modsChanged = nil, nil, false
  state.attached = lovepsp and lovepsp.setOverlay and lovepsp.touches and true or false
  if not state.attached then return false end
  local Screens = require("src.ui.Screens")
  if not Screens._vitaPush then
    Screens._vitaPush = Screens.push
    Screens.push = function(g, id, ...)
      if id == "StartMenu" and state.attached and not state.passthrough then
        if state.right then closeRight() else openRight() end
        applyBars()
        return nil
      end
      return Screens._vitaPush(g, id, ...)
    end
  end
  return true
end

function M.detach()
  state.attached = false
  state.left, state.right = false, false
  if lovepsp.setOverlay then lovepsp.setOverlay(nil) end
  if lovepsp.setBars then lovepsp.setBars(-1, -1) end
end

function M.isOpen() return state.left or state.right end

function M.update(dt)
  if not state.attached then return end
  if lovepsp.screen then
    state.sw, state.sh = lovepsp.screen()
    state.ds = state.sh > PANEL_H
    state.base = state.sh - PANEL_H
  end
  local ok, touches = pcall(lovepsp.touches)
  local t = ok and touches and touches[1]
  if t and not state.wasDown then tapAt(t.x, t.y) end
  state.wasDown = t ~= nil and t ~= false
  if state.circleTimer > 0 and not (state.left or state.right) then
    state.circleTimer = state.circleTimer - dt
  end
  if state.message then
    state.messageTimer = state.messageTimer - dt
    if state.messageTimer <= 0 then state.message = nil end
  end
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

return M
