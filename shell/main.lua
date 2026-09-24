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
local PORTED_BY = "Ported by nahalewski"
-- card artwork supplied with the port (assets/cards/<size>/): <game>_n
-- (normal), <game>_s (selected, glowing), ready / norom badges, empty cards
local CARD_DIR = "assets/cards/psp/"
local cards = {}
local OPTIONS_FILE = "psp_options.lua"
local SCREEN_W, SCREEN_H = 480, 272
local GAME_W, GAME_H = 160, 144
local COLS = 4

local lovepsp = love.lovepsp
local core = require("lovepsp")
local GameVersion = require("src.core.GameVersion")
-- Pokemon Green: the Japanese release shares Blue's version exclusives and
-- Blue is its western form, so Green runs on Blue's engine and imported data
-- (the same Blue ROM import serves both) with its own cart, theme and saves.
-- The Japanese ROM itself is not importable: its layout and text differ.
do
  local b = GameVersion.VERSIONS.blue
  if b and not GameVersion.VERSIONS.green then
    local g = {}
    for k, v in pairs(b) do g[k] = v end
    g.id, g.label, g.displayName, g.launcherName = "green", "Green", "Pokemon Green", "Green"
    g.saveSuffix = "_green"
    GameVersion.VERSIONS.green = g
    GameVersion.ORDER[#GameVersion.ORDER + 1] = "green"
    local isBlue = GameVersion.isBlue
    function GameVersion.isBlue() return isBlue() or GameVersion.current == "green" end
  end
end

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
local VitaUI -- lovepsp.vitaui while a game runs with touch (Vita)
local FoldUI -- lovepsp.foldui: the launcher on Android foldables (3DS skin)
local Options -- the port's options table, defined with the options page below
local function foldActive()
  return FoldUI ~= nil and love._os == "Android" and Shell.page ~= "game" and Shell.page ~= "lid"
end
local fonts = {}
local drawChrome, font -- defined with the drawing code below
local Mods, scanMods    -- the mods page, defined after the options

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

-- A GitHub token for the mod updater lives next to the ROMs, never in the
-- build: github_token.json ({"token": "ghp_..."}) or github_token.txt.
local function readGithubToken()
  for _, dir in ipairs(ROM_DIRS) do
    local raw = love.filesystem.read(dir.mount .. "/github_token.json")
    if raw then
      local ok, Json = pcall(require, "src.link.Json")
      if ok then
        local okd, t = pcall(Json.decode, raw)
        if okd and type(t) == "table" and type(t.token) == "string" then return (t.token:gsub("%s", "")) end
      end
    end
    raw = love.filesystem.read(dir.mount .. "/github_token.txt")
    if raw and raw:match("%S") then return raw:match("^%s*(%S+)") end
  end
  return nil
end

-- Find canonical ROMs (matched by SHA-1, streamed so a 16 MiB GBA dump
-- never has to sit in memory on a 32 MiB console).
-- SHA-1 results keyed by name/size/mtime so a launcher start only hashes
-- files that changed: a folder of GBA dumps otherwise costs seconds of
-- Memory Stick reads and hashing on every boot
local ROM_INDEX_FILE = "rom_index.lua"
local romIndex

local function loadRomIndex()
  if romIndex then return romIndex end
  romIndex = {}
  local chunk = love.filesystem.load(ROM_INDEX_FILE)
  local ok, t = pcall(chunk or function() end)
  if ok and type(t) == "table" then romIndex = t end
  return romIndex
end

local function saveRomIndex()
  local parts = {}
  for key, sha in pairs(romIndex or {}) do
    parts[#parts + 1] = ("[%q] = %q,"):format(key, sha)
  end
  pcall(love.filesystem.write, ROM_INDEX_FILE, "return {" .. table.concat(parts) .. "}")
end

local function romSha1(path, name, info)
  local index = loadRomIndex()
  local key = ("%s|%d|%d"):format(name, info.size or 0, info.modtime or 0)
  local sha = index[key]
  if sha then return sha, false end
  local raw = love.data.hashFile("sha1", path)
  sha = raw and love.data.encode("string", "hex", raw)
  if sha then index[key] = sha end
  return sha, true
end

local function scanRoms()
  Shell.roms, Shell.unknown = {}, {}
  local hashed = false
  for _, dir in ipairs(ROM_DIRS) do
    love.filesystem.unmount(dir.real)
    if love.filesystem.mount(dir.real, dir.mount, true) then
      for _, name in ipairs(love.filesystem.getDirectoryItems(dir.mount)) do
        local lower = name:lower()
        if lower:match("%.gbc?$") or lower:match("%.gba$") then
          local path = dir.mount .. "/" .. name
          local info = love.filesystem.getInfo(path, "file")
          if info and info.size and info.size <= 32 * 1024 * 1024 then
            local sha, fresh = romSha1(path, name, info)
            hashed = hashed or fresh
            local version = sha and GameVersion.forSha1(sha)
            if version then
              if not Shell.roms[version] then
                Shell.roms[version] = { path = path, name = name, sha1 = sha }
              end
              if (version == "blue" or version == "green") and not Shell.roms.green then
                Shell.roms.green = Shell.roms[version]
              end
            else
              Shell.unknown[#Shell.unknown + 1] = name
            end
          end
        end
      end
    end
  end
  if hashed then saveRomIndex() end
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
  pcall(scanMods)
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
Options = { scaling = "fit", smooth = false, swapAB = false, audioRate = "22050", music = true,
                  touch = nil, -- nil: the runtime's default (on for the Vita)
                  layout = love._os == "Android" and "ds" or nil, -- "ds": game on top, controls below
                  pad = nil,    -- nil: the runtime's default (drawn pad on Android, off on the Vita)
                  skin = "gbc", -- DS layout skin: gbc (3DS, G1R sticker, GBC border), sticker, plain, small, off
                  theme = "auto" } -- panel colours: auto (the game's), gameboy, red, ... leafgreen

local function saveOptions()
  local parts = {}
  for k, v in pairs(Options) do
    if k == "music" then k = "musicNative" end
    parts[#parts + 1] = ("%s = %q,"):format(k, tostring(v))
  end
  pcall(love.filesystem.write, OPTIONS_FILE, "return {" .. table.concat(parts) .. "}")
end

local function applyOptions()
  lovepsp.setScaling(Options.scaling, Options.smooth)
  lovepsp.setSwapAB(Options.swapAB)
  lovepsp.env.POKEPORT_AUDIO_RATE = Options.audioRate
  if Options.touch ~= nil and lovepsp.touch then pcall(lovepsp.touch, Options.touch) end
  if Options.layout and lovepsp.layout then pcall(lovepsp.layout, Options.layout) end
  if Options.pad ~= nil and lovepsp.touchPad then pcall(lovepsp.touchPad, Options.pad) end
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
    -- "music" was written by builds whose default was off (Lua synth); the
    -- native renderer made it playable, so the setting moved to a new key
    if t.musicNative ~= nil then Options.music = t.musicNative == "true" end
    if t.touch ~= nil then Options.touch = t.touch == "true" end
    if t.layout == "ds" or t.layout == "single" then Options.layout = t.layout end
    if t.pad ~= nil then Options.pad = t.pad == "true" end
    if t.skin then Options.skin = t.skin end
    if t.theme then Options.theme = t.theme end
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
  love.filesystem.remove(prefix .. "lovepsp-bytecode")
  refresh()
end

-- rows: label, value(), change(dir)   (dir 0 = X pressed)
local OPTIONS_TOP, OPTIONS_ROW_H = 36, 22
local OPTION_ROWS = {
  { "Screen mode", function() return SCALING_NAMES[Options.scaling] or Options.scaling end,
    function(d) Options.scaling = cycle(SCALING, Options.scaling, d == 0 and 1 or d) end },
  { "Smooth scaling", function() return Options.smooth and "ON" or "OFF" end,
    function() Options.smooth = not Options.smooth end },
  { "Confirm button", function() return Options.swapAB and "CIRCLE=A CROSS=B" or "CROSS=A CIRCLE=B" end,
    function() Options.swapAB = not Options.swapAB end },
  { "Music", function() return Options.music and "ON (next launch)" or "OFF (next launch)" end,
    function() Options.music = not Options.music end },
  { "Music sample rate", function() return Options.audioRate .. " Hz (next launch)" end,
    function(d) Options.audioRate = cycle(RATES, Options.audioRate, d == 0 and 1 or d) end },
  { "Screen layout", function()
      if love._os == "PSP" then return "SINGLE (Vita/Android only)" end
      local cur = lovepsp.layout and lovepsp.layout() or "single"
      return cur == "ds" and "DS: game above, controls below" or "SINGLE"
    end,
    function()
      if love._os == "PSP" or not lovepsp.layout then return end
      Options.layout = lovepsp.layout() == "ds" and "single" or "ds"
    end },
  { "Theme", function()
      local ok, V = pcall(require, "lovepsp.vitaui")
      local t = ok and V.themeFor(Options.theme, GAMES[Shell.cursor]) or nil
      return (Options.theme == "auto" and "AUTO > " or "") .. (t and t.name or Options.theme)
    end,
    function(d)
      local ok, V = pcall(require, "lovepsp.vitaui")
      if not ok then return end
      local ids = {}
      for _, t in ipairs(V.THEMES) do ids[#ids + 1] = t.id end
      Options.theme = cycle(ids, Options.theme, d == 0 and 1 or d)
    end },
  { "DS skin", function()
      if love._os ~= "Android" then return "Android foldables only" end
      local names = { gbc = "3DS, G1R sticker, GBC border", sticker = "3DS, G1R sticker", plain = "3DS plain",
                      small = "3DS small screen", off = "OFF" }
      return (names[Options.skin] or Options.skin) .. " (folded DS layout)"
    end,
    function(d)
      if love._os ~= "Android" then return end
      Options.skin = cycle({ "gbc", "sticker", "plain", "small" }, Options.skin, d == 0 and 1 or d)
    end },
  { "On-screen pad", function()
      if love._os == "PSP" or not lovepsp.touchPad then return "n/a" end
      return lovepsp.touchPad() and "ON (drawn D-pad, A, B)" or "OFF (real buttons)"
    end,
    function()
      if love._os == "PSP" or not lovepsp.touchPad then return end
      Options.pad = not lovepsp.touchPad()
    end },
  { "Touch controls", function()
      local on = lovepsp.touch and lovepsp.touch()
      if not on and love._os == "PSP" then return "OFF (Vita only)" end
      return on and "ON (pad in game, tap launcher)" or "OFF"
    end,
    function()
      if not lovepsp.touch then return end
      Options.touch = not lovepsp.touch()
    end },
  { "Mods", function()
      local n = 0
      for _, m in ipairs(Mods.list) do if m.enabled then n = n + 1 end end
      return ("%d of %d enabled (press X)"):format(n, #Mods.list)
    end,
    function(d) if d == 0 then scanMods() Shell.page = "mods" end end },
  { "Delete import", function()
      local v = GAMES[Shell.cursor]
      return Shell.ready[v] and GameVersion.info(v).displayName .. " (press X)" or "nothing for this card"
    end,
    function(d)
      local v = GAMES[Shell.cursor]
      if d == 0 and Shell.ready[v] then
        deleteCache(v)
        showMessage(GameVersion.info(v).displayName .. " data deleted. Saves were kept.\n\nPress X to go back.", "options")
      end
    end },
}

---------------------------------------------------------------- mods

-- Mods live in mods/ (the archive ships upstream's examples; players add
-- their own under save/pokemon-love2d/mods/).  The engine enables every
-- discovered non-experimental mod unless options.lua says otherwise, so
-- the shell records "off" for anything it has not seen before: the vanilla
-- game stays vanilla until a mod is switched on here.
Mods = { list = {}, cursor = 1 }

local function readManifest(id)
  local raw = love.filesystem.read("mods/" .. id .. "/manifest.json")
  if not raw then return nil end
  local ok, Json = pcall(require, "src.link.Json")
  local m = ok and Json.decode(raw) or nil
  if type(m) ~= "table" then return nil end
  return m
end

-- Reading 140 manifests from the Memory Stick costs seconds, so the scan
-- result is cached in mods_cache.lua keyed by the folder listing: the cache
-- is rebuilt only when a mod folder appears or disappears.
local MODS_CACHE_FILE = "mods_cache.lua"

local function serializeMods(key, entries)
  local out = { "return {key=", ("%q"):format(key), ",entries={" }
  for _, e in ipairs(entries) do
    out[#out + 1] = ("{dir=%q,id=%q,name=%q,version=%q,description=%q"):format(
      e.dir, e.id, e.name, e.version, e.description)
    if type(e.games) == "table" then
      local g = {}
      for _, v in ipairs(e.games) do g[#g + 1] = ("%q"):format(tostring(v)) end
      out[#out + 1] = ",games={" .. table.concat(g, ",") .. "}"
    end
    out[#out + 1] = "},"
  end
  out[#out + 1] = "}}"
  return table.concat(out)
end

local function modEntries()
  Shell.rawModScan = true
  local names = love.filesystem.getDirectoryItems("mods")
  Shell.rawModScan = false
  table.sort(names)
  local key = table.concat(names, "\n")
  local chunk = love.filesystem.load(MODS_CACHE_FILE)
  local ok, t = pcall(chunk or function() end)
  if ok and type(t) == "table" and t.key == key and type(t.entries) == "table" then
    return t.entries
  end
  local entries = {}
  for _, dir in ipairs(names) do
    local m = readManifest(dir)
    if m then
      entries[#entries + 1] = {
        dir = dir, id = tostring(m.id or dir), name = tostring(m.name or dir),
        version = tostring(m.version or ""), description = tostring(m.description or ""),
        games = type(m.games) == "table" and m.games or nil,
      }
    end
  end
  pcall(love.filesystem.write, MODS_CACHE_FILE, serializeMods(key, entries))
  return entries
end

scanMods = function()
  local SaveData = require("src.core.SaveData")
  local options = SaveData.loadOptions()
  local changed = false
  Mods.list = {}
  for _, e in ipairs(modEntries()) do
    if SaveData.modEnabled(options, e.id) == nil then
      SaveData.setModEnabled(options, e.id, false)
      changed = true
    end
    Mods.list[#Mods.list + 1] = {
      dir = e.dir, id = e.id, name = e.name, version = e.version, games = e.games,
      description = e.description,
      enabled = SaveData.modEnabled(options, e.id) == true,
    }
  end
  table.sort(Mods.list, function(a, b) return a.name < b.name end)
  if changed then SaveData.saveOptions(options) end
  if Mods.cursor > #Mods.list then Mods.cursor = math.max(1, #Mods.list) end
end

-- The engine's loader reads every folder under mods/ at boot; with the
-- community mods bundled that is 140 manifests off the Memory Stick for
-- mods that are off.  While a game runs, the listing only shows the mods
-- enabled for it (Shell.enabledModDirs, set by bootGame).
do
  local rawItems = love.filesystem.getDirectoryItems
  love.filesystem.getDirectoryItems = function(path, ...)
    local items = rawItems(path, ...)
    if Shell.enabledModDirs and not Shell.rawModScan
        and (path == "mods" or path == "mods/") then
      local out = {}
      for _, n in ipairs(items) do if Shell.enabledModDirs[n] then out[#out + 1] = n end end
      return out
    end
    return items
  end
end

-- The loader reads a per-game entry (options.modsByVersion[version][id])
-- before the shared flag, and the desktop launcher writes those, so a
-- toggle here sets the shared flag and clears every per-game override:
-- what the card shows is what the game loads.
local function toggleMod(entry)
  local SaveData = require("src.core.SaveData")
  local options = SaveData.loadOptions()
  entry.enabled = not entry.enabled
  SaveData.setModEnabled(options, entry.id, entry.enabled)
  for _, v in ipairs(GameVersion.ORDER or GAMES) do
    SaveData.setModEnabled(options, entry.id, entry.enabled, v)
  end
  SaveData.saveOptions(options)
end

local function drawMods()
  drawChrome("X toggle   Circle back")
  love.graphics.setFont(font(12))
  if #Mods.list == 0 then
    love.graphics.setColor(0.8, 0.8, 0.85, 1)
    love.graphics.printf("No mods found. Put a mod folder (with manifest.json) under\n"
      .. "save/pokemon-love2d/mods/ on the memory stick.", 16, 44, SCREEN_W - 32)
    return
  end
  local rowH, top, visible = 22, 34, 7
  local first = math.max(1, math.min(Mods.cursor - 3, #Mods.list - visible + 1))
  local y = top
  for i = first, math.min(#Mods.list, first + visible - 1) do
    local m = Mods.list[i]
    local selected = i == Mods.cursor
    if selected then
      love.graphics.setColor(1, 1, 1, 0.12)
      love.graphics.rectangle("fill", 8, y - 3, SCREEN_W - 16, rowH)
    end
    love.graphics.setColor(m.enabled and { 0.45, 0.95, 0.55, 1 } or { 0.6, 0.6, 0.66, 1 })
    love.graphics.print(m.enabled and "[ON] " or "[  ] ", 16, y)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(m.name .. "  " .. m.version, 56, y)
    y = y + rowH
  end
  local m = Mods.list[Mods.cursor]
  love.graphics.setColor(0.8, 0.8, 0.85, 1)
  love.graphics.printf(m.description, 16, top + visible * rowH + 4, SCREEN_W - 32)
  love.graphics.setColor(0.6, 0.6, 0.66, 1)
  love.graphics.printf("Changes apply the next time a game starts.", 16, SCREEN_H - 52, SCREEN_W - 32)
end

local function modsPress(button)
  if button == "dpup" then Mods.cursor = (Mods.cursor - 2) % math.max(1, #Mods.list) + 1
  elseif button == "dpdown" then Mods.cursor = Mods.cursor % math.max(1, #Mods.list) + 1
  elseif button == "a" and Mods.list[Mods.cursor] then toggleMod(Mods.list[Mods.cursor])
  elseif button == "b" or button == "y" then Shell.page = "options" end
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
    love.filesystem.remove(prefix .. "lovepsp-bytecode")
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
      if Shell.ready[job.version] then pcall(precompileCache, job.version) end
      local secs = math.floor(love.timer.getTime() - job.started)
      log(("import: %s finished in %ds"):format(job.version, secs))
      showMessage(("%s is ready (imported in %dm %02ds).\n\nPress X to continue.")
        :format(GameVersion.info(job.version).displayName, secs // 60, secs % 60))
      return
    end
  until love.timer.getTime() >= deadline
end

---------------------------------------------------------------- game

-- The importer writes data/generated/*.lua as Lua source (2.6 MB for a Gen 1
-- game) which the PSP has to parse on every boot.  Once a cache is complete
-- we replace each file with stripped bytecode: half the bytes to read from
-- the Memory Stick and about a quarter of the load time.  Data.load asks
-- for text chunks, so bootGame widens the global load() for these files.
local BYTECODE_MARKER = "lovepsp-bytecode"

local function precompileCache(version)
  local prefix = GameVersion.info(version).cachePrefix
  if love.filesystem.getInfo(prefix .. BYTECODE_MARKER) then return end
  local dir = prefix .. "data/generated"
  local t0 = love.timer.getTime()
  local converted = 0
  -- the Memory Stick's FAT driver lists 8.3 names in upper case (MAPS.LUA);
  -- the importer wrote lower-case names and FAT lookups ignore case
  for _, item in ipairs(love.filesystem.getDirectoryItems(dir)) do
    if item:lower():match("%.lua$") then
      local path = dir .. "/" .. item:lower()
      local bytes = love.filesystem.read(path)
      if bytes and bytes:byte(1) ~= 27 then
        local chunk, err = load(bytes, "@" .. path, "t", {})
        if chunk then
          local dump = string.dump(chunk, true)
          chunk = nil
          local ok, werr = love.filesystem.write(path, dump)
          if ok then converted = converted + 1 else log("precompile: write " .. path .. ": " .. tostring(werr)) end
        else
          log("precompile: " .. tostring(err))
        end
      elseif not bytes then
        log("precompile: cannot read " .. path)
      end
      bytes = nil
      collectgarbage()
    end
  end
  love.filesystem.write(prefix .. BYTECODE_MARKER, "1\n")
  log(("precompiled %d data files for %s in %.1fs"):format(converted, version, love.timer.getTime() - t0))
end

local rawLoad = load
local function installBytecodeLoad()
  if load ~= rawLoad then return end
  load = function(chunk, name, mode, env)
    if mode == "t" and type(chunk) == "string" and chunk:byte(1) == 27
        and type(name) == "string" and name:find("data/generated/", 1, true) then
      mode = "bt"
    end
    return rawLoad(chunk, name, mode, env)
  end
end

local function bootGame(version)
  if FoldUI then FoldUI.detach() end
  local t0 = love.timer.getTime()
  local marks = {}
  local function mark(name) marks[#marks + 1] = ("%s %.2fs"):format(name, love.timer.getTime() - t0) end
  Shell.page = "game"
  love.graphics.setDefaultFilter("nearest", "nearest")
  local loadProf
  if lovepsp.env.LOVEPSP_PROFILE == "1" then
    -- where boot time goes: file loads, image decodes, module requires
    loadProf = {}
    local function wrapLoad(tbl, key, name)
      local fn = tbl[key]
      if type(fn) ~= "function" then return end
      local slot = { time = 0, calls = 0 }
      loadProf[name] = slot
      tbl[key] = function(...)
        local t1 = core.time()
        local a, b = fn(...)
        slot.time = slot.time + (core.time() - t1)
        slot.calls = slot.calls + 1
        return a, b
      end
    end
    wrapLoad(love.filesystem, "load", "fs_load")
    wrapLoad(love.filesystem, "read", "fs_read")
    wrapLoad(love.filesystem, "getInfo", "fs_info")
    wrapLoad(love.graphics, "newImage", "newImage")
    wrapLoad(love.image, "newImageData", "newImageData")
    wrapLoad(love.graphics, "newShader", "newShader")
    wrapLoad(_G, "require", "require")
  end
  pcall(function() require("src.core.RequireGuard").capture() end)
  GameVersion.set(version)
  local CacheFs = require("src.import.CacheFs")
  CacheFs.prefix = GameVersion.cachePrefix()
  CacheFs.mountVersion(GameVersion.get())
  local SaveData = require("src.core.SaveData")
  SaveData.setCart(nil, nil)
  require("src.core.GameSpeed").setAllowed(nil)
  pcall(precompileCache, version)
  installBytecodeLoad()
  -- only the mods enabled for this game are visible to the loader
  do
    scanMods()
    local SaveData = require("src.core.SaveData")
    local options = SaveData.loadOptions()
    Shell.enabledModDirs = {}
    for _, m in ipairs(Mods.list) do
      if SaveData.modEnabled(options, m.id, version) == true then Shell.enabledModDirs[m.dir] = true end
    end
  end
  love.window.setTitle(GameVersion.info().displayName)
  -- the engine lays out one 160x144 Game Boy screen; lovepsp scales the
  -- window to the PSP's 480x272 panel on present
  love.window.setMode(GAME_W, GAME_H)
  fonts, Shell.art, cards = {}, {}, {}
  collectgarbage()
  -- hand the per-sample chip synthesis to the runtime's native renderer
  -- (lovepsp.chipnative / apu.c): the engine's Lua synth costs ~370 us a
  -- sample on the PSP, far too slow for music; the C port renders the same
  -- samples ~40x faster and keeps the song interpreter in Lua
  do
    local ok, err = pcall(function() return require("lovepsp.chipnative").install() end)
    if not ok then log("chipnative: " .. tostring(err)) end
  end
  if not Options.music then
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
  mark("mount")
  Game:load({})
  mark("load")
  collectgarbage()
  mark("gc")
  Shell.bootMarks = marks
  if loadProf then
    local parts = {}
    for name, slot in pairs(loadProf) do
      parts[#parts + 1] = ("%s %.2fs/%d"):format(name, slot.time, slot.calls)
    end
    table.sort(parts)
    log("boot profile: " .. table.concat(parts, "; "))
  end
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
    wrap(require("src.core.StateStack"), "update", "stack_update")
    wrap(require("src.core.Input"), "step", "input_step")
    wrap(require("src.mods.Runtime"), "call", "mod_call")
    wrap(require("src.render.Renderer"), "beginFrame", "r_begin")
    wrap(require("src.render.Renderer"), "endFrame", "r_end")
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
  log(("game: %s loaded, Lua heap %d KiB (%s)"):format(version, math.floor(collectgarbage("count")),
    table.concat(marks, ", ")))
  -- Vita: floating touch sidebars (mods, and a menu replacing START)
  VitaUI = nil
  if lovepsp.touch and lovepsp.touch() and lovepsp.setOverlay then
    local okUI, ui = pcall(require, "lovepsp.vitaui")
    if okUI then
      VitaUI = ui
      local rows = {}
      for _, row in ipairs(OPTION_ROWS) do
        if row[1] ~= "Mods" and row[1] ~= "Delete import" then rows[#rows + 1] = row end
      end
      VitaUI.attach(Game, {
        font = font, log = log, version = version, generation = gen,
        optionRows = rows,
        applyOptions = function() applyOptions() saveOptions() end,
        options = function() return OPTION_ROWS end,
        page = function() return Shell.page end,
        trainer = function() return "PLAYER" end,
        mods = function() scanMods() return Mods.list end,
        toggleMod = toggleMod,
        token = readGithubToken,
        skin = function() return Options.skin end,
        theme = function() return Options.theme end,
        setTheme = function(id) Options.theme = id saveOptions() end,
        padDefault = function()
          if Options.pad ~= nil then return Options.pad end
          return love._os ~= "Vita"
        end,
        invalidateMods = function() love.filesystem.remove("mods_cache.lua") end,
        removeTree = removeTree,
        restart = function(bootVersion)
          pcall(love.filesystem.write, "boot_once.txt", bootVersion or "launcher")
          love.event.quit("restart")
        end,
      })
    else
      log("vitaui: " .. tostring(ui))
    end
  end
  -- what the mod loader made of the enabled mods, for lovepsp.log
  local status = Game and Game.modStatus
  if status then
    local parts = {}
    for _, m in ipairs(status.available or {}) do
      if m.enabled then
        parts[#parts + 1] = ("%s=%s%s"):format(m.id or "?", m.state or "?",
          m.error and (" (" .. tostring(m.error):gsub("\n", " "):sub(1, 160) .. ")") or "")
      end
    end
    log(("mods: %d available, %d loaded; %s"):format(#(status.available or {}),
      #(status.loaded or {}), #parts > 0 and table.concat(parts, "; ") or "none enabled"))
    for _, e in ipairs(status.errors or {}) do log("mod error: " .. tostring(e):sub(1, 300)) end
  end
end

---------------------------------------------------------------- drawing

font = function(size)
  if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
  return fonts[size]
end

local function card(name)
  local img = cards[name]
  if img == nil then
    local ok, loaded = pcall(love.graphics.newImage, CARD_DIR .. name .. ".png")
    img = ok and loaded or false
    if img then img:setFilter("nearest", "nearest") end
    cards[name] = img
  end
  return img or nil
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

drawChrome = function(subtitle)
  drawBackground()
  love.graphics.setColor(0.80, 0.14, 0.18, 1)
  love.graphics.rectangle("fill", 0, 0, SCREEN_W, 24)
  love.graphics.setColor(0.55, 0.08, 0.10, 1)
  love.graphics.rectangle("fill", 0, 24, SCREEN_W, 2)
  love.graphics.setFont(font(12))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(TITLE, 10, 8)
  love.graphics.setColor(1, 0.85, 0.85, 1)
  love.graphics.printf(subtitle or PORTED_BY, 10, 8, SCREEN_W - 20, "right")
  -- the credit the upstream licence requires in every launcher, plus the port's
  love.graphics.setColor(0.85, 0.75, 0.55, 1)
  love.graphics.printf(PORTED_BY, 10, SCREEN_H - 40, SCREEN_W - 20, "right")
  love.graphics.setColor(0.62, 0.64, 0.72, 1)
  love.graphics.printf(CREDIT, 10, SCREEN_H - 28, SCREEN_W - 20)
end

local function fitScale(img, maxW, maxH)
  local w, h = img:getDimensions()
  local s = math.min(maxW / w, maxH / h)
  if s >= 1 then s = math.floor(s) end
  return s, w * s, h * s
end

-- the game's card: the supplied artwork when the port ships it, else a
-- drawn cartridge with the player's own extracted logo on the label
local function drawArtCard(version, x, y, w, h, selected)
  local img = card(version .. (selected and "_s" or "_n")) or card(version .. "_n")
  if not img then return false end
  local iw, ih = img:getDimensions()
  local s = math.min(w / iw, (h - 16) / ih)
  local dw, dh = iw * s, ih * s
  love.graphics.setColor(1, 1, 1, selected and 1 or 0.72)
  love.graphics.draw(img, x + (w - dw) / 2, y + (h - 16 - dh) / 2, 0, s, s)
  h = h - 16
  -- status badge centred under the card
  local ready, rom = Shell.ready[version], Shell.roms[version]
  local badge = ready and card("ready") or (not rom and card("norom")) or nil
  local by = y + (h + dh) / 2 + 1
  if badge then
    local bw, bh = badge:getDimensions()
    local bs = 13 / bh
    love.graphics.setColor(1, 1, 1, selected and 1 or 0.8)
    love.graphics.draw(badge, x + (w - bw * bs) / 2, by, 0, bs, bs)
  elseif rom then
    love.graphics.setFont(font(12))
    love.graphics.setColor(0.12, 0.10, 0.05, 0.9)
    love.graphics.rectangle("fill", x + w / 2 - 30, by, 60, 13, 3, 3)
    love.graphics.setColor(1, 0.85, 0.35, 1)
    love.graphics.printf("IMPORT", x + w / 2 - 30, by + 2, 60, "center")
  end
  return true
end

local function drawCartridge(version, x, y, w, h, selected)
  if drawArtCard(version, x, y, w, h, selected) then return end
  local st = STYLE[version] or DEFAULT_STYLE
  local info = GameVersion.info(version)
  local ready, rom = Shell.ready[version], Shell.roms[version]
  local art = Shell.art[version] or {}
  local mul = selected and 1 or 0.62
  love.graphics.setColor(0, 0, 0, 0.35)
  love.graphics.rectangle("fill", x + 3, y + 4, w, h)
  setColor(st.body, mul)
  love.graphics.polygon("fill", x + 8, y, x + w - 8, y, x + w, y + 8, x + w, y + h, x, y + h, x, y + 8)
  local lx, ly, lw, lh = x + 8, y + 18, w - 16, h - 30
  setColor(st.label, mul)
  love.graphics.rectangle("fill", lx, ly, lw, lh)
  love.graphics.setColor(1, 1, 1, mul)
  if art.logo then
    local s, sw, sh = fitScale(art.logo, lw - 6, lh * 0.55)
    love.graphics.draw(art.logo, lx + (lw - sw) / 2, ly + 3, 0, s, s)
    if art.mascot then
      local ms, mw, mh = fitScale(art.mascot, lw * 0.55, lh - sh - 4)
      love.graphics.draw(art.mascot, lx + lw - mw - 3, ly + lh - mh - 2, 0, ms, ms)
    end
  else
    love.graphics.setFont(font(12))
    setColor(st.text, mul)
    love.graphics.printf("POKEMON", lx, ly + 6, lw, "center")
    love.graphics.printf(info.label:upper(), lx, ly + 20, lw, "center")
  end
  local status, col
  if ready then status, col = "READY", { 0.45, 0.95, 0.55 }
  elseif rom then status, col = "IMPORT", { 1, 0.85, 0.35 }
  else status, col = "NO ROM", { 0.62, 0.62, 0.68 } end
  love.graphics.setFont(font(12))
  setColor(col, mul)
  love.graphics.printf(status, x, y + h - 10, w, "center")
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
  local areaY, areaH = 30, 172
  local w = math.floor((SCREEN_W - 24 - (cols - 1) * gap) / cols)
  local h = math.floor((areaH - (rows - 1) * gap) / rows)
  if w > 140 then w = 140 end
  if h > 120 then h = 120 end
  -- art cards are 16:9-ish and carry a badge underneath
  if card(GAMES[1] .. "_n") then h = math.min(h, math.floor(w * 0.6) + 16) end
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
  love.graphics.printf(hint, 10, 208, SCREEN_W - 20, "center")
  love.graphics.setColor(0.62, 0.62, 0.68, 1)
  local foot
  if GameVersion.generation(v) ~= 1 then
    foot = "Gen " .. GameVersion.generation(v) .. " is experimental on PSP and may run out of memory"
  elseif #Shell.unknown > 0 then
    foot = "Not supported: " .. table.concat(Shell.unknown, ", ")
  else
    foot = "Select+R / Select+L: " .. (SCALING_NAMES[Options.scaling] or Options.scaling)
  end
  love.graphics.printf(foot, 10, 221, SCREEN_W - 20, "center")
end

local function drawOptions()
  drawChrome("Circle: back")
  love.graphics.setFont(font(12))
  local y = OPTIONS_TOP
  for i, row in ipairs(OPTION_ROWS) do
    local selected = i == Shell.optCursor
    if selected then
      love.graphics.setColor(1, 1, 1, 0.12)
      love.graphics.rectangle("fill", 8, y - 3, SCREEN_W - 16, OPTIONS_ROW_H)
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print((selected and "> " or "  ") .. row[1], 16, y)
    love.graphics.setColor(0.6, 0.9, 1, 1)
    love.graphics.print("< " .. row[2]() .. " >", 176, y)
    y = y + OPTIONS_ROW_H
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

-- Foldables (Android): the closed 3DS lid fills the screen until the
-- phone is unfolded (hinge angle) or any button / tap, then the launcher.
local lidImage
local lidCanvas
local function drawLid()
  love.graphics.clear(0.02, 0.02, 0.03, 1)
  if lidImage == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/skin3ds/lid.png")
    lidImage = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  if not lidImage then return end
  -- the closed lid fills the whole physical screen: it goes through the
  -- overlay layer (screen-sized), not the launcher's 480x272 window
  local sw, sh = SCREEN_W, SCREEN_H
  if lovepsp.screen then local ok, w, h = pcall(lovepsp.screen) if ok and w then sw, sh = w, h end end
  local okV, V = pcall(require, "lovepsp.vitaui")
  local k = okV and V.hudScale and V.hudScale() or 1
  if lovepsp.setOverlay then
    if not lidCanvas or lidCanvas:getWidth() ~= sw * k or lidCanvas:getHeight() ~= sh * k then
      lidCanvas = love.graphics.newCanvas(sw * k, sh * k)
    end
    love.graphics.push("all")
    love.graphics.setCanvas(lidCanvas)
    love.graphics.clear(0.02, 0.02, 0.03, 1)
    if okV and V.hdBegin then V.hdBegin(k) end
  end
  -- full width; a taller screen gets the shell's grey above and below
  local iw, ih = lidImage:getDimensions()
  local s = sw / iw
  love.graphics.setColor(0.16, 0.16, 0.17, 1)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  if okV and V.drawSkin then
    V.drawSkin("lid.png", 0, math.floor((sh - ih * s) / 2), s)
  else
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(lidImage, 0, math.floor((sh - ih * s) / 2), 0, s, s)
  end
  if lovepsp.setOverlay then
    if okV and V.hdEnd then V.hdEnd() end
    love.graphics.setCanvas()
    love.graphics.pop()
    lovepsp.setOverlay(lidCanvas)
  end
end

-- the lid covers whatever was on screen while the phone is closed (the
-- cover screen); opening the phone returns to it
local function coverScreen()
  if not lovepsp.display then return false end
  local ok, dw, dh = pcall(lovepsp.display)
  return ok and dw and dh and dh > 0 and dw / dh > 1.8 or false
end
local function lidShow()
  if Shell.page == "lid" then return end
  Shell.lidReturn = Shell.page
  Shell.page = "lid"
  -- the frame takes the display's shape so the lid reaches the edges
  local okV, V = pcall(require, "lovepsp.vitaui")
  if okV and V.fullSplit and lovepsp.layout then
    local ft, fb = V.fullSplit()
    if ft then lovepsp.layout(nil, ft, fb) end
  end
end
local function lidDone(byHand)
  -- on the cover screen only unfolding opens the lid
  if byHand and coverScreen() then return end
  Shell.page = Shell.lidReturn or "cards"
  if VitaUI and VitaUI.relayout then VitaUI.relayout() end
  Shell.lidReturn = nil
  Shell.lidSnooze = byHand or false   -- dismissed by hand: stay open until the phone really opens
  if lovepsp.setOverlay then lovepsp.setOverlay(nil) end
  if FoldUI and FoldUI.swallowTouch then FoldUI.swallowTouch() end
end
local function foldCheck()
  if love._os ~= "Android" or not lovepsp.hinge then return end
  local hinge = lovepsp.hinge()
  local folded = hinge >= 0 and hinge < 60
  -- the lid is a landscape picture: only on a landscape display (the
  -- physical one; the logical frame is always taller than wide here)
  if folded and lovepsp.display then
    local ok, dw, dh = pcall(lovepsp.display)
    if ok and dw and dh and dw > 0 and dh > dw * 1.1 then folded = false end
  end
  if folded then
    if not Shell.lidSnooze then lidShow() end
  else
    Shell.lidSnooze = false
    if Shell.page == "lid" then lidDone() end
  end
end

function love.load()
  local t0 = love.timer.getTime()
  love.graphics.setDefaultFilter("nearest", "nearest")
  loadOptions()
  refresh()
  -- the foldable launcher (3DS skin): attach once, active while the phone is folded
  if love._os == "Android" then
    local okF, F = pcall(require, "lovepsp.foldui")
    if okF then
      FoldUI = F
      local okB, info = pcall(require, "lovepsp.build_info")
      FoldUI.attach({
        font = font,
        theme = function() return Options.theme end,
        skin = function() return Options.skin end,
        version = function() return GAMES[Shell.cursor] end,
        game = function()
          local v = GAMES[Shell.cursor]
          local rom = Shell.roms[v]
          return { version = v, name = GameVersion.info(v).displayName, ready = Shell.ready[v],
                   rom = rom and rom.name or nil,
                   save = love.filesystem.getInfo("save_" .. v .. ".lua") and "save_" .. v .. ".lua" or nil }
        end,
        primary = function() love.gamepadpressed(nil, "a") end,
        moveGame = function(d) love.gamepadpressed(nil, d < 0 and "dpleft" or "dpright") end,
        rescan = function() refresh() end,
        mods = function() scanMods() return Mods.list end,
        toggleMod = toggleMod,
        rescanMods = function() love.filesystem.remove("mods_cache.lua") scanMods() end,
        token = readGithubToken,
        applyOptions = function() applyOptions() saveOptions() end,
        options = function() return OPTION_ROWS end,
        page = function() return Shell.page end,
        trainer = function() return "PLAYER" end,
        versionLabel = okB and type(info) == "table" and ("v" .. tostring(info.port or "?") .. " / gen1recomp " .. tostring(info.upstream or ""):sub(1, 9)) or "",
        portVersion = okB and type(info) == "table" and info.port or "",
        romDir = core.baseDir(),
      })
    else
      log("foldui: " .. tostring(F))
    end
  end
  -- a foldable that is not open yet shows the lid first
  -- the Fold app always starts on the closed lid (the top shell); a tap, any
  -- button, or unfolding the phone opens it
  foldCheck()
  log(("launcher: ready in %.2fs (%.2fs since power-on)"):format(
    love.timer.getTime() - t0, love.timer.getTime()))
  -- boot_once.txt: written before a restart (Vita menu QUIT -> "launcher",
  -- mods APPLY -> the game to relaunch); consumed here
  local once = love.filesystem.read("boot_once.txt")
  once = once and once:match("%a+")
  if once then love.filesystem.remove("boot_once.txt") end
  -- a direct-boot shortcut: save/pokemon-love2d/autoboot.txt naming a version
  local auto = love.filesystem.read("autoboot.txt")
  auto = auto and auto:match("%a+")
  if once and once ~= "launcher" and Shell.ready[once] then
    bootGame(once)
  elseif auto and not once and Shell.ready[auto] then
    bootGame(auto)
  end
  -- LOVEPSP_AUTOIMPORT=<version> in env.txt: start that import on boot
  -- (used to drive the port in an emulator with no input injection)
  local autoImport = lovepsp.env.LOVEPSP_AUTOIMPORT
  if autoImport and Shell.roms[autoImport] and not Shell.ready[autoImport] then
    for i, v in ipairs(GAMES) do if v == autoImport then Shell.cursor = i end end
    startImport(autoImport)
  end
end

-- Taps on the launcher pages (Vita touch screen, or the mouse on a desktop
-- with LOVEPSP_TOUCH=1).  Only the first finger counts; a tap is the frame
-- it lands.  Tapping a card selects it, tapping the selected card presses X;
-- the header line stands in for the Triangle / Square / Circle hints.
local touchWasDown = false
local function tapAt(x, y)
  if Shell.page == "message" then
    Shell.page = Shell.messageBack
    return
  end
  if y < 24 then
    if Shell.page == "cards" then
      love.gamepadpressed(nil, x < SCREEN_W * 0.72 and "y" or "x")
    else
      love.gamepadpressed(nil, "b")
    end
    return
  end
  if Shell.page == "cards" then
    for i in ipairs(GAMES) do
      local cx, cy, cw, ch = cardRect(i)
      if x >= cx and x < cx + cw and y >= cy and y < cy + ch + 16 then
        if Shell.cursor == i then love.gamepadpressed(nil, "a") else Shell.cursor = i end
        return
      end
    end
  elseif Shell.page == "options" then
    local i = math.floor((y - OPTIONS_TOP + 3) / OPTIONS_ROW_H) + 1
    if i >= 1 and i <= #OPTION_ROWS then
      if Shell.optCursor == i then
        love.gamepadpressed(nil, x < 176 and "dpleft" or "a")
      else
        Shell.optCursor = i
      end
    end
  elseif Shell.page == "mods" and #Mods.list > 0 then
    local rowH, top, visible = 22, 34, 7
    local first = math.max(1, math.min(Mods.cursor - 3, #Mods.list - visible + 1))
    local i = first + math.floor((y - top + 3) / rowH)
    if i >= first and i <= math.min(#Mods.list, first + visible - 1) then
      if Mods.cursor == i then love.gamepadpressed(nil, "a") else Mods.cursor = i end
    end
  end
end

local function pollTaps()
  if not lovepsp.touches then return end
  local ok, touches = pcall(lovepsp.touches)
  local t = ok and touches and touches[1]
  if t and not touchWasDown then tapAt(t.x, t.y) end
  touchWasDown = t ~= nil and t ~= false
end

function love.update(dt)
  foldCheck()
  -- on the fold launcher a tap anywhere closes a message (the panel's taps
  -- never reach the launcher's own tap handler there)
  if Shell.page == "message" and foldActive() and lovepsp.touches then
    local ok, t = pcall(lovepsp.touches)
    local down = ok and t and t[1] and true or false
    if down and not Shell.msgTouch then
      Shell.page = Shell.messageBack
      if FoldUI and FoldUI.swallowTouch then FoldUI.swallowTouch() end
    end
    Shell.msgTouch = down
  end
  if Shell.page == "lid" then
    if lovepsp.touches then
      local ok, t = pcall(lovepsp.touches)
      if ok and t and t[1] then lidDone(true) end
    end
    return
  end
  if Shell.page == "game" then
    require("src.core.PlatformHooks").update(Game, dt)
    if VitaUI then VitaUI.update(dt) end
    return
  elseif Shell.page == "import" then
    stepImport()
    if foldActive() then FoldUI.update(dt) end
  elseif foldActive() then
    -- the foldable launcher takes taps and the pad; the classic pages stay
    -- for the top screen (import progress, messages)
    if Shell.page == "options" or Shell.page == "mods" then Shell.page = "cards" end
    FoldUI.update(dt)
  else
    pollTaps()
  end
end

function love.draw()
  if Shell.page == "lid" then return drawLid() end
  if Shell.page == "game" then return Game:draw() end
  if Shell.page == "cards" and foldActive() then return FoldUI.drawTop() end
  if Shell.page == "import" then return drawImport() end
  if Shell.page == "message" then return drawMessage() end
  if Shell.page == "options" then return drawOptions() end
  if Shell.page == "mods" then return drawMods() end
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
  if Shell.page == "lid" then return lidDone(true) end
  if Shell.page == "game" then return Game:gamepadpressed(joystick, button) end
  if Shell.page == "cards" and foldActive() and joystick ~= nil and FoldUI.press(button) then return end
  if Shell.page == "message" then
    if button == "a" or button == "b" then Shell.page = Shell.messageBack end
    return
  end
  if Shell.page == "cards" then return cardsPress(button) end
  if Shell.page == "options" then return optionsPress(button) end
  if Shell.page == "mods" then return modsPress(button) end
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
