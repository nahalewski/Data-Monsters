-- PSP front end for the Gen 1 engine.
--
-- This is the port's own launcher.  The upstream desktop launcher is not
-- licensed for redistribution (LICENSE.MD term 2), so none of its files
-- ship in the EBOOT; this shell only uses the GPL engine modules: ROM
-- verification and cache extraction (src/import/RomExtractor et al.) and
-- the Gen 1 game (src/core/Game).  Gen 2 / Gen 3 are not offered: they do
-- not fit the PSP's memory.
--
--   ROMs go in PSP/GAME/<this folder>/roms/  (canonical US Red/Blue/Yellow)
--
--   Cards:   Left/Right or nub: pick a cartridge   X: play / import
--            Triangle: options   Square: rescan roms/
--   Options: Up/Down: row   Left/Right or X: change   Circle: back
--   Anywhere: Select + R / Select + L cycle NATIVE / FULLSCREEN / WIDESCREEN

local CREDIT = "Based on the Pokemon Gen 1 Recompilation Project by BOIS CLUB "
  .. "GAMES, LLC (https://github.com/bryanthaboi/gen1recomp)"
local TITLE = "GEN 1 PORT for PSP"
local GameVersion = require("src.core.GameVersion")

-- The cards on offer.  Only Gen 1 fits the PSP; LOVEPSP_GAMES in env.txt
-- (e.g. "red,blue,yellow,firered") adds others for experiments.
local GEN1 = { "red", "blue", "yellow" }
do
  local list = love.lovepsp.env.LOVEPSP_GAMES
  if list then
    GEN1 = {}
    for v in list:gmatch("%a+") do
      GEN1[#GEN1 + 1] = v
    end
  end
end
local ROM_DIR_MOUNT = "__psp_roms"
local OPTIONS_FILE = "psp_options.lua"
local SCREEN_W, SCREEN_H = 480, 272
local GAME_W, GAME_H = 160, 144

local lovepsp = love.lovepsp

local Shell = {
  page = "cards",     -- cards | options | import | game | message
  cursor = 1,
  optCursor = 1,
  roms = {},          -- version -> { path=, name=, sha1= }
  ready = {},         -- version -> bool
  message = nil,
  import = nil,
  blink = 0,
}
local Game
local fonts = {}

---------------------------------------------------------------- helpers

local function log(msg)
  print(msg)
  pcall(lovepsp.log, msg)
end

local function romDir()
  return require("lovepsp").baseDir() .. "roms"
end

local function removeTree(path)
  local info = love.filesystem.getInfo(path)
  if not info then return end
  if info.type == "directory" then
    for _, child in ipairs(love.filesystem.getDirectoryItems(path)) do
      removeTree(path .. "/" .. child)
    end
  end
  love.filesystem.remove(path)
end

local function isReady(version)
  local ok, ready = pcall(function()
    return require("src.import.CacheContract").isReady(version, require("src.import.CacheFs"))
  end)
  return ok and ready
end

-- find canonical Gen 1 ROMs in the roms/ folder (matched by SHA-1)
local function scanRoms()
  Shell.roms = {}
  love.filesystem.unmount(romDir())
  if not love.filesystem.mount(romDir(), ROM_DIR_MOUNT, true) then return end
  for _, name in ipairs(love.filesystem.getDirectoryItems(ROM_DIR_MOUNT)) do
    if name:lower():match("%.gbc?$") or name:lower():match("%.gba$") then
      local path = ROM_DIR_MOUNT .. "/" .. name
      local info = love.filesystem.getInfo(path, "file")
      if info and info.size and info.size <= 16 * 1024 * 1024 then
        local data = love.filesystem.read(path)
        if data then
          local sha = love.data.encode("string", "hex", love.data.hash("sha1", data))
          local version = GameVersion.forSha1(sha)
          if version and not Shell.roms[version] then
            Shell.roms[version] = { path = path, name = name, sha1 = sha }
          end
        end
        data = nil
        collectgarbage()
      end
    end
  end
end

local function refresh()
  for _, v in ipairs(GEN1) do Shell.ready[v] = isReady(v) end
  scanRoms()
end

local function showMessage(text, back)
  Shell.page = "message"
  Shell.message = text
  Shell.messageBack = back or "cards"
end

---------------------------------------------------------------- options

local SCALING = { "none", "fit", "stretch" }
local SCALING_NAMES = { none = "NATIVE (160x144)", fit = "FULLSCREEN (3:2)", stretch = "WIDESCREEN (16:9)" }
local RATES = { "11025", "16000", "22050", "32000", "44100" }
local Options = { scaling = "fit", smooth = true, swapAB = false, audioRate = "22050" }

local function saveOptions()
  local parts = {}
  for k, v in pairs(Options) do
    parts[#parts + 1] = ("%s = %q,"):format(k, tostring(v))
  end
  pcall(love.filesystem.write, OPTIONS_FILE, "return {" .. table.concat(parts) .. "}")
end

local function applyOptions()
  lovepsp.setScaling(Options.scaling, Options.smooth)
  lovepsp.setSwapAB(Options.swapAB)
  lovepsp.env.POKEPORT_AUDIO_RATE = Options.audioRate
  pcall(love.filesystem.write, "lovepsp_scaling.txt", Options.scaling)
end

-- the runtime's SELECT+R / SELECT+L hotkeys report back here
lovepsp.onScalingChanged = function(mode, smooth)
  Options.scaling = mode
  Options.smooth = smooth
  saveOptions()
end

local function loadOptions()
  local chunk = love.filesystem.load(OPTIONS_FILE)
  local ok, t = pcall(chunk or function() end)
  if ok and type(t) == "table" then
    if t.scaling then Options.scaling = t.scaling end
    if t.smooth ~= nil then Options.smooth = t.smooth == "true" end
    if t.swapAB ~= nil then Options.swapAB = t.swapAB == "true" end
    if t.audioRate then Options.audioRate = t.audioRate end
  end
  applyOptions()
end

local function cycle(list, cur, dir)
  local idx = 1
  for i, v in ipairs(list) do if v == cur then idx = i end end
  return list[(idx - 1 + dir) % #list + 1]
end

local function deleteCache(version)
  local prefix = GameVersion.info(version).cachePrefix
  removeTree(prefix .. "data/generated")
  removeTree(prefix .. "assets/generated")
  love.filesystem.remove(prefix .. require("src.import.CacheContract").MARKER_PATH)
  refresh()
end

-- rows: label, value(), change(dir)   (dir 0 = X pressed)
local OPTION_ROWS = {
  { "Screen mode", function() return SCALING_NAMES[Options.scaling] or Options.scaling end,
    function(d) Options.scaling = cycle(SCALING, Options.scaling, d == 0 and 1 or d) end },
  { "Smooth scaling", function() return Options.smooth and "ON" or "OFF" end,
    function() Options.smooth = not Options.smooth end },
  { "Confirm button", function() return Options.swapAB and "CIRCLE = A, CROSS = B" or "CROSS = A, CIRCLE = B" end,
    function() Options.swapAB = not Options.swapAB end },
  { "Music sample rate", function() return Options.audioRate .. " Hz (applies on next launch)" end,
    function(d) Options.audioRate = cycle(RATES, Options.audioRate, d == 0 and 1 or d) end },
  { "Delete imported data", function()
      local v = GEN1[Shell.cursor]
      return Shell.ready[v] and GameVersion.info(v).displayName .. " (press X)" or "nothing imported for this card"
    end,
    function(d)
      local v = GEN1[Shell.cursor]
      if d == 0 and Shell.ready[v] then
        deleteCache(v)
        showMessage(GameVersion.info(v).displayName .. " data deleted. Saves were kept.\n\nPress X to go back.", "options")
      end
    end },
}

---------------------------------------------------------------- import

local function startImport(version)
  local rom = Shell.roms[version]
  if not rom then return end
  local info = GameVersion.info(version)
  local job = { version = version, stage = "Reading ROM", progress = 0, started = love.timer.getTime() }
  job.co = coroutine.create(function()
    local data = assert(love.filesystem.read(rom.path))
    local sha = love.data.encode("string", "hex", love.data.hash("sha1", data))
    assert(GameVersion.forSha1(sha) == version, "ROM changed while importing")
    local CacheFs = require("src.import.CacheFs")
    local CacheContract = require("src.import.CacheContract")
    local prefix = info.cachePrefix
    -- clear this version's previous cache before anything writes
    removeTree(prefix .. "data/generated")
    removeTree(prefix .. "assets/generated")
    love.filesystem.remove(prefix .. CacheContract.MARKER_PATH)
    job.stage = "Reading import metadata"
    coroutine.yield()
    local savedPrefix = CacheFs.prefix
    CacheFs.prefix = prefix
    local manifest = require("src.import.RomManifest").decode(version)
    collectgarbage()
    local gen = GameVersion.generation(version)
    local RomExtractor = gen == 3 and require("src.import.RomExtractorGen3")
      or gen == 2 and require("src.import.RomExtractorGen2")
      or require("src.import.RomExtractor")
    local extractor = RomExtractor.new(data, manifest,
      function(progress, total, stage)
        job.stage = stage
        job.progress = total > 0 and progress / total or 0
        coroutine.yield()
      end, sha)
    extractor:run()
    extractor, manifest, data = nil, nil, nil
    CacheFs.prefix = savedPrefix
    collectgarbage()
    local ok, err = CacheContract.publish(version, CacheFs, sha)
    if not ok then error("could not finish the cache: " .. tostring(err)) end
  end)
  Shell.import = job
  Shell.page = "import"
  log("import: " .. version .. " from " .. rom.name)
end

local function stepImport()
  local job = Shell.import
  -- the import screen does not need 60 fps: spend most of each frame on it
  local deadline = love.timer.getTime() + 0.25
  repeat
    local ok, err = coroutine.resume(job.co)
    if not ok then
      Shell.import = nil
      log("import failed: " .. tostring(err))
      showMessage("Import failed:\n\n" .. tostring(err) .. "\n\n" .. debug.traceback(job.co))
      return
    end
    if coroutine.status(job.co) == "dead" then
      Shell.import = nil
      collectgarbage()
      refresh()
      local secs = math.floor(love.timer.getTime() - job.started)
      log(("import: %s finished in %ds"):format(job.version, secs))
      showMessage(("%s is ready (imported in %dm %02ds).\n\nPress X to continue.")
        :format(GameVersion.info(job.version).displayName, secs // 60, secs % 60))
      return
    end
  until love.timer.getTime() >= deadline
end

---------------------------------------------------------------- game

local function bootGame(version)
  Shell.page = "game"
  love.graphics.setDefaultFilter("nearest", "nearest")
  pcall(function() require("src.core.RequireGuard").capture() end)
  GameVersion.set(version)
  local CacheFs = require("src.import.CacheFs")
  CacheFs.prefix = GameVersion.cachePrefix()
  CacheFs.mountVersion(GameVersion.get())
  local SaveData = require("src.core.SaveData")
  SaveData.setCart(nil, nil)
  require("src.core.GameSpeed").setAllowed(nil)
  love.window.setTitle(GameVersion.info().displayName)
  -- the engine lays out one 160x144 Game Boy screen; lovepsp scales the
  -- window to the PSP's 480x272 panel on present
  love.window.setMode(GAME_W, GAME_H)
  fonts = {}
  collectgarbage()
  local gen = GameVersion.generation()
  if gen == 3 then
    Game = require("src.core.Game3").new()
  elseif gen == 2 then
    Game = require("src.core.Game2").new()
  else
    package.loaded["src.core.Game"] = nil
    Game = require("src.core.Game")
  end
  Game:load({})
  collectgarbage()
  log(("game: %s loaded, Lua heap %d KiB"):format(version, math.floor(collectgarbage("count"))))
end

---------------------------------------------------------------- drawing

local function font(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
  return fonts[size]
end

local CART = setmetatable({
  red = { body = { 0.80, 0.16, 0.18 }, label = { 0.96, 0.90, 0.82 }, text = { 0.45, 0.08, 0.1 } },
  blue = { body = { 0.16, 0.32, 0.78 }, label = { 0.86, 0.92, 0.98 }, text = { 0.08, 0.16, 0.4 } },
  yellow = { body = { 0.92, 0.76, 0.10 }, label = { 0.25, 0.22, 0.15 }, text = { 0.95, 0.9, 0.7 } },
}, { __index = function() return { body = { 0.4, 0.4, 0.45 }, label = { 0.9, 0.9, 0.9 }, text = { 0.2, 0.2, 0.2 } } end })

local function drawFrame(subtitle)
  love.graphics.clear(0.07, 0.08, 0.12, 1)
  love.graphics.setColor(0.85, 0.2, 0.2, 1)
  love.graphics.rectangle("fill", 0, 0, SCREEN_W, 30)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(12))
  love.graphics.print(TITLE, 12, 9)
  if subtitle then
    love.graphics.setColor(1, 0.85, 0.85, 1)
    love.graphics.printf(subtitle, 12, 9, SCREEN_W - 24, "right")
  end
  -- the credit the upstream licence requires in every launcher
  love.graphics.setColor(0.65, 0.68, 0.75, 1)
  love.graphics.printf(CREDIT, 12, SCREEN_H - 30, SCREEN_W - 24)
end

-- a Game Boy cartridge with the game's name on its label
local function drawCartridge(version, x, y, w, h, selected)
  local c = CART[version]
  local info = GameVersion.info(version)
  local ready, rom = Shell.ready[version], Shell.roms[version]
  local bright = selected and 1 or 0.6
  love.graphics.setColor(c.body[1] * bright, c.body[2] * bright, c.body[3] * bright, 1)
  love.graphics.polygon("fill", x + 8, y, x + w - 8, y, x + w, y + 8, x + w, y + h, x, y + h, x, y + 8)
  love.graphics.setColor(0, 0, 0, 0.25)
  for i = 0, 4 do love.graphics.rectangle("fill", x + 6, y + 10 + i * 5, w - 12, 2) end
  love.graphics.setColor(c.label[1] * bright, c.label[2] * bright, c.label[3] * bright, 1)
  love.graphics.rectangle("fill", x + 10, y + 42, w - 20, h - 62)
  love.graphics.setFont(font(12))
  love.graphics.setColor(c.text[1] * bright, c.text[2] * bright, c.text[3] * bright, 1)
  love.graphics.printf("POKEMON", x + 10, y + 52, w - 20, "center")
  love.graphics.printf(info.label:upper(), x + 10, y + 70, w - 20, "center")
  love.graphics.printf("VERSION", x + 10, y + 88, w - 20, "center")
  if selected then
    love.graphics.setColor(1, 1, 1, 0.5 + 0.5 * math.abs(math.sin(Shell.blink * 4)))
    love.graphics.setLineWidth(2)
    love.graphics.polygon("line", x + 8, y - 4, x + w - 8, y - 4, x + w + 4, y + 8, x + w + 4, y + h + 4,
      x - 4, y + h + 4, x - 4, y + 8)
    love.graphics.setLineWidth(1)
  end
  -- status under the cart
  local status, col
  if ready then status, col = "READY", { 0.5, 0.95, 0.55 }
  elseif rom then status, col = "IMPORT", { 1, 0.85, 0.4 }
  else status, col = "NO ROM", { 0.55, 0.55, 0.6 } end
  love.graphics.setColor(col)
  love.graphics.printf(status, x, y + h + 10, w, "center")
end

local function drawCards()
  drawFrame("Triangle: options   Square: rescan")
  Shell.blink = Shell.blink + love.timer.getDelta()
  local gap, h = 24, 130
  local w = math.min(110, math.floor((SCREEN_W - 32 - (#GEN1 - 1) * gap) / #GEN1))
  local x0 = math.floor((SCREEN_W - (#GEN1 * w + (#GEN1 - 1) * gap)) / 2)
  for i, v in ipairs(GEN1) do
    drawCartridge(v, x0 + (i - 1) * (w + gap), 52, w, h, i == Shell.cursor)
  end
  local v = GEN1[Shell.cursor]
  love.graphics.setFont(font(12))
  love.graphics.setColor(0.85, 0.85, 0.9, 1)
  local hint
  if Shell.ready[v] then hint = "X: play " .. GameVersion.info(v).displayName
  elseif Shell.roms[v] then hint = "X: import " .. Shell.roms[v].name
  else hint = "Put a canonical US " .. GameVersion.info(v).label .. " .gb in roms/ and press Square" end
  love.graphics.printf(hint, 12, 216, SCREEN_W - 24, "center")
  love.graphics.setColor(0.6, 0.6, 0.65, 1)
  love.graphics.printf("Select+R / Select+L: screen mode (" .. (SCALING_NAMES[Options.scaling] or Options.scaling) .. ")",
    12, 230, SCREEN_W - 24, "center")
end

local function drawOptions()
  drawFrame("Circle: back")
  love.graphics.setFont(font(12))
  local y = 46
  for i, row in ipairs(OPTION_ROWS) do
    local selected = i == Shell.optCursor
    if selected then
      love.graphics.setColor(1, 1, 1, 0.12)
      love.graphics.rectangle("fill", 8, y - 4, SCREEN_W - 16, 32)
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print((selected and "> " or "  ") .. row[1], 16, y)
    love.graphics.setColor(0.6, 0.9, 1, 1)
    love.graphics.print("< " .. row[2]() .. " >", 32, y + 13)
    y = y + 36
  end
  local ok, mem, free = pcall(lovepsp.memory)
  if ok then
    love.graphics.setColor(0.6, 0.6, 0.65, 1)
    love.graphics.print(("Lua heap %d KiB%s"):format(mem, free and free >= 0 and (("   free %d KiB"):format(free // 1024)) or ""), 16, y + 4)
  end
end

local function drawImport()
  drawFrame()
  local job = Shell.import
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("Importing " .. GameVersion.info(job.version).displayName, 16, 46)
  love.graphics.setColor(0.8, 0.8, 0.85, 1)
  love.graphics.printf(tostring(job.stage or ""), 16, 66, SCREEN_W - 32)
  love.graphics.setColor(0.25, 0.25, 0.3, 1)
  love.graphics.rectangle("fill", 16, 106, SCREEN_W - 32, 14)
  love.graphics.setColor(0.4, 0.8, 0.5, 1)
  love.graphics.rectangle("fill", 16, 106, (SCREEN_W - 32) * math.min(1, job.progress or 0), 14)
  love.graphics.setColor(0.7, 0.7, 0.75, 1)
  local elapsed = math.floor(love.timer.getTime() - job.started)
  love.graphics.print(("%d%%   %dm %02ds elapsed"):format(math.floor((job.progress or 0) * 100),
    elapsed // 60, elapsed % 60), 16, 128)
  love.graphics.print("The first import takes a while on PSP. Keep the system awake.", 16, 146)
end

local function drawMessage()
  drawFrame()
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.printf(Shell.message or "", 16, 42, SCREEN_W - 32)
end

---------------------------------------------------------------- love callbacks

function love.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  loadOptions()
  refresh()
  -- a direct-boot shortcut: save/pokemon-love2d/autoboot.txt naming a version
  local auto = love.filesystem.read("autoboot.txt")
  auto = auto and auto:match("%a+")
  if auto and Shell.ready[auto] then bootGame(auto) end
  -- LOVEPSP_AUTOIMPORT=<version> in env.txt: start that import on boot
  -- (used to drive the port in an emulator with no input injection)
  local autoImport = lovepsp.env.LOVEPSP_AUTOIMPORT
  if autoImport and Shell.roms[autoImport] and not Shell.ready[autoImport] then
    for i, v in ipairs(GEN1) do if v == autoImport then Shell.cursor = i end end
    startImport(autoImport)
  end
end

function love.update(dt)
  if Shell.page == "game" then
    return require("src.core.PlatformHooks").update(Game, dt)
  elseif Shell.page == "import" then
    stepImport()
  end
end

function love.draw()
  if Shell.page == "game" then return Game:draw() end
  if Shell.page == "import" then return drawImport() end
  if Shell.page == "message" then return drawMessage() end
  if Shell.page == "options" then return drawOptions() end
  drawCards()
end

local function cardsPress(button)
  local v = GEN1[Shell.cursor]
  if button == "dpleft" then
    Shell.cursor = (Shell.cursor - 2) % #GEN1 + 1
  elseif button == "dpright" then
    Shell.cursor = Shell.cursor % #GEN1 + 1
  elseif button == "a" then
    if Shell.ready[v] then
      local ok, err = xpcall(bootGame, debug.traceback, v)
      if not ok then error(err, 0) end
    elseif Shell.roms[v] then
      startImport(v)
    else
      showMessage("No ROM for " .. GameVersion.info(v).displayName .. " was found.\n\n"
        .. "Copy your own canonical US cartridge dump (.gb) into\n" .. romDir() .. "/\n\n"
        .. "Accepted SHA-1: " .. tostring(GameVersion.info(v).sha1) .. "\n\nPress X to go back.")
    end
  elseif button == "y" then
    Shell.page = "options"
  elseif button == "x" then
    refresh()
  end
end

local function optionsPress(button)
  local row = OPTION_ROWS[Shell.optCursor]
  if button == "dpup" then
    Shell.optCursor = (Shell.optCursor - 2) % #OPTION_ROWS + 1
  elseif button == "dpdown" then
    Shell.optCursor = Shell.optCursor % #OPTION_ROWS + 1
  elseif button == "dpleft" then
    row[3](-1) applyOptions() saveOptions()
  elseif button == "dpright" or button == "a" then
    row[3](button == "a" and 0 or 1) applyOptions() saveOptions()
  elseif button == "b" or button == "y" then
    Shell.page = "cards"
  end
end

-- the nub doubles as a D-pad on the shell pages
local nubDir = { leftx = nil, lefty = nil }
local function nubPress(axis, value)
  local dir
  if axis == "leftx" then dir = value < -0.5 and "dpleft" or value > 0.5 and "dpright" or nil
  elseif axis == "lefty" then dir = value < -0.5 and "dpup" or value > 0.5 and "dpdown" or nil
  else return nil end
  if dir ~= nubDir[axis] then
    nubDir[axis] = dir
    return dir
  end
end

function love.gamepadpressed(joystick, button)
  if Shell.page == "game" then return Game:gamepadpressed(joystick, button) end
  if Shell.page == "message" then
    if button == "a" or button == "b" then Shell.page = Shell.messageBack end
    return
  end
  if Shell.page == "cards" then return cardsPress(button) end
  if Shell.page == "options" then return optionsPress(button) end
end

function love.gamepadreleased(joystick, button)
  if Shell.page == "game" then return Game:gamepadreleased(joystick, button) end
end

function love.gamepadaxis(joystick, axis, value)
  if Shell.page == "game" then return Game:gamepadaxis(joystick, axis, value) end
  local dir = nubPress(axis, value)
  if dir then love.gamepadpressed(joystick, dir) end
end

function love.joystickadded(joystick)
  if Shell.page == "game" and Game.joystickadded then return Game:joystickadded(joystick) end
end

function love.keypressed(key)
  if Shell.page == "game" then return Game:keypressed(key) end
end

function love.keyreleased(key)
  if Shell.page == "game" then return Game:keyreleased(key) end
end

function love.focus(f)
  if Shell.page == "game" and Game.focus then return Game:focus(f) end
end

function love.lowmemory()
  collectgarbage()
  collectgarbage()
end

function love.quit()
  -- HOME -> Exit Game: the engine writes saves and options as it goes, so
  -- there is nothing to flush here
  return false
end
