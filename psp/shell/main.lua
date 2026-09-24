-- PSP front end for gen1recomp.
--
-- This is the port's own launcher.  The upstream desktop launcher is not
-- licensed for redistribution (LICENSE.MD term 2), so none of its files
-- ship in the EBOOT; this shell only uses the GPL engine modules: ROM
-- verification and cache extraction (src/import/RomExtractor*) and the
-- game service owners (src/core/Game, Game2, Game3).
--
-- Every game upstream supports gets a card.  Only Gen 1 has been shown to
-- fit the PSP's memory; Gen 2 and Gen 3 cards are offered as experiments
-- and say so.  Art on a card (logo, mascot) is the player's own, decoded
-- from their ROM into the cache at import time -- the port ships none.
--
--   ROMs: PSP/GAME/<this folder>/  or  PSP/GAME/<this folder>/roms/
--         (canonical US dumps; matched by SHA-1, any file name)
--
--   Cards:   D-pad / nub: pick a cartridge   X: play / import
--            Triangle: options   Square: rescan
--   Options: Up/Down: row   Left/Right or X: change   Circle: back
--   Anywhere: Select + R / Select + L cycle NATIVE / FULLSCREEN / WIDESCREEN

local CREDIT = "Based on the Pokemon Gen 1 Recompilation Project by BOIS CLUB "
  .. "GAMES, LLC (https://github.com/bryanthaboi/gen1recomp)"
local TITLE = "GEN 1 RECOMP - PSP"
local OPTIONS_FILE = "psp_options.lua"
local SCREEN_W, SCREEN_H = 480, 272
local GAME_W, GAME_H = 160, 144
local COLS = 4

local lovepsp = love.lovepsp
local core = require("lovepsp")
local GameVersion = require("src.core.GameVersion")

-- The cards on offer: everything upstream can import, in its order.
-- LOVEPSP_GAMES in env.txt narrows or reorders the list.
local GAMES = {}
do
  local list = lovepsp.env.LOVEPSP_GAMES
  if list then
    for v in list:gmatch("%a+") do if GameVersion.VERSIONS[v] then GAMES[#GAMES + 1] = v end end
  end
  if #GAMES == 0 then
    for _, v in ipairs(GameVersion.ORDER) do GAMES[#GAMES + 1] = v end
  end
end

local Shell = {
  page = "cards",     -- cards | options | import | game | message
  cursor = 1,
  optCursor = 1,
  roms = {},          -- version -> { path=, name=, sha1= }
  unknown = {},       -- ROM-looking files no supported game matched
  ready = {},         -- version -> bool
  art = {},           -- version -> { logo = Image?, mascot = Image? }
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

-- ROM folders: the EBOOT's own folder and roms/ under it, mounted read-only
local ROM_DIRS = {
  { real = core.baseDir():gsub("/$", ""), mount = "__psp_base" },
  { real = core.baseDir() .. "roms", mount = "__psp_roms" },
}

-- Find canonical ROMs (matched by SHA-1, streamed so a 16 MiB GBA dump
-- never has to sit in memory on a 32 MiB console).
local function scanRoms()
  Shell.roms, Shell.unknown = {}, {}
  for _, dir in ipairs(ROM_DIRS) do
    love.filesystem.unmount(dir.real)
    if love.filesystem.mount(dir.real, dir.mount, true) then
      for _, name in ipairs(love.filesystem.getDirectoryItems(dir.mount)) do
        local lower = name:lower()
        if lower:match("%.gbc?$") or lower:match("%.gba$") then
          local path = dir.mount .. "/" .. name
          local info = love.filesystem.getInfo(path, "file")
          if info and info.size and info.size <= 32 * 1024 * 1024 then
            local raw = love.data.hashFile("sha1", path)
            local sha = raw and love.data.encode("string", "hex", raw)
            local version = sha and GameVersion.forSha1(sha)
            if version then
              if not Shell.roms[version] then
                Shell.roms[version] = { path = path, name = name, sha1 = sha }
              end
            else
              Shell.unknown[#Shell.unknown + 1] = name
            end
          end
        end
      end
    end
  end
end

-- card art comes from the player's imported cache, never from the archive
local ART = {
  red = { logo = "assets/generated/title/pokemon_logo.png", mascot = "assets/generated/battle/front/charizard.png" },
  blue = { logo = "assets/generated/title/pokemon_logo.png", mascot = "assets/generated/battle/front/blastoise.png" },
  yellow = { logo = "assets/generated/title/pokemon_logo.png", mascot = "assets/generated/battle/front/pikachu.png" },
  gold = { logo = "assets/generated/title/pokemon_logo.png", mascot = "assets/generated/title/hooh.png" },
  silver = { logo = "assets/generated/title/pokemon_logo.png", mascot = "assets/generated/title/lugia.png" },
  crystal = { logo = "assets/generated/title/crystal_logo.png", mascot = "assets/generated/title/crystal_suicune.png" },
  firered = { logo = "data/generated/gba/intro/title_logo.png" },
  leafgreen = { logo = "data/generated/gba/intro/title_logo.png" },
}

local function loadArt(version)
  local art = {}
  local spec = ART[version]
  if spec and Shell.ready[version] then
    local prefix = GameVersion.info(version).cachePrefix
    for kind, rel in pairs(spec) do
      local ok, img = pcall(love.graphics.newImage, prefix .. rel)
      if ok and img then
        img:setFilter("nearest", "nearest")
        art[kind] = img
      end
    end
  end
  Shell.art[version] = art
end

local function refresh()
  for _, v in ipairs(GAMES) do
    Shell.ready[v] = isReady(v)
    loadArt(v)
  end
  scanRoms()
  collectgarbage()
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
local Options = { scaling = "fit", smooth = true, swapAB = false, audioRate = "22050", music = true }

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
    if t.music ~= nil then Options.music = t.music == "true" end
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
  { "Music", function() return Options.music and "ON" or "OFF (faster: the chip synth runs in Lua)" end,
    function() Options.music = not Options.music end },
  { "Music sample rate", function() return Options.audioRate .. " Hz (applies on next launch)" end,
    function(d) Options.audioRate = cycle(RATES, Options.audioRate, d == 0 and 1 or d) end },
  { "Delete imported data", function()
      local v = GAMES[Shell.cursor]
      return Shell.ready[v] and GameVersion.info(v).displayName .. " (press X)" or "nothing imported for this card"
    end,
    function(d)
      local v = GAMES[Shell.cursor]
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
  fonts, Shell.art = {}, {}
  collectgarbage()
  if not Options.music then
    -- music is synthesized sample by sample in Lua, which is the single most
    -- expensive thing the engine does on a 333 MHz interpreter; sound
    -- effects and cries are short one-shots and stay
    local ChipAudio = require("src.core.ChipAudio")
    ChipAudio.playMusic = function() return nil, "music disabled in PSP options" end
  end
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
  if lovepsp.env.LOVEPSP_PROFILE == "1" then
    -- wrap the engine's per-frame entry points; boot.lua prints the totals
    LOVEPSP_PROF = {}
    local function wrap(tbl, key, name)
      local fn = tbl[key]
      if type(fn) ~= "function" then return end
      local slot = { time = 0, calls = 0 }
      LOVEPSP_PROF[name] = slot
      tbl[key] = function(...)
        local t0 = core.time()
        local a, b, c, d = fn(...)
        slot.time = slot.time + (core.time() - t0)
        slot.calls = slot.calls + 1
        return a, b, c, d
      end
    end
    wrap(require("src.core.FixedStep"), "update", "fixedstep")
    wrap(require("src.core.Music"), "update", "music")
    wrap(require("src.core.ChipSynth"), "soundData", "synth")
    wrap(require("src.render.Tilt"), "update", "tilt")
    wrap(require("src.render.Pipelines"), "update", "pipelines")
    wrap(Game, "updateSync", "sync")
    wrap(Game, "step", "step")
    wrap(Game, "draw", "gamedraw")
    wrap(love.audio, "_update", "audio_reap")
    local cg = collectgarbage
    local slot = { time = 0, calls = 0 }
    LOVEPSP_PROF.gc = slot
    collectgarbage = function(...)
      local t0 = core.time()
      local r = cg(...)
      slot.time = slot.time + (core.time() - t0)
      slot.calls = slot.calls + 1
      return r
    end
  end
  log(("game: %s loaded, Lua heap %d KiB"):format(version, math.floor(collectgarbage("count"))))
end

---------------------------------------------------------------- drawing

local function font(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
  return fonts[size]
end

-- cartridge styling per game: plastic colour, label colour, label text
-- colour, and the shell shape (gb / gbc / gba)
local STYLE = {
  red = { body = { 0.80, 0.16, 0.18 }, label = { 0.95, 0.90, 0.84 }, text = { 0.45, 0.08, 0.10 } },
  blue = { body = { 0.16, 0.34, 0.80 }, label = { 0.88, 0.93, 0.98 }, text = { 0.08, 0.16, 0.42 } },
  yellow = { body = { 0.95, 0.78, 0.12 }, label = { 0.26, 0.22, 0.14 }, text = { 0.98, 0.92, 0.70 } },
  gold = { body = { 0.86, 0.68, 0.20 }, label = { 0.98, 0.94, 0.80 }, text = { 0.45, 0.32, 0.06 }, gbc = true },
  silver = { body = { 0.72, 0.74, 0.78 }, label = { 0.94, 0.95, 0.98 }, text = { 0.25, 0.27, 0.32 }, gbc = true },
  crystal = { body = { 0.45, 0.72, 0.92 }, label = { 0.90, 0.96, 1.00 }, text = { 0.10, 0.30, 0.50 }, gbc = true },
  firered = { body = { 0.86, 0.32, 0.14 }, label = { 0.98, 0.90, 0.80 }, text = { 0.50, 0.14, 0.04 }, gba = true },
  leafgreen = { body = { 0.30, 0.64, 0.30 }, label = { 0.90, 0.97, 0.88 }, text = { 0.10, 0.32, 0.10 }, gba = true },
}
local DEFAULT_STYLE = { body = { 0.45, 0.45, 0.50 }, label = { 0.92, 0.92, 0.92 }, text = { 0.2, 0.2, 0.2 } }

local function setColor(c, mul, a)
  love.graphics.setColor(c[1] * mul, c[2] * mul, c[3] * mul, a or 1)
end

local function drawBackground()
  -- vertical gradient in a few bands (cheap on the CPU rasterizer)
  local bands = 8
  for i = 0, bands - 1 do
    local t = i / (bands - 1)
    love.graphics.setColor(0.10 + 0.04 * (1 - t), 0.09 + 0.02 * (1 - t), 0.16 + 0.06 * (1 - t), 1)
    love.graphics.rectangle("fill", 0, i * SCREEN_H / bands, SCREEN_W, SCREEN_H / bands + 1)
  end
  -- the Poke Ball motif, faint, bottom right
  love.graphics.setColor(1, 1, 1, 0.05)
  love.graphics.circle("fill", SCREEN_W - 40, SCREEN_H - 20, 110)
  love.graphics.setColor(0.10, 0.09, 0.16, 1)
  love.graphics.rectangle("fill", SCREEN_W - 150, SCREEN_H - 24, 220, 8)
  love.graphics.setColor(1, 1, 1, 0.06)
  love.graphics.circle("fill", SCREEN_W - 40, SCREEN_H - 20, 26)
end

local function drawChrome(subtitle)
  drawBackground()
  love.graphics.setColor(0.80, 0.14, 0.18, 1)
  love.graphics.rectangle("fill", 0, 0, SCREEN_W, 24)
  love.graphics.setColor(0.55, 0.08, 0.10, 1)
  love.graphics.rectangle("fill", 0, 24, SCREEN_W, 2)
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(TITLE, 10, 8)
  if subtitle then
    love.graphics.setColor(1, 0.85, 0.85, 1)
    love.graphics.printf(subtitle, 10, 8, SCREEN_W - 20, "right")
  end
  -- the credit the upstream licence requires in every launcher
  love.graphics.setColor(0.62, 0.64, 0.72, 1)
  love.graphics.printf(CREDIT, 10, SCREEN_H - 30, SCREEN_W - 20)
end

local function fitScale(img, maxW, maxH)
  local w, h = img:getDimensions()
  local s = math.min(maxW / w, maxH / h)
  if s >= 1 then s = math.floor(s) end
  return s, w * s, h * s
end

-- a cartridge with the game's art (from the player's cache) on its label
local function drawCartridge(version, x, y, w, h, selected)
  local st = STYLE[version] or DEFAULT_STYLE
  local info = GameVersion.info(version)
  local ready, rom = Shell.ready[version], Shell.roms[version]
  local art = Shell.art[version] or {}
  local mul = selected and 1 or 0.62
  -- shadow
  love.graphics.setColor(0, 0, 0, 0.35)
  love.graphics.rectangle("fill", x + 3, y + 4, w, h)
  -- shell
  setColor(st.body, mul)
  if st.gba then
    love.graphics.polygon("fill", x + 4, y, x + w - 4, y, x + w, y + 4, x + w, y + h - 6,
      x + w - 6, y + h, x + 6, y + h, x, y + h - 6, x, y + 4)
  else
    love.graphics.polygon("fill", x + 8, y, x + w - 8, y, x + w, y + 8, x + w, y + h, x, y + h, x, y + 8)
  end
  if st.gbc then
    -- translucent look: lighter diagonal highlight
    love.graphics.setColor(1, 1, 1, 0.10 * mul)
    love.graphics.polygon("fill", x + 4, y + 4, x + w * 0.45, y + 4, x + 4, y + h * 0.7)
  end
  -- grip ridges
  love.graphics.setColor(0, 0, 0, 0.22)
  for i = 0, 2 do love.graphics.rectangle("fill", x + 8, y + 5 + i * 4, w - 16, 1.5) end
  -- label
  local lx, ly, lw, lh = x + 8, y + 18, w - 16, h - 30
  setColor(st.label, mul)
  love.graphics.rectangle("fill", lx, ly, lw, lh)
  love.graphics.setColor(0, 0, 0, 0.15)
  love.graphics.rectangle("line", lx + 0.5, ly + 0.5, lw - 1, lh - 1)
  love.graphics.setColor(1, 1, 1, mul)
  if art.logo then
    local s, sw, sh = fitScale(art.logo, lw - 6, lh * 0.55)
    love.graphics.draw(art.logo, lx + (lw - sw) / 2, ly + 3, 0, s, s)
    if art.mascot then
      local ms, mw, mh = fitScale(art.mascot, lw * 0.55, lh - sh - 4)
      love.graphics.draw(art.mascot, lx + lw - mw - 3, ly + lh - mh - 2, 0, ms, ms)
    end
    love.graphics.setFont(font(12))
    setColor(st.text, mul)
    love.graphics.print(info.label:upper(), lx + 4, ly + lh - 12)
  else
    love.graphics.setFont(font(12))
    setColor(st.text, mul)
    love.graphics.printf("POKEMON", lx, ly + 6, lw, "center")
    love.graphics.printf(info.launcherName and info.launcherName:upper() or info.label:upper(), lx, ly + 20, lw, "center")
    love.graphics.printf("VERSION", lx, ly + 34, lw, "center")
  end
  -- status strip
  local status, col
  if ready then status, col = "READY", { 0.45, 0.95, 0.55 }
  elseif rom then status, col = "IMPORT", { 1, 0.85, 0.35 }
  else status, col = "NO ROM", { 0.62, 0.62, 0.68 } end
  love.graphics.setColor(0, 0, 0, 0.35)
  love.graphics.rectangle("fill", x + 8, y + h - 11, w - 16, 10)
  love.graphics.setFont(font(12))
  setColor(col, mul)
  love.graphics.printf(status, x, y + h - 10, w, "center")
  -- selection frame
  if selected then
    love.graphics.setColor(1, 1, 1, 0.55 + 0.45 * math.abs(math.sin(Shell.blink * 4)))
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x - 3, y - 3, w + 6, h + 6)
    love.graphics.setLineWidth(1)
  end
end

local function cardRect(i)
  local rows = math.ceil(#GAMES / COLS)
  local cols = math.min(COLS, #GAMES)
  local gap = 10
  local areaY, areaH = 30, 170
  local w = math.floor((SCREEN_W - 24 - (cols - 1) * gap) / cols)
  local h = math.floor((areaH - (rows - 1) * gap) / rows)
  if w > 140 then w = 140 end
  if h > 120 then h = 120 end
  local x0 = math.floor((SCREEN_W - (cols * w + (cols - 1) * gap)) / 2)
  local y0 = areaY + math.floor((areaH - (rows * h + (rows - 1) * gap)) / 2)
  local r, c = (i - 1) // cols, (i - 1) % cols
  return x0 + c * (w + gap), y0 + r * (h + gap), w, h
end

local function drawCards()
  drawChrome("Triangle options  Square rescan")
  Shell.blink = Shell.blink + love.timer.getDelta()
  for i, v in ipairs(GAMES) do
    local x, y, w, h = cardRect(i)
    drawCartridge(v, x, y, w, h, i == Shell.cursor)
  end
  local v = GAMES[Shell.cursor]
  local info = GameVersion.info(v)
  love.graphics.setFont(font(12))
  love.graphics.setColor(0.9, 0.9, 0.95, 1)
  local hint
  if Shell.ready[v] then hint = "X: play " .. info.displayName
  elseif Shell.roms[v] then hint = "X: import " .. Shell.roms[v].name
  else hint = "No ROM: put your US " .. info.displayName .. " dump next to the EBOOT" end
  love.graphics.printf(hint, 10, 206, SCREEN_W - 20, "center")
  love.graphics.setColor(0.62, 0.62, 0.68, 1)
  local foot
  if GameVersion.generation(v) ~= 1 then
    foot = "Gen " .. GameVersion.generation(v) .. " is experimental on PSP and may run out of memory"
  elseif #Shell.unknown > 0 then
    foot = "Not supported: " .. table.concat(Shell.unknown, ", ")
  else
    foot = "Select+R / Select+L: " .. (SCALING_NAMES[Options.scaling] or Options.scaling)
  end
  love.graphics.printf(foot, 10, 220, SCREEN_W - 20, "center")
end

local function drawOptions()
  drawChrome("Circle: back")
  love.graphics.setFont(font(12))
  local y = 40
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
    love.graphics.print(("Lua heap %d KiB%s"):format(mem, free and free >= 0 and (("   free %d KiB"):format(free // 1024)) or ""), 16, y + 2)
  end
end

local function drawImport()
  drawChrome()
  local job = Shell.import
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("Importing " .. GameVersion.info(job.version).displayName, 16, 44)
  love.graphics.setColor(0.8, 0.8, 0.85, 1)
  love.graphics.printf(tostring(job.stage or ""), 16, 64, SCREEN_W - 32)
  love.graphics.setColor(0.22, 0.22, 0.30, 1)
  love.graphics.rectangle("fill", 16, 104, SCREEN_W - 32, 14)
  love.graphics.setColor(0.35, 0.80, 0.50, 1)
  love.graphics.rectangle("fill", 16, 104, (SCREEN_W - 32) * math.min(1, job.progress or 0), 14)
  love.graphics.setColor(0.7, 0.7, 0.75, 1)
  local elapsed = math.floor(love.timer.getTime() - job.started)
  love.graphics.print(("%d%%   %dm %02ds elapsed"):format(math.floor((job.progress or 0) * 100),
    elapsed // 60, elapsed % 60), 16, 126)
  love.graphics.print("The first import takes a few minutes on PSP. Keep the system awake.", 16, 144)
end

local function drawMessage()
  drawChrome()
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.printf(Shell.message or "", 16, 40, SCREEN_W - 32)
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
    for i, v in ipairs(GAMES) do if v == autoImport then Shell.cursor = i end end
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
  local v = GAMES[Shell.cursor]
  local n, cols = #GAMES, math.min(COLS, #GAMES)
  if button == "dpleft" then
    Shell.cursor = (Shell.cursor - 2) % n + 1
  elseif button == "dpright" then
    Shell.cursor = Shell.cursor % n + 1
  elseif button == "dpup" then
    if Shell.cursor > cols then Shell.cursor = Shell.cursor - cols end
  elseif button == "dpdown" then
    if Shell.cursor + cols <= n then Shell.cursor = Shell.cursor + cols end
  elseif button == "a" then
    if Shell.ready[v] then
      local ok, err = xpcall(bootGame, debug.traceback, v)
      if not ok then error(err, 0) end
    elseif Shell.roms[v] then
      startImport(v)
    else
      local accepted = {}
      for _, rev in ipairs(GameVersion.revisions(v)) do accepted[#accepted + 1] = rev.sha1 end
      showMessage("No ROM for " .. GameVersion.info(v).displayName .. " was found.\n\n"
        .. "Copy your own canonical US cartridge dump next to the EBOOT or into roms/\n"
        .. "(" .. core.baseDir() .. ")\n\n"
        .. "Accepted SHA-1: " .. table.concat(accepted, ", ") .. "\n\nPress X to go back.")
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
