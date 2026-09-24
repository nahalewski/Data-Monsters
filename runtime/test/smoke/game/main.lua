-- lovepsp smoke test: exercises the drawing paths the game relies on
local frame = 0
local canvas, img, quad, batch, shader, font, results
local function check(name, cond) results[#results + 1] = (cond and "ok   " or "FAIL ") .. name end

function love.load()
  results = {}
  love.graphics.setDefaultFilter("nearest", "nearest")
  canvas = love.graphics.newCanvas(160, 144)
  local id = love.image.newImageData(16, 16)
  id:mapPixel(function(x, y) local v = ((x // 4 + y // 4) % 4) / 3 return v, v, v, 1 end)
  img = love.graphics.newImage(id)
  quad = love.graphics.newQuad(0, 0, 8, 8, 16, 16)
  batch = love.graphics.newSpriteBatch(img)
  for i = 0, 3 do batch:add(quad, 8 + i * 10, 100) end
  shader = love.graphics.newShader([[
      extern vec3 c0; extern vec3 c1; extern vec3 c2; extern vec3 c3;
      vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        vec4 p = Texel(tex, tc);
        vec3 mapped = p.r > 0.83 ? c0 : (p.r > 0.5 ? c1 : (p.r > 0.17 ? c2 : c3));
        return vec4(mapped, p.a);
      }
    ]])
  shader:send("c0", {1, 1, 0.8}); shader:send("c1", {0.9, 0.5, 0.2})
  shader:send("c2", {0.5, 0.2, 0.4}); shader:send("c3", {0.1, 0.05, 0.2})
  font = love.graphics.newFont(8)
  -- filesystem round trip
  check("fs write", love.filesystem.write("dir/a.txt", "hello"))
  check("fs read", love.filesystem.read("dir/a.txt") == "hello")
  check("fs info", love.filesystem.getInfo("dir", "directory") ~= nil)
  local items = love.filesystem.getDirectoryItems("dir")
  check("fs items", #items == 1 and items[1] == "a.txt")
  check("fs mount", love.filesystem.mount("dir", "mnt", false) and love.filesystem.read("mnt/a.txt") == "hello")
  check("fs rootlist", (function() for _, n in ipairs(love.filesystem.getDirectoryItems("")) do if n == "mnt" then return true end end end)())
  check("sha1", love.data.encode("string", "hex", love.data.hash("sha1", "abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d")
  check("sha256", love.data.encode("string", "hex", love.data.hash("sha256", "abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  check("md5", love.data.encode("string", "hex", love.data.hash("md5", "abc")) == "900150983cd24fb0d6963f7d28e17f72")
  local z = love.data.compress("string", "zlib", string.rep("abc", 100))
  check("zlib", love.data.decompress("string", "zlib", z) == string.rep("abc", 100))
  local sd = love.sound.newSoundData(100, 22050, 16, 1)
  sd:setSample(5, 0.5)
  check("sounddata", math.abs(sd:getSample(5) - 0.5) < 0.001)
  local q = love.audio.newQueueableSource(22050, 16, 1, 4)
  check("queue", q:queue(sd) and q:getFreeBufferCount() == 3)
  q:play()
  local bit = require("bit")
  check("bit", bit.band(0xff, 0x0f) == 15 and bit.lshift(1, 31) == -2147483648 and bit.tohex(255, 2) == "ff")
  local w, lines = font:getWrap("hello world this wraps", 40)
  check("wrap", #lines >= 2)
  check("typeOf", canvas:typeOf("Canvas") and canvas:typeOf("Texture") and img:type() == "Image")
  local rng = love.math.newRandomGenerator(42)
  local r1 = rng:random(1, 6)
  check("rng", r1 >= 1 and r1 <= 6)
  for _, r in ipairs(results) do print(r) end
end

function love.update(dt) frame = frame + 1 end

function love.draw()
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.2, 0.2, 0.3, 1)
  love.graphics.setColor(1, 0, 0)
  love.graphics.rectangle("fill", 4, 4, 40, 20)
  love.graphics.setColor(0, 1, 0)
  love.graphics.circle("fill", 80, 20, 14)
  love.graphics.setColor(1, 1, 1)
  love.graphics.rectangle("line", 110, 6, 40, 30)
  love.graphics.draw(img, 4, 40, 0, 2, 2)
  love.graphics.setShader(shader)
  love.graphics.draw(img, 44, 40, 0, 2, 2)
  love.graphics.setShader()
  love.graphics.draw(img, 100, 56, frame * 0.05, 2, 2, 8, 8)
  love.graphics.draw(batch)
  love.graphics.setFont(font)
  love.graphics.print("lovepsp " .. frame, 4, 124)
  love.graphics.setCanvas()
  love.graphics.draw(canvas)
end
