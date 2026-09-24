-- PSP front end for the Gen 1 engine.
--
-- This is the port's own launcher.  The upstream desktop launcher is not
-- licensed for redistribution, so none of its files ship in the EBOOT; this
-- shell only uses the GPL engine modules: ROM verification and cache
-- extraction (src/import/RomExtractor et al.) and the Gen 1 game
-- (src/core/Game).  Gen 2 / Gen 3 are not offered: they do not fit the PSP's
-- memory.
--
--   ROMs go in PSP/GAME/<this folder>/roms/  (canonical US Red/Blue/Yellow)
--   Cross: play / import     Triangle: cycle screen scaling
--   Circle: back             Select + L (in game): cycle screen scaling

local CREDIT = "Based on the Pokemon Gen 1 Recompilation Project by BOIS CLUB "
  .. "GAMES, LLC (https://github.com/bryanthaboi/gen1recomp)"
local TITLE = "Gen 1 Port for PSP (unofficial)"
local GEN1 = { "red", "blue", "yellow" }
local ROM_DIR_MOUNT = "__psp_roms"
local SCREEN_W, SCREEN_H = 480, 272
local GAME_W, GAME_H = 160, 144

local GameVersion = require("src.core.GameVersion")

local Shell = {
  mode = "menu",      -- menu | import | game | message
  cursor = 1,
  roms = {},          -- version -> { path=, name= }
  ready = {},         -- version -> bool
  message = nil,
  import = nil,
}
local Game
local fonts = {}

---------------------------------------------------------------- helpers

local function log(msg)
  print(msg)
  pcall(function() require("lovepsp").log(msg) end)
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
    local lower = name:lower()
    if lower:match("%.gbc?$") then
      local path = ROM_DIR_MOUNT .. "/" .. name
      local info = love.filesystem.getInfo(path, "file")
      if info and info.size and info.size <= 2 * 1024 * 1024 then
        local data = love.filesystem.read(path)
        if data then
          local sha = love.data.encode("string", "hex", love.data.hash("sha1", data))
          local version = GameVersion.forSha1(sha)
          if version and GameVersion.generation(version) == 1 and not Shell.roms[version] then
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
  Shell.mode = "message"
  Shell.message = text
  Shell.messageBack = back or "menu"
end

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
    local RomExtractor = require("src.import.RomExtractor")
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
  Shell.mode = "import"
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
  Shell.mode = "game"
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
  package.loaded["src.core.Game"] = nil
  Game = require("src.core.Game")
  Game:load({})
  collectgarbage()
  log(("game: %s loaded, Lua heap %d KiB"):format(version, math.floor(collectgarbage("count"))))
end

---------------------------------------------------------------- drawing

local function font(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
  return fonts[size]
end

local function drawFrame()
  love.graphics.clear(0.07, 0.08, 0.12, 1)
  love.graphics.setColor(0.85, 0.2, 0.2, 1)
  love.graphics.rectangle("fill", 0, 0, SCREEN_W, 34)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(font(12))
  love.graphics.print(TITLE, 12, 11)
  -- the credit the upstream licence requires in every launcher
  love.graphics.setFont(font(12))
  love.graphics.setColor(0.75, 0.78, 0.85, 1)
  love.graphics.printf(CREDIT, 12, SCREEN_H - 30, SCREEN_W - 24)
end

local function drawMenu()
  drawFrame()
  love.graphics.setFont(font(12))
  local y = 50
  for i, v in ipairs(GEN1) do
    local info = GameVersion.info(v)
    local selected = i == Shell.cursor
    if selected then
      love.graphics.setColor(1, 1, 1, 0.12)
      love.graphics.rectangle("fill", 8, y - 4, SCREEN_W - 16, 30)
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print((selected and "> " or "  ") .. info.displayName, 16, y)
    local status, col
    if Shell.ready[v] then status, col = "Ready - X to play", { 0.5, 0.9, 0.5 }
    elseif Shell.roms[v] then status, col = "ROM found - X to import", { 0.95, 0.8, 0.4 }
    else status, col = "No ROM in roms/", { 0.6, 0.6, 0.65 } end
    love.graphics.setColor(col)
    love.graphics.print(status, 32, y + 12)
    y = y + 36
  end
  love.graphics.setColor(0.7, 0.7, 0.75, 1)
  local mode = love.graphics._getPresentScaling()
  love.graphics.print("Triangle: screen scaling (" .. mode .. ")    Square: rescan ROMs", 16, y + 6)
  love.graphics.print("Put canonical US ROMs (.gb) in PSP/GAME/<folder>/roms/", 16, y + 20)
end

local function drawImport()
  drawFrame()
  local job = Shell.import
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("Importing " .. GameVersion.info(job.version).displayName, 16, 50)
  love.graphics.setColor(0.8, 0.8, 0.85, 1)
  love.graphics.printf(tostring(job.stage or ""), 16, 70, SCREEN_W - 32)
  love.graphics.setColor(0.25, 0.25, 0.3, 1)
  love.graphics.rectangle("fill", 16, 110, SCREEN_W - 32, 14)
  love.graphics.setColor(0.4, 0.8, 0.5, 1)
  love.graphics.rectangle("fill", 16, 110, (SCREEN_W - 32) * math.min(1, job.progress or 0), 14)
  love.graphics.setColor(0.7, 0.7, 0.75, 1)
  local elapsed = math.floor(love.timer.getTime() - job.started)
  love.graphics.print(("%d%%   %dm %02ds elapsed"):format(math.floor((job.progress or 0) * 100),
    elapsed // 60, elapsed % 60), 16, 132)
  love.graphics.print("The first import takes a while on PSP. Keep the system awake.", 16, 150)
end

local function drawMessage()
  drawFrame()
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.printf(Shell.message or "", 16, 46, SCREEN_W - 32)
end

---------------------------------------------------------------- love callbacks

function love.load()
  love.graphics.setDefaultFilter("nearest", "nearest")
  refresh()
  -- a direct-boot shortcut: save/pokemon-love2d/autoboot.txt naming a version
  local auto = love.filesystem.read("autoboot.txt")
  auto = auto and auto:match("%a+")
  if auto and Shell.ready[auto] then bootGame(auto) end
end

function love.update(dt)
  if Shell.mode == "game" then
    return require("src.core.PlatformHooks").update(Game, dt)
  elseif Shell.mode == "import" then
    stepImport()
  end
end

function love.draw()
  if Shell.mode == "game" then return Game:draw() end
  if Shell.mode == "import" then return drawImport() end
  if Shell.mode == "message" then return drawMessage() end
  drawMenu()
end

local function menuPress(button)
  local v = GEN1[Shell.cursor]
  if button == "dpup" then
    Shell.cursor = (Shell.cursor - 2) % #GEN1 + 1
  elseif button == "dpdown" then
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
    local modes = { fit = "stretch", stretch = "integer", integer = "none", none = "fit" }
    local cur, smooth = love.graphics._getPresentScaling()
    love.graphics._setPresentScaling(modes[cur] or "fit", smooth)
    pcall(love.filesystem.write, "lovepsp_scaling.txt", modes[cur] or "fit")
  elseif button == "x" then
    refresh()
  end
end

function love.gamepadpressed(joystick, button)
  if Shell.mode == "game" then return Game:gamepadpressed(joystick, button) end
  if Shell.mode == "message" then
    if button == "a" or button == "b" then Shell.mode = Shell.messageBack end
    return
  end
  if Shell.mode == "menu" then return menuPress(button) end
end

function love.gamepadreleased(joystick, button)
  if Shell.mode == "game" then return Game:gamepadreleased(joystick, button) end
end

function love.gamepadaxis(joystick, axis, value)
  if Shell.mode == "game" then return Game:gamepadaxis(joystick, axis, value) end
end

function love.joystickadded(joystick)
  if Shell.mode == "game" and Game.joystickadded then return Game:joystickadded(joystick) end
end

function love.keypressed(key)
  if Shell.mode == "game" then return Game:keypressed(key) end
end

function love.keyreleased(key)
  if Shell.mode == "game" then return Game:keyreleased(key) end
end

function love.focus(f)
  if Shell.mode == "game" and Game.focus then return Game:focus(f) end
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
