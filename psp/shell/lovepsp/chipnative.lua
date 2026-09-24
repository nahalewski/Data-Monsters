-- Native chip synthesizer hook for gen1recomp on lovepsp.
--
-- ChipSynth renders Game Boy audio one sample at a time in Lua; on the PSP
-- that is ~370 us per sample, so music could never keep up with real time
-- and the port shipped with it switched off.  This module keeps the song
-- program interpreter in Lua (Channel:nextEvent runs once per note) and
-- hands the per-sample waveform synthesis to lovepsp.apu_render (apu.c),
-- which reads each channel's current event, renders up to the next event
-- boundary and writes the channel state back.
--
-- Install with require("lovepsp.chipnative").install() before the game
-- loads; it replaces ChipSynth.soundData and ChipSynth.renderEffectData.
local M = {}

local core = require("lovepsp")
if not core.apu_render then
  function M.install() return false, "runtime has no apu_render" end
  return M
end

local ChipSynth = require("src.core.ChipSynth")

local MAX_SFX_SECONDS = 12

local function drumAudioEnd(drum)
  local last = drum and drum[#drum]
  return last and last.endSample or 0
end

-- the event-advance loop from Channel:sample, verbatim
local function advance(ch)
  while not ch.ended and (not ch.event or ch.event.sample >= ch.event.samples) do
    local prev = ch.event
    ch.event = ch:nextEvent()
    ch.phase = 0
    local ev = ch.event
    if ev and ev.drum then
      ch.drumTail = nil
      ch:resetNoise()
    elseif prev and prev.drum and prev.sample < drumAudioEnd(prev.drum) then
      ch.drumTail = prev
    elseif not (ev and ev.silence and ch.drumTail) then
      ch.drumTail = nil
      ch:resetNoise()
    end
  end
end

local params = { gain = {1, 1, 1, 1}, pitch = {1, 1, 1, 1} }

local function refreshParams()
  params.rate = ChipSynth.SAMPLE_RATE
  params.stereo = ChipSynth.getStereo()
  params.monoFast = true
  for hw = 1, 4 do
    params.gain[hw] = ChipSynth.getChannelVolume(hw) or 1
    params.pitch[hw] = ChipSynth.getChannelPitch(hw) or 1
  end
  return params
end

-- render `frames` frames of `engine` into sd at frame `offset`; returns the
-- number rendered (all of them unless stopAtEnd and the song finished)
local function render(engine, sd, offset, frames, channels, stopAtEnd)
  local p = refreshParams()
  local channelsList = engine.channels
  local done = 0
  while done < frames do
    local n = frames - done
    local live = false
    for i = 1, #channelsList do
      local ch = channelsList[i]
      advance(ch)
      local ev = ch.event
      if ev then
        live = true
        local left = ev.samples - ev.sample
        if left < n then n = left end
      end
    end
    if stopAtEnd and not live then
      -- renderEffectData samples once more before it sees finished()
      core.apu_render(engine, sd, offset + done, 1, channels, p)
      done = done + 1
      break
    end
    if n <= 0 then n = 1 end
    core.apu_render(engine, sd, offset + done, n, channels, p)
    done = done + n
  end
  return done
end

local function soundData(engine, samples, channels)
  local sd = love.sound.newSoundData(samples, ChipSynth.SAMPLE_RATE, 16, channels)
  render(engine, sd, 0, samples, channels, false)
  return sd
end

local function renderEffectData(data, header, options)
  if not header then return nil end
  options = options or {}
  options.sfx = true
  options.allowLoops = false
  local engine = ChipSynth.newEngine(data, header, options)
  local rate = ChipSynth.SAMPLE_RATE
  local maximum = rate * (options.maxSeconds or MAX_SFX_SECONDS)
  local chunkFrames = 4096
  local chunks, count = {}, 0
  while count < maximum and not engine:finished() do
    local want = math.min(chunkFrames, maximum - count)
    local sd = love.sound.newSoundData(want, rate, 16, 1)
    local got = render(engine, sd, 0, want, 1, true)
    if got <= 0 then break end
    chunks[#chunks + 1] = { sd = sd, frames = got }
    count = count + got
  end
  if count < math.floor(rate / 100) then return nil end
  local result = love.sound.newSoundData(count, rate, 16, 2)
  local at = 0
  for _, chunk in ipairs(chunks) do
    core.apu_copy(result, at, chunk.sd, 0, chunk.frames)
    at = at + chunk.frames
  end
  return result
end

M.soundData = soundData
M.renderEffectData = renderEffectData

function M.install()
  if ChipSynth.soundData == soundData then return true end
  M.luaSoundData = ChipSynth.soundData
  M.luaRenderEffectData = ChipSynth.renderEffectData
  ChipSynth.soundData = soundData
  ChipSynth.renderEffectData = renderEffectData
  return true
end

function M.uninstall()
  if M.luaSoundData then
    ChipSynth.soundData = M.luaSoundData
    ChipSynth.renderEffectData = M.luaRenderEffectData
  end
end

return M
