local WaitPlaySFX = {}

local function sound()
  local ok, mod = pcall(require, "src.core.Sound")
  return ok and type(mod) == "table" and mod or nil
end

-- home/audio.asm:220 WaitPlaySFX
-- home/delay.asm:15
function WaitPlaySFX.arm(name, fallback)
  local Sound = sound()
  local frames = Sound and Sound.waitFramesFor
    and Sound.waitFramesFor(name, fallback or 30)
  return { name = name, left = tonumber(frames) or 0 }
end

-- home/audio.asm:225 WaitSFX
function WaitPlaySFX.waiting(pending)
  if not pending then return false end
  pending.left = (pending.left or 0) - 1
  if pending.left <= 0 then return false end
  local Sound = sound()
  if not Sound then return false end
  if Sound.sfxBusy and Sound.sfxBusy() then return true end
  return (Sound.isPlaying and Sound.isPlaying(pending.name)) or false
end

return WaitPlaySFX
