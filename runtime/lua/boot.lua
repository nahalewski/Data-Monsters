-- lovepsp boot: builds the love.* API on top of the native modules, runs
-- conf.lua / main.lua from the game archive and drives love.run().
--
-- Native modules (C): love.graphics, love.filesystem, love.image,
-- love.sound, love.audio, lovepsp (platform helpers) and bit.
-- Implemented here in Lua: love.timer, event, keyboard, mouse, joystick,
-- touch, math, data, system, window, plus the run loop and error screen.

local newTransform = ...
local core = require("lovepsp")

love = love or {}
love._os = core.os()
love._version = "11.5"
love._version_major, love._version_minor, love._version_revision = 11, 5, 0
love._version_codename = "Mysterious Mysteries"
love._lovepsp = core.version
function love.getVersion()
  return 11, 5, 0, "Mysterious Mysteries"
end
function love.isVersionCompatible() return true end
function love.hasDeprecationOutput() return false end
function love.setDeprecationOutput() end

-- LuaJIT / 5.1 conveniences the game may reach for on its 5.1 code paths
bit = require("bit")
unpack = unpack or table.unpack
loadstring = loadstring or load
math.pow = math.pow or function(a, b) return a ^ b end
-- functions Lua 5.4 dropped that LuaJIT (the engine's home) still has
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
math.ldexp = math.ldexp or function(m, e) return m * 2.0 ^ e end
math.frexp = math.frexp or function(x)
  if x == 0 then return 0.0, 0 end
  local e = math.floor(math.log(math.abs(x), 2)) + 1
  return x / 2.0 ^ e, e
end
math.log10 = math.log10 or function(x) return math.log(x, 10) end
math.cosh = math.cosh or function(x) return (math.exp(x) + math.exp(-x)) / 2 end
math.sinh = math.sinh or function(x) return (math.exp(x) - math.exp(-x)) / 2 end
math.tanh = math.tanh or function(x) local a, b = math.exp(x), math.exp(-x) return (a - b) / (a + b) end
math.mod = math.mod or math.fmod
table.getn = table.getn or function(t) return #t end
table.maxn = table.maxn or function(t)
  local n = 0
  for k in pairs(t) do if type(k) == "number" and k > n then n = k end end
  return n
end

-- setfenv/getfenv for Lua functions, via their _ENV upvalue (the engine
-- sandboxes data chunks with setfenv(f, {}))
if not setfenv then
  local function envIndex(f)
    local i = 1
    while true do
      local name = debug.getupvalue(f, i)
      if name == "_ENV" then return i elseif not name then return nil end
      i = i + 1
    end
  end
  function setfenv(f, env)
    if type(f) == "number" then f = debug.getinfo(f + 1, "f").func end
    local i = envIndex(f)
    if i then
      debug.upvaluejoin(f, i, function() return env end, 1)
    end
    return f
  end
  function getfenv(f)
    if type(f) == "number" then f = debug.getinfo((f or 1) + 1, "f").func end
    local i = f and envIndex(f)
    if i then
      local _, v = debug.getupvalue(f, i)
      return v
    end
    return _G
  end
end

-- LuaJIT's string.format("%d", 2.5) truncates; Lua 5.4 raises "number has
-- no integer representation".  The engine was written against LuaJIT, so
-- retry with floored arguments when that is what went wrong.
do
  local format = string.format
  string.format = function(fmt, ...)
    local ok, res = pcall(format, fmt, ...)
    if ok then return res end
    if type(res) == "string" and res:find("no integer representation", 1, true) then
      local args = table.pack(...)
      for i = 1, args.n do
        local v = args[i]
        if math.type(v) == "float" then
          local iv = math.tointeger(v) or math.tointeger(v < 0 and math.ceil(v) or math.floor(v))
          if iv then args[i] = iv end
        end
      end
      return format(fmt, table.unpack(args, 1, args.n))
    end
    error(res, 2)
  end
end

---------------------------------------------------------------- environment
-- os.getenv is how gen1recomp takes per-platform tunables.  The PSP has no
-- environment, so values come from built-in defaults, then lovepsp/env.lua in
-- the archive, then save/env.txt (KEY=VALUE lines) which players can edit.
local ENV = {}
local function loadEnvText(text)
  for line in (text or ""):gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and not line:match("^%s*#") then ENV[k] = v end
  end
end
os.getenv = function(k) return ENV[k] end
love._env = ENV

---------------------------------------------------------------- modules
love.filesystem = require("love.filesystem")
love.graphics = require("love.graphics")
love.image = require("love.image")
love.sound = require("love.sound")
love.audio = require("love.audio")

do
  local ok, envDefaults = pcall(love.filesystem.load, "lovepsp/env.lua")
  if ok and envDefaults then
    local t = envDefaults()
    if type(t) == "table" then for k, v in pairs(t) do ENV[k] = tostring(v) end end
  end
end

-- love.timer ------------------------------------------------------------
do
  local timer = {}
  local t0 = core.time()
  local last, dt = 0, 0
  local fps, frames, fpsTime = 0, 0, 0
  local avg, avgSum, avgN = 0, 0, 0
  function timer.getTime() return core.time() - t0 end
  function timer.step()
    local now = timer.getTime()
    dt = now - last
    last = now
    frames = frames + 1
    avgSum, avgN = avgSum + dt, avgN + 1
    if now - fpsTime >= 1 then
      fps = math.floor(frames / (now - fpsTime) + 0.5)
      avg = avgSum / math.max(avgN, 1)
      frames, fpsTime, avgSum, avgN = 0, now, 0, 0
    end
    return dt
  end
  function timer.getDelta() return dt end
  function timer.getFPS() return fps end
  function timer.getAverageDelta() return avg end
  function timer.sleep(s) core.sleep(s) end
  love.timer = timer
  package.loaded["love.timer"] = timer
end

-- love.event -------------------------------------------------------------
local queue, qhead = {}, 1
do
  local event = {}
  function event.push(name, ...)
    queue[#queue + 1] = table.pack(name, ...)
  end
  function event.poll()
    return function()
      local e = queue[qhead]
      if not e then
        queue, qhead = {}, 1
        return nil
      end
      queue[qhead] = nil
      qhead = qhead + 1
      return table.unpack(e, 1, e.n)
    end
  end
  function event.clear() queue, qhead = {}, 1 end
  function event.quit(status)
    event.push("quit", status == "restart" and "restart" or status or 0)
  end
  love.event = event
  package.loaded["love.event"] = event
end

-- input: one virtual gamepad for the PSP's buttons ----------------------------
local B = {
  up = 1, down = 2, left = 4, right = 8, cross = 16, circle = 32, square = 64,
  triangle = 128, l = 256, r = 512, start = 1024, select = 2048,
}
-- PSP button -> SDL gamepad button name.  Cross confirms (GB A) and circle
-- cancels (GB B) like western PSP games; LOVEPSP_SWAP_AB=1 flips that.
local PAD_MAP = {
  { B.up, "dpup" }, { B.down, "dpdown" }, { B.left, "dpleft" }, { B.right, "dpright" },
  { B.cross, "a" }, { B.circle, "b" }, { B.square, "x" }, { B.triangle, "y" },
  { B.l, "leftshoulder" }, { B.r, "rightshoulder" }, { B.start, "start" },
  { B.select, "back" },
}
local padButtons, padAxes = 0, { leftx = 0, lefty = 0 }
local padDown = {}

local Joystick = {}
Joystick.__index = Joystick
local pad = setmetatable({}, Joystick)
function Joystick:type() return "Joystick" end
function Joystick:typeOf(t) return t == "Joystick" or t == "Object" end
function Joystick:getID() return 1, 1 end
function Joystick:getGUID() return "0300000050535000000000000000504b" end
function Joystick:getName() return "PSP" end
function Joystick:getDeviceInfo() return 0x054c, 0x0001, 1 end
function Joystick:isConnected() return true end
function Joystick:isGamepad() return true end
function Joystick:getAxisCount() return 2 end
function Joystick:getButtonCount() return #PAD_MAP end
function Joystick:getHatCount() return 0 end
function Joystick:getHat() return "c" end
function Joystick:getAxis(i)
  if i == 1 then return padAxes.leftx elseif i == 2 then return padAxes.lefty end
  return 0
end
function Joystick:getAxes() return padAxes.leftx, padAxes.lefty end
function Joystick:getGamepadAxis(a) return padAxes[a] or 0 end
function Joystick:isGamepadDown(...)
  for i = 1, select("#", ...) do
    if padDown[(select(i, ...))] then return true end
  end
  return false
end
function Joystick:isDown(...)
  for i = 1, select("#", ...) do
    local m = PAD_MAP[(select(i, ...))]
    if m and padButtons & m[1] ~= 0 then return true end
  end
  return false
end
function Joystick:getGamepadMapping(b) return "button", 1 end
function Joystick:getGamepadMappingString() return nil end
function Joystick:isVibrationSupported() return false end
function Joystick:setVibration() return false end
function Joystick:getVibration() return 0, 0 end
function Joystick:release() return true end

do
  local joystick = {}
  function joystick.getJoysticks() return { pad } end
  function joystick.getJoystickCount() return 1 end
  function joystick.setGamepadMapping() return true end
  function joystick.loadGamepadMappings() end
  function joystick.saveGamepadMappings() return "" end
  function joystick.getGamepadMappingString() return nil end
  love.joystick = joystick
  package.loaded["love.joystick"] = joystick

  local keyboard = {}
  local keyRepeat = false
  function keyboard.isDown() return false end
  function keyboard.isScancodeDown() return false end
  function keyboard.setKeyRepeat(v) keyRepeat = v end
  function keyboard.hasKeyRepeat() return keyRepeat end
  function keyboard.setTextInput() end
  function keyboard.hasTextInput() return false end
  function keyboard.hasScreenKeyboard() return false end
  function keyboard.getKeyFromScancode(s) return s end
  function keyboard.getScancodeFromKey(k) return k end
  function keyboard.isModifierActive() return false end
  love.keyboard = keyboard
  package.loaded["love.keyboard"] = keyboard

  local mouse = {}
  function mouse.getPosition() return 0, 0 end
  function mouse.getX() return 0 end
  function mouse.getY() return 0 end
  function mouse.setPosition() end
  function mouse.isDown() return false end
  function mouse.setVisible() end
  function mouse.isVisible() return false end
  function mouse.setCursor() end
  function mouse.getCursor() return nil end
  function mouse.getSystemCursor() return nil end
  function mouse.newCursor() return nil end
  function mouse.isCursorSupported() return false end
  function mouse.setGrabbed() end
  function mouse.isGrabbed() return false end
  function mouse.setRelativeMode() end
  function mouse.getRelativeMode() return false end
  love.mouse = mouse
  package.loaded["love.mouse"] = mouse

  local touch = {}
  function touch.getTouches() return {} end
  function touch.getPosition() error("Invalid active touch ID") end
  function touch.getPressure() return 0 end
  love.touch = touch
  package.loaded["love.touch"] = touch
end

-- scaling hotkeys: hold SELECT and press R to cycle the screen mode forward,
-- SELECT + L to cycle back.  "none" is the native 160x144 size, "fit" fills
-- the height keeping the 3:2 aspect (FULLSCREEN), "stretch" fills the whole
-- 16:9 panel (WIDESCREEN).
local SCALE_MODES = { "none", "fit", "stretch" }
local function cycleScaling(dir)
  local cur, smooth = love.graphics._getPresentScaling()
  local idx = 2
  for i, m in ipairs(SCALE_MODES) do if m == cur then idx = i end end
  idx = (idx - 1 + dir) % #SCALE_MODES + 1
  love.graphics._setPresentScaling(SCALE_MODES[idx], smooth)
  pcall(love.filesystem.write, "lovepsp_scaling.txt", SCALE_MODES[idx])
  local hook = love.lovepsp and love.lovepsp.onScalingChanged
  if hook then pcall(hook, SCALE_MODES[idx], smooth) end
end

local swapAB = false
local quitSent = false
local DEADZONE = 0.3

-- LOVEPSP_INPUT (env.txt): scripted presses "frame:button:frames,..." with
-- button in up/down/left/right/cross/circle/square/triangle/l/r/start/select,
-- merged into the real pad so a console or emulator run can be driven
local scriptHolds, scriptFrame = nil, 0
local function loadInputScript()
  local spec = ENV.LOVEPSP_INPUT
  if not spec then return end
  scriptHolds = {}
  local names = { up = B.up, down = B.down, left = B.left, right = B.right, cross = B.cross,
    circle = B.circle, square = B.square, triangle = B.triangle, l = B.l, r = B.r,
    start = B.start, select = B.select }
  -- "600:cross:3" = frames; "12.5s:cross:0.2s" = seconds of runtime time
  for f, fu, name, n, nu in spec:gmatch("([%d%.]+)(s?):(%a+):([%d%.]+)(s?)") do
    if names[name] then
      scriptHolds[#scriptHolds + 1] = { from = tonumber(f), len = tonumber(n),
        bit = names[name], seconds = fu == "s" or nu == "s" }
    end
  end
end

local rawPrev = 0
-- the shell's panels read the pad directly (sticks, triggers, START/SELECT)
local rawInput = { buttons = 0, ax = 0, ay = 0, rx = 0, ry = 0, lt = 0, rt = 0 }
local function pumpInput()
  local buttons, ax, ay, quit, rx, ry, lt, rt = core.poll()
  if scriptHolds then
    scriptFrame = scriptFrame + 1
    local now = love.timer.getTime()
    for _, h in ipairs(scriptHolds) do
      local pos = h.seconds and now or scriptFrame
      if pos >= h.from and pos < h.from + h.len then buttons = buttons | h.bit end
    end
  end
  if quit and not quitSent then
    quitSent = true
    love.event.push("quit", 0)
  end
  rawInput.buttons, rawInput.ax, rawInput.ay = buttons, ax, ay
  rawInput.rx, rawInput.ry, rawInput.lt, rawInput.rt = rx or 0, ry or 0, lt or 0, rt or 0
  -- SELECT+R / SELECT+L are the runtime's scaling hotkeys, not game input:
  -- detect them against the raw previous state, then hide the shoulder
  -- buttons from the game for as long as SELECT is held
  local rawChanged = buttons ~ rawPrev
  rawPrev = buttons
  if buttons & B.select ~= 0 then
    if rawChanged & B.r ~= 0 and buttons & B.r ~= 0 then cycleScaling(1) end
    if rawChanged & B.l ~= 0 and buttons & B.l ~= 0 then cycleScaling(-1) end
    buttons = buttons & ~(B.r | B.l)
  end
  local changed = buttons ~ padButtons
  if changed ~= 0 then
    for _, m in ipairs(PAD_MAP) do
      local bit, name = m[1], m[2]
      if swapAB then
        if name == "a" then name = "b" elseif name == "b" then name = "a" end
      end
      if changed & bit ~= 0 then
        if buttons & bit ~= 0 then
          padDown[name] = true
          love.event.push("gamepadpressed", pad, name)
        else
          padDown[name] = nil
          love.event.push("gamepadreleased", pad, name)
        end
      end
    end
  end
  padButtons = buttons
  ax = math.abs(ax) < DEADZONE and 0 or ax
  ay = math.abs(ay) < DEADZONE and 0 or ay
  if ax ~= padAxes.leftx then
    padAxes.leftx = ax
    love.event.push("gamepadaxis", pad, "leftx", ax)
  end
  if ay ~= padAxes.lefty then
    padAxes.lefty = ay
    love.event.push("gamepadaxis", pad, "lefty", ay)
  end
end

function love.event.pump()
  pumpInput()
  love.audio._update()
end
function love.event.wait(timeout)
  local t0 = core.time()
  while true do
    love.event.pump()
    local e = queue[qhead]
    if e then
      queue[qhead] = nil
      qhead = qhead + 1
      return table.unpack(e, 1, e.n)
    end
    if timeout and core.time() - t0 >= timeout then return nil end
    core.sleep(0.005)
  end
end

-- love.math ------------------------------------------------------------------
do
  local mathm = {}
  local RNG = {}
  RNG.__index = RNG
  local MASK = 0xffffffffffffffff
  local function wang(k)
    k = (~k) + (k << 21)
    k = k ~ (k >> 24)
    k = (k + (k << 3)) + (k << 8)
    k = k ~ (k >> 14)
    k = (k + (k << 2)) + (k << 4)
    k = k ~ (k >> 28)
    k = k + (k << 31)
    return k
  end
  local function newRNG()
    return setmetatable({ state = 0, seedLow = 0, seedHigh = 0 }, RNG)
  end
  function RNG:setSeed(low, high)
    if high == nil then
      -- one number: split its integral bits into two 32-bit halves
      local n = math.floor(low)
      if math.type(n) ~= "integer" then n = math.tointeger(n) or 0 end
      low, high = n & 0xffffffff, (n >> 32) & 0xffffffff
    end
    self.seedLow, self.seedHigh = math.floor(low) & 0xffffffff, math.floor(high) & 0xffffffff
    self.state = wang((self.seedHigh << 32) | self.seedLow)
    if self.state == 0 then self.state = 1 end
    for _ = 1, 3 do self:_next() end
  end
  function RNG:getSeed() return self.seedLow, self.seedHigh end
  function RNG:_next()
    local x = self.state
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    self.state = x
    return x * 2685821657736338717
  end
  function RNG:random(a, b)
    local r = ((self:_next() >> 11) & 0x1fffffffffffff) * (1.0 / 9007199254740992.0)
    if a == nil then return r end
    if b == nil then return math.floor(r * a) + 1 end
    return math.floor(r * (b - a + 1)) + a
  end
  function RNG:randomNormal(stddev, mean)
    stddev, mean = stddev or 1, mean or 0
    local u1, u2 = self:random(), self:random()
    if u1 < 1e-300 then u1 = 1e-300 end
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * stddev + mean
  end
  function RNG:getState() return string.format("0x%016x", self.state) end
  function RNG:setState(s)
    local v = tonumber((tostring(s):gsub("^0x", "")), 16)
    if not v then error("Invalid random state: " .. tostring(s)) end
    self.state = math.tointeger(v) or 0
  end
  function RNG:type() return "RandomGenerator" end
  function RNG:typeOf(t) return t == "RandomGenerator" or t == "Object" end
  function RNG:release() return true end

  local global = newRNG()
  global:setSeed(os.time())
  function mathm.random(a, b) return global:random(a, b) end
  function mathm.randomNormal(s, m) return global:randomNormal(s, m) end
  function mathm.setRandomSeed(l, h) global:setSeed(l, h) end
  function mathm.getRandomSeed() return global:getSeed() end
  function mathm.getRandomState() return global:getState() end
  function mathm.setRandomState(s) global:setState(s) end
  function mathm.newRandomGenerator(l, h)
    local r = newRNG()
    r:setSeed(l or os.time(), h)
    return r
  end
  mathm.newTransform = newTransform
  function mathm.gammaToLinear(r, g, b, a)
    local function f(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    return f(r), g and f(g), b and f(b), a
  end
  function mathm.linearToGamma(r, g, b, a)
    local function f(c) return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055 end
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    return f(r), g and f(g), b and f(b), a
  end
  function mathm.colorToBytes(r, g, b, a)
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    local function c(v) return v and math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return c(r), c(g), c(b), c(a)
  end
  function mathm.colorFromBytes(r, g, b, a)
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    return r / 255, g and g / 255, b and b / 255, a and a / 255
  end
  -- deterministic value noise; LÖVE uses simplex noise, which nothing in the
  -- game depends on for exact values
  local function hash(...)
    local h = 2166136261
    for i = 1, select("#", ...) do
      local v = math.floor((select(i, ...)) * 1000) & 0xffffffff
      h = ((h ~ v) * 16777619) & 0xffffffff
    end
    return (h & 0xffff) / 65535
  end
  function mathm.noise(x, y, z, w)
    local function lerp(a, b, t) return a + (b - a) * (t * t * (3 - 2 * t)) end
    local ix, fx = math.floor(x), x - math.floor(x)
    if not y then return lerp(hash(ix), hash(ix + 1), fx) end
    local iy, fy = math.floor(y), y - math.floor(y)
    local zz, ww = z or 0, w or 0
    return lerp(lerp(hash(ix, iy, zz, ww), hash(ix + 1, iy, zz, ww), fx),
                lerp(hash(ix, iy + 1, zz, ww), hash(ix + 1, iy + 1, zz, ww), fx), fy)
  end
  function mathm.isConvex(...)
    local v = type(...) == "table" and ... or { ... }
    local n = #v // 2
    if n < 3 then return false end
    local sign = 0
    for i = 0, n - 1 do
      local j, k = (i + 1) % n, (i + 2) % n
      local cross = (v[j * 2 + 1] - v[i * 2 + 1]) * (v[k * 2 + 2] - v[j * 2 + 2])
                  - (v[j * 2 + 2] - v[i * 2 + 2]) * (v[k * 2 + 1] - v[j * 2 + 1])
      if cross ~= 0 then
        local s = cross > 0 and 1 or -1
        if sign == 0 then sign = s elseif s ~= sign then return false end
      end
    end
    return true
  end
  function mathm.triangulate(...)
    local v = type(...) == "table" and ... or { ... }
    local tris = {}
    for i = 2, #v // 2 - 1 do
      tris[#tris + 1] = { v[1], v[2], v[i * 2 - 1], v[i * 2], v[i * 2 + 1], v[i * 2 + 2] }
    end
    return tris
  end
  love.math = mathm
  package.loaded["love.math"] = mathm
end

-- love.data ----------------------------------------------------------------
do
  local data = {}
  local function bytes(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" or type(v) == "table" then
      if v.getString then return v:getString() end
    end
    error("string or Data expected", 3)
  end
  local function out(container, s)
    if container == "data" then return core.newByteData(s) end
    return s
  end
  function data.hash(alg, v) return core.hash(alg, bytes(v)) end
  -- lovepsp extension: hash a file from the virtual filesystem in chunks
  function data.hashFile(alg, path) return core.hashFile(alg, path) end
  function data.encode(container, fmt, v, lineLength)
    local s = core.encode(fmt, bytes(v))
    if lineLength and lineLength > 0 and fmt == "base64" then
      s = s:gsub(("."):rep(lineLength), "%0\n")
    end
    return out(container, s)
  end
  function data.decode(container, fmt, v) return out(container, core.decode(fmt, bytes(v))) end
  local Compressed = {}
  Compressed.__index = Compressed
  function Compressed:getString() return self.s end
  function Compressed:getSize() return #self.s end
  function Compressed:getFormat() return self.fmt end
  function Compressed:type() return "CompressedData" end
  function Compressed:typeOf(t) return t == "CompressedData" or t == "Data" or t == "Object" end
  function Compressed:clone() return setmetatable({ s = self.s, fmt = self.fmt }, Compressed) end
  function data.compress(container, fmt, v, level)
    if fmt ~= "zlib" and fmt ~= "deflate" and fmt ~= "gzip" then
      error("Compression format '" .. tostring(fmt) .. "' is not supported on PSP")
    end
    local s = core.compress(fmt, bytes(v), level)
    if container == "string" then return s end
    return setmetatable({ s = s, fmt = fmt }, Compressed)
  end
  function data.decompress(container, a, b)
    local fmt, s
    if getmetatable(a) == Compressed then fmt, s = a.fmt, a.s else fmt, s = a, bytes(b) end
    if fmt ~= "zlib" and fmt ~= "deflate" and fmt ~= "gzip" then
      error("Compression format '" .. tostring(fmt) .. "' is not supported on PSP")
    end
    return out(container, core.decompress(fmt, s))
  end
  function data.newByteData(v, offset, size)
    if type(v) == "number" then return core.newByteData(v) end
    local s = bytes(v)
    offset = offset or 0
    size = size or (#s - offset)
    return core.newByteData(s:sub(offset + 1, offset + size))
  end
  data.newDataView = data.newByteData
  function data.pack(container, fmt, ...) return out(container, string.pack(fmt, ...)) end
  function data.unpack(fmt, v, pos) return string.unpack(fmt, bytes(v), (pos or 0) + 1) end
  function data.getPackedSize(fmt) return string.packsize(fmt) end
  love.data = data
  package.loaded["love.data"] = data
end

-- love.system ----------------------------------------------------------------
do
  local system = {}
  local clipboard = ""
  function system.getOS() return core.os() end
  function system.getProcessorCount() return 1 end
  function system.getPowerInfo()
    local pct, charging, secs = core.power()
    if pct < 0 then return "nobattery", nil, nil end
    local state = charging and (pct >= 100 and "charged" or "charging") or "battery"
    return state, pct, secs >= 0 and secs or nil
  end
  function system.getClipboardText() return clipboard end
  function system.setClipboardText(t) clipboard = tostring(t) end
  function system.openURL() return false end
  function system.vibrate() end
  function system.hasBackgroundMusic() return false end
  function system.getPreferredLocales() return { "en_US" } end
  love.system = system
  package.loaded["love.system"] = system
end

-- love.window ----------------------------------------------------------------
do
  local window = {}
  local title = "gen1recomp"
  local SW, SH = core.screen()
  local flags = {
    fullscreen = true, fullscreentype = "desktop", vsync = 1, msaa = 0,
    stencil = false, depth = 0, resizable = false, borderless = true,
    centered = true, display = 1, minwidth = 1, minheight = 1,
    highdpi = false, usedpiscale = false, refreshrate = 60, x = 0, y = 0,
  }
  function window.setMode(w, h, f)
    w, h = math.floor(w or SW), math.floor(h or SH)
    if w <= 0 then w = SW end
    if h <= 0 then h = SH end
    core.setMode(w, h)
    if love.resize then pcall(love.resize, w, h) end
    return true
  end
  window.updateMode = window.setMode
  function window.getMode()
    local w, h = core.getMode()
    local f = {}
    for k, v in pairs(flags) do f[k] = v end
    return w, h, f
  end
  function window.getDesktopDimensions() return SW, SH end
  function window.getDPIScale() return 1 end
  function window.toPixels(a, b) return a, b end
  function window.fromPixels(a, b) return a, b end
  function window.setTitle(t) title = tostring(t) end
  function window.getTitle() return title end
  function window.isOpen() return true end
  function window.close() end
  function window.hasFocus() return true end
  function window.hasMouseFocus() return false end
  function window.isVisible() return true end
  function window.isMinimized() return false end
  function window.isMaximized() return false end
  function window.minimize() end
  function window.maximize() end
  function window.restore() end
  function window.setFullscreen() return true end
  function window.getFullscreen() return true, "desktop" end
  function window.getFullscreenModes() return { { width = SW, height = SH } } end
  function window.setVSync() end
  function window.getVSync() return 1 end
  function window.getSafeArea()
    local w, h = core.getMode()
    return 0, 0, w, h
  end
  function window.showMessageBox(t, msg)
    core.log("messagebox: " .. tostring(t) .. ": " .. tostring(msg))
    return 1
  end
  function window.requestAttention() end
  function window.setIcon() return true end
  function window.getIcon() return nil end
  function window.getDisplayCount() return 1 end
  function window.getDisplayName() return "PSP" end
  function window.getDisplayOrientation() return "landscape" end
  function window.setPosition() end
  function window.getPosition() return 0, 0, 1 end
  function window.setDisplaySleepEnabled() end
  function window.isDisplaySleepEnabled() return true end
  love.window = window
  package.loaded["love.window"] = window
end

-- runtime hooks for the shell's options page
love.lovepsp = {
  setSwapAB = function(v) swapAB = not not v end,
  getSwapAB = function() return swapAB end,
  setScaling = function(mode, smooth)
    love.graphics._setPresentScaling(mode, smooth)
  end,
  getScaling = love.graphics._getPresentScaling,
  memory = core.memory,
  power = core.power,
  touch = core.touch,       -- taps on/off: touch(on) / touch()
  touchPad = core.touchPad, -- the drawn D-pad/A/B overlay on/off
  inject = core.inject,     -- inject(mask): buttons held by a shell-drawn skin this frame
  gameRect = core.gameRect, -- gameRect(x, y, w, h) / gameRect(): where the game is presented
  split = core.split,       -- top, bottom heights of the DS halves; layout(mode, top, bottom) sets them
  hinge = core.hinge,       -- foldable hinge angle (degrees) or -1
  openUrl = core.openUrl,   -- open a web page in the host browser (Android)
  rawInput = rawInput,      -- live pad state: buttons bitmask, ax, ay, rx, ry, lt, rt
  buttonBits = B,           -- names -> bits for rawInput.buttons
  touches = core.touches,   -- fingers on the screen, launcher taps
  setOverlay = love.graphics._setOverlay, -- HUD canvas over the presented frame
  setBars = love.graphics._setBars,       -- side bars the game shrinks between
  screen = core.screen,     -- logical screen size (480x272, or 480x544 in the DS layout)
  layout = core.layout,     -- layout("single"|"ds") / layout()
  network = core.network,   -- true when http_get can work on this console
  http_get = core.http_get, -- http_get(url, save_relative_path[, token]) -> ok, err
  unzip = core.unzip,       -- unzip(zip_rel, dest_rel) -> files, err
  rename = core.rename,     -- rename(from_rel, to_rel) -> ok
  log = core.log,
  env = ENV,
}

-- love.thread is deliberately absent: gen1recomp falls back to synchronous
-- music synthesis and ROM extraction when it is missing.

---------------------------------------------------------------- handlers
love.handlers = setmetatable({
  keypressed = function(...) if love.keypressed then return love.keypressed(...) end end,
  keyreleased = function(...) if love.keyreleased then return love.keyreleased(...) end end,
  textinput = function(...) if love.textinput then return love.textinput(...) end end,
  textedited = function(...) if love.textedited then return love.textedited(...) end end,
  mousemoved = function(...) if love.mousemoved then return love.mousemoved(...) end end,
  mousepressed = function(...) if love.mousepressed then return love.mousepressed(...) end end,
  mousereleased = function(...) if love.mousereleased then return love.mousereleased(...) end end,
  wheelmoved = function(...) if love.wheelmoved then return love.wheelmoved(...) end end,
  touchpressed = function(...) if love.touchpressed then return love.touchpressed(...) end end,
  touchreleased = function(...) if love.touchreleased then return love.touchreleased(...) end end,
  touchmoved = function(...) if love.touchmoved then return love.touchmoved(...) end end,
  joystickpressed = function(...) if love.joystickpressed then return love.joystickpressed(...) end end,
  joystickreleased = function(...) if love.joystickreleased then return love.joystickreleased(...) end end,
  joystickaxis = function(...) if love.joystickaxis then return love.joystickaxis(...) end end,
  joystickhat = function(...) if love.joystickhat then return love.joystickhat(...) end end,
  gamepadpressed = function(...) if love.gamepadpressed then return love.gamepadpressed(...) end end,
  gamepadreleased = function(...) if love.gamepadreleased then return love.gamepadreleased(...) end end,
  gamepadaxis = function(...) if love.gamepadaxis then return love.gamepadaxis(...) end end,
  joystickadded = function(...) if love.joystickadded then return love.joystickadded(...) end end,
  joystickremoved = function(...) if love.joystickremoved then return love.joystickremoved(...) end end,
  focus = function(...) if love.focus then return love.focus(...) end end,
  mousefocus = function(...) if love.mousefocus then return love.mousefocus(...) end end,
  visible = function(...) if love.visible then return love.visible(...) end end,
  resize = function(...) if love.resize then return love.resize(...) end end,
  filedropped = function(...) if love.filedropped then return love.filedropped(...) end end,
  directorydropped = function(...) if love.directorydropped then return love.directorydropped(...) end end,
  lowmemory = function() if love.lowmemory then love.lowmemory() end collectgarbage() collectgarbage() end,
  displayrotated = function(...) if love.displayrotated then return love.displayrotated(...) end end,
  quit = function() end,
}, { __index = function(_, name)
  -- unknown custom events are ignored rather than fatal
  return function() end
end })

---------------------------------------------------------------- run loop
local perfFrames, perfT0 = 0, 0
local perfUpdate, perfDraw, perfPresent = 0, 0, 0
function love.run()
  if love.load then love.load(arg, arg) end
  if love.timer then love.timer.step() end
  perfT0 = love.timer.getTime()
  local dt = 0
  return function()
    love.event.pump()
    for name, a, b, c, d, e, f in love.event.poll() do
      if name == "quit" then
        if not love.quit or not love.quit() or quitSent then
          return a or 0
        end
      end
      love.handlers[name](a, b, c, d, e, f)
    end
    dt = love.timer.step()
    -- performance trace in lovepsp.log: one line every 300 frames
    perfFrames = perfFrames + 1
    if perfFrames >= 300 then
      local now = love.timer.getTime()
      core.log(("perf: %.1f fps at t=%ds, Lua heap %d KiB; per frame update %.1f ms, draw %.1f ms, present %.1f ms")
        :format(300 / (now - perfT0), now // 1, collectgarbage("count") // 1,
                perfUpdate / 300 * 1000, perfDraw / 300 * 1000, perfPresent / 300 * 1000))
      -- LOVEPSP_PROFILE=1: the shell wraps engine entry points and reports
      -- their per-frame cost through this table
      if LOVEPSP_PROF then
        local parts = {}
        for name, t in pairs(LOVEPSP_PROF) do
          parts[#parts + 1] = ("%s %.1f ms (%d calls)"):format(name, t.time / 300 * 1000, t.calls)
          t.time, t.calls = 0, 0
        end
        table.sort(parts)
        core.log("prof: " .. table.concat(parts, "; "))
      end
      perfFrames, perfT0 = 0, now
      perfUpdate, perfDraw, perfPresent = 0, 0, 0
    end
    local t0 = core.time()
    if love.update then love.update(dt) end
    local t1 = core.time()
    perfUpdate = perfUpdate + (t1 - t0)
    if love.graphics.isActive() then
      love.graphics.origin()
      love.graphics.clear(love.graphics.getBackgroundColor())
      if love.draw then love.draw() end
      local t2 = core.time()
      perfDraw = perfDraw + (t2 - t1)
      love.graphics.present()
      perfPresent = perfPresent + (core.time() - t2)
    end
  end
end

---------------------------------------------------------------- errors
local function errorScreen(msg)
  msg = tostring(msg)
  core.log("Error: " .. msg)
  pcall(love.audio.stop)
  local SW, SH = core.screen()
  pcall(core.setMode, SW, SH)
  pcall(love.graphics.reset)
  love.graphics._setPresentScaling("none", false)
  local font = love.graphics.newFont(12)
  local text = msg:gsub("\t", "  ")
  text = text .. "\n\nPress START to exit.  A copy of this message is in lovepsp.log."
  return function()
    local buttons, _, _, quit = core.poll()
    if quit or (buttons & B.start) ~= 0 then return 1 end
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setCanvas()
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha")
    love.graphics.clear(0.12, 0.10, 0.18, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font)
    love.graphics.printf(text, 8, 8, SW - 16)
    love.graphics.present()
  end
end

function love.errorhandler(msg)
  local ok, fn = pcall(errorScreen, tostring(msg))
  if ok then return fn end
  core.log("error screen failed: " .. tostring(fn))
  return nil
end
love.errhand = love.errorhandler

---------------------------------------------------------------- boot
local function boot()
  -- user overrides (save dir) win over archive defaults
  local envText = love.filesystem.read("env.txt")
  local c = {
    identity = nil, appendidentity = false, version = "11.5", console = false,
    accelerometerjoystick = false, externalstorage = false, gammacorrect = false,
    audio = { mic = false, mixwithsystem = true },
    window = { title = "Untitled", icon = nil, width = 480, height = 272,
      borderless = true, resizable = false, minwidth = 1, minheight = 1,
      fullscreen = true, fullscreentype = "desktop", vsync = 1, msaa = 0,
      depth = nil, stencil = nil, display = 1, highdpi = false,
      usedpiscale = true, x = nil, y = nil },
    modules = {},
  }
  if love.filesystem.getInfo("conf.lua") then
    local chunk = assert(love.filesystem.load("conf.lua"))
    chunk()
    if love.conf then love.conf(c) end
  end
  if c.identity then love.filesystem.setIdentity(c.identity) end
  loadEnvText(love.filesystem.read("env.txt") or envText)
  swapAB = ENV.LOVEPSP_SWAP_AB == "1"
  loadInputScript()
  do
    local saved = love.filesystem.read("lovepsp_scaling.txt")
    local mode = ENV.LOVEPSP_SCALING or saved or "fit"
    pcall(love.graphics._setPresentScaling, mode, ENV.LOVEPSP_SMOOTH ~= "0")
  end
  if c.window then love.window.setMode(c.window.width, c.window.height) end
  if c.window and c.window.title then love.window.setTitle(c.window.title) end
  love.event.push("joystickadded", pad)
  require("main")
end

local ok, err = xpcall(boot, debug.traceback)
local step, quitStatus
if ok then
  local okRun, loop = xpcall(love.run, debug.traceback)
  if okRun then step = loop else err = loop end
end
if not step then
  step = love.errorhandler(err)
  if not step then return end
end

while true do
  local okStep, result = xpcall(step, debug.traceback)
  if not okStep then
    local handler = love.errorhandler(result)
    if not handler then break end
    step = function()
      local r = handler()
      return r
    end
    -- errors inside the error screen end the program
    local okE, r = pcall(step)
    if not okE or r then break end
    step = handler
  elseif result ~= nil then
    quitStatus = result
    break
  end
end
if quitStatus == "restart" then return "restart" end
