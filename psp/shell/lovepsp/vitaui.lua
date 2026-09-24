-- Vita touch UI for a running game: two floating buttons appear at the
-- edges when the screen is touched; the left one slides in a MODS panel
-- (enable / disable, apply with a restart), the right one a menu that
-- replaces the game's START menu -- POKeMON, ITEM, the trainer card, SAVE,
-- OPTIONS (this port's settings), the game's own OPTION screen, MODS and
-- QUIT (back to the launcher).  While a panel is open the game shrinks
-- between the panels and keeps running under the physical controls.
--
-- The panels are drawn into a screen-sized canvas that the runtime
-- composites over the presented frame (lovepsp.setOverlay), so the game's
-- 160x144 canvas and its renderer are untouched.  Gen 1 menu rows reuse the
-- engine's own START menu items (src/ui/StartMenu.lua) and therefore also
-- carry rows added by mods; Gen 2 keeps its own START menu (opened from the
-- panel) because its rows are bound to that screen's state machine.
local M = {}

local lovepsp = love.lovepsp
local SCREEN_W, SCREEN_H = 480, 272
local PANEL_W = 150
local ROW_H = 24
local CIRCLE_R = 13
local CIRCLE_Y = 30
local SHOW_SECONDS = 4

local ACCENT = { 0.25, 0.55, 1.0 }
local PANEL_BG = { 0.09, 0.10, 0.14, 0.94 }

local state = {
  game = nil, opts = nil, attached = false,
  left = false, right = false, rightPage = "menu",
  circleTimer = 0, hud = nil, wasDown = false,
  rows = {}, modRows = {}, modScroll = 0, modsChanged = false,
  passthrough = false, message = nil, messageTimer = 0,
}

local function font(size)
  return state.opts.font(size)
end

local function log(msg)
  if state.opts.log then state.opts.log(msg) end
end

---------------------------------------------------------------- rows

local function buildMenuRows()
  local game, opts = state.game, state.opts
  local rows = {}
  local Strings = require("src.core.Strings")
  local function push(label, action, keep)
    -- the runtime's bitmap font is ASCII: POKéMON -> POKeMON
    label = tostring(label):gsub("[\194-\244][\128-\191]*", "e")
    rows[#rows + 1] = { label = label, action = action, keep = keep }
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
  push("MODS", function() state.left = true end, true)
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

---------------------------------------------------------------- panels

local function openRight()
  state.right = true
  state.rightPage = "menu"
  state.rows = buildMenuRows()
end

local function closeRight()
  state.right = false
  state.rightPage = "menu"
end

local function openLeft()
  state.left = true
  state.modRows = buildModRows()
  state.modScroll = 0
end

local function applyBars()
  local l = state.left and PANEL_W or -1
  local r = state.right and PANEL_W or -1
  if lovepsp.setBars then lovepsp.setBars(l, r) end
end

---------------------------------------------------------------- input

local function tapRight(x, y)
  local px = SCREEN_W - PANEL_W
  if y < 30 then closeRight() return end
  local rows = state.rightPage == "options" and buildOptionRows() or state.rows
  if state.rightPage == "quit" then
    -- YES / NO boxes
    if y >= 120 and y < 150 then
      if x < px + PANEL_W / 2 then
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
  if y < 30 then state.left = false return end
  local visible = math.floor((SCREEN_H - 36 - 30) / ROW_H)
  -- bottom strip: scroll arrows and APPLY
  if y >= SCREEN_H - 30 then
    if x < 40 then state.modScroll = math.max(0, state.modScroll - visible)
    elseif x < 80 then state.modScroll = math.min(math.max(0, #state.modRows - visible), state.modScroll + visible)
    elseif state.modsChanged and state.opts.restart then
      state.opts.restart(state.opts.version)
    end
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
  if state.left and x < PANEL_W then return tapLeft(x, y) end
  if state.right and x >= SCREEN_W - PANEL_W then return tapRight(x, y) end
  -- floating buttons (only while shown)
  if state.circleTimer > 0 or state.left or state.right then
    if not state.left and x < 40 and math.abs(y - CIRCLE_Y) < 24 then openLeft() return end
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
end

local function panel(x, title)
  love.graphics.setColor(PANEL_BG)
  love.graphics.rectangle("fill", x, 0, PANEL_W, SCREEN_H)
  love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  love.graphics.rectangle("fill", x, 0, PANEL_W, 26)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(13))
  love.graphics.print(title, x + 10, 6)
  love.graphics.print("X", x + PANEL_W - 18, 6)
end

local function drawRows(x, rows, scroll, selectedFn)
  love.graphics.setFont(font(11))
  local y = 36
  local visible = math.floor((SCREEN_H - 36 - 30) / ROW_H)
  for i = scroll + 1, math.min(#rows, scroll + visible) do
    local row = rows[i]
    love.graphics.setColor(1, 1, 1, 0.08)
    love.graphics.rectangle("fill", x + 6, y - 2, PANEL_W - 12, ROW_H - 4, 4, 4)
    if selectedFn then selectedFn(row, x, y) end
    y = y + ROW_H
  end
end

local function drawRight()
  local x = SCREEN_W - PANEL_W
  if state.rightPage == "options" then
    panel(x, "OPTIONS")
    drawRows(x, buildOptionRows(), 0, function(row, rx, ry)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print(row.label, rx + 10, ry)
      if row.value then
        love.graphics.setColor(0.6, 0.85, 1, 1)
        love.graphics.setFont(font(9))
        love.graphics.print(tostring(row.value()):sub(1, 26), rx + 10, ry + 11)
        love.graphics.setFont(font(11))
      end
    end)
  elseif state.rightPage == "quit" then
    panel(x, "QUIT")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(11))
    love.graphics.printf("Back to the launcher?\nUnsaved progress is lost.", x + 8, 50, PANEL_W - 16, "center")
    love.graphics.setColor(0.8, 0.25, 0.25, 1)
    love.graphics.rectangle("fill", x + 10, 120, PANEL_W / 2 - 15, 30, 5, 5)
    love.graphics.setColor(0.3, 0.3, 0.36, 1)
    love.graphics.rectangle("fill", x + PANEL_W / 2 + 5, 120, PANEL_W / 2 - 15, 30, 5, 5)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("YES", x + 10, 129, PANEL_W / 2 - 15, "center")
    love.graphics.printf("NO", x + PANEL_W / 2 + 5, 129, PANEL_W / 2 - 15, "center")
  else
    panel(x, "MENU")
    drawRows(x, state.rows, 0, function(row, rx, ry)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print(tostring(row.label), rx + 10, ry + 4)
    end)
  end
end

local function drawLeft()
  panel(0, "MODS")
  drawRows(0, state.modRows, state.modScroll, function(row, rx, ry)
    local on = row.entry.enabled
    love.graphics.setColor(on and { 0.35, 0.9, 0.5, 1 } or { 0.5, 0.5, 0.56, 1 })
    love.graphics.rectangle("fill", rx + 10, ry + 3, 22, 12, 6, 6)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", on and rx + 26 or rx + 16, ry + 9, 5)
    love.graphics.print(tostring(row.label):sub(1, 17), rx + 38, ry + 1)
    love.graphics.setFont(font(8))
    if row.state == "error" then
      love.graphics.setColor(1, 0.45, 0.4, 1)
      love.graphics.print((row.error or "error"):gsub("\n", " "):sub(1, 30), rx + 38, ry + 12)
    elseif row.state then
      love.graphics.setColor(0.6, 0.6, 0.66, 1)
      love.graphics.print(row.state, rx + 38, ry + 12)
    end
    love.graphics.setFont(font(11))
  end)
  -- bottom strip
  love.graphics.setColor(1, 1, 1, 0.12)
  love.graphics.rectangle("fill", 6, SCREEN_H - 28, 32, 22, 4, 4)
  love.graphics.rectangle("fill", 42, SCREEN_H - 28, 32, 22, 4, 4)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(11))
  love.graphics.print("UP", 12, SCREEN_H - 23)
  love.graphics.print("DN", 48, SCREEN_H - 23)
  if state.modsChanged then
    love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    love.graphics.rectangle("fill", 80, SCREEN_H - 28, PANEL_W - 86, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("APPLY+RESTART", 84, SCREEN_H - 23)
  else
    love.graphics.setColor(0.6, 0.6, 0.66, 1)
    love.graphics.setFont(font(8))
    love.graphics.print(("%d mods"):format(#state.modRows), 84, SCREEN_H - 21)
  end
end

local function render()
  if not state.hud then state.hud = love.graphics.newCanvas(SCREEN_W, SCREEN_H) end
  love.graphics.push("all")
  love.graphics.setCanvas(state.hud)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("alpha")
  if state.circleTimer > 0 or state.left or state.right then
    if not state.left then circle(18, CIRCLE_Y, "mods") end
    if not state.right then circle(SCREEN_W - 18, CIRCLE_Y, "menu") end
  end
  if state.left then drawLeft() end
  if state.right then drawRight() end
  if state.message then
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 120, SCREEN_H - 40, 240, 22, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font(9))
    love.graphics.printf(state.message, 124, SCREEN_H - 35, 232, "center")
  end
  love.graphics.setCanvas()
  love.graphics.pop()
  lovepsp.setOverlay(state.hud)
end

---------------------------------------------------------------- public

function M.attach(game, opts)
  state.game, state.opts = game, opts
  state.left, state.right, state.circleTimer = false, false, 0
  state.attached = lovepsp and lovepsp.setOverlay and lovepsp.touches and true or false
  if not state.attached then return false end
  -- START opens this menu instead of the game's own
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
  applyBars()
  if state.left or state.right or state.circleTimer > 0 or state.message then
    render()
  else
    lovepsp.setOverlay(nil)
  end
end

return M
