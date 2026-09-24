/* lovepsp.apu_render: native renderer for gen1recomp's ChipSynth.
 *
 * The engine synthesizes Game Boy music sample by sample in Lua
 * (src/core/ChipSynth.lua, Channel:sample / Engine:sampleStereo), which
 * costs ~370 us per sample on the PSP's interpreter -- far more than real
 * time.  This module renders the same waveforms in C.  The song program
 * interpreter (Channel:nextEvent) stays in Lua: the shell's chipnative.lua
 * advances every channel to a live event, then asks us to render up to the
 * next event boundary, reading the event tables and writing back the
 * per-channel state Lua keeps (event.sample, phase, LFSR, drum tail).
 *
 *   lovepsp.apu_render(engine, sounddata, offset, frames, channels, params)
 *
 * params: { rate=, gain={1..4}, pitch={1..4}, stereo=bool, monoFast=bool,
 *           noiseGain= }
 * The arithmetic follows ChipSynth.lua line by line (real precision, so
 * the output matches the Lua synth to rounding).
 */
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lp.h"

#define GB_CLOCK 4194304.0f
#define LPF_ALPHA 0.8f
#define MIX_SCALE 0.5f
#define MAX_SEGS 72
/* single precision: the PSP FPU has no double, doubles are emulated in software */
typedef float real;
#define MAX_CHANNELS 8

typedef struct Seg { real start, end, volume, fade; int parameter; } Seg;

typedef struct Chan {
  int hasEvent, silence, drum, noise, wave;
  real sample, samples;
  real volume, fade;
  int noiseParameter;
  real reg;
  int hasSweep, sweepShift, sweepSub; real sweepPace;
  int hasSlide; real slideTarget, slideFrames;
  int hasVibrato; real vibDelay, vibRate, vibAbove, vibBelow;
  int dutyIsTable, duty[4];
  real waveLevel; real waveTab[32]; int hasWaveTab;
  Seg segs[MAX_SEGS]; int nsegs; int segIndex; /* 1-based like Lua; 0 = nil */
  int hasTail; Seg tsegs[MAX_SEGS]; int ntsegs; real tsample; int tsegIndex;
  real phase; uint32_t lfsr; real noiseClock;
  real gain, pitch; int panL, panR;
  int hardware;
} Chan;

static const real NOISE_DIVISORS[8] = {8.f, 16.f, 32.f, 48.f, 64.f, 80.f, 96.f, 112.f};
static const int PATTERNS[4][8] = {
  {0, 0, 0, 0, 0, 0, 0, 1}, {1, 0, 0, 0, 0, 0, 0, 1},
  {1, 0, 0, 0, 0, 1, 1, 1}, {0, 1, 1, 1, 1, 1, 1, 0}};

static real fnum(lua_State *L, int t, const char *k, real def) {
  real v = def;
  lua_getfield(L, t, k);
  if (lua_isnumber(L, -1)) v = lua_tonumber(L, -1);
  lua_pop(L, 1);
  return v;
}
static int fbool(lua_State *L, int t, const char *k) {
  int v;
  lua_getfield(L, t, k);
  v = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return v;
}
static int fistrue(lua_State *L, int t, const char *k) { /* field ~= false and ~= nil */
  return fbool(L, t, k);
}

static int read_segs(lua_State *L, int t, Seg *out) {
  int n = 0, i;
  lua_len(L, t);
  int len = (int)lua_tointeger(L, -1);
  lua_pop(L, 1);
  if (len > MAX_SEGS) len = MAX_SEGS;
  for (i = 1; i <= len; i++) {
    lua_rawgeti(L, t, i);
    int s = lua_gettop(L);
    out[n].start = fnum(L, s, "startSample", 0);
    out[n].end = fnum(L, s, "endSample", 0);
    out[n].volume = fnum(L, s, "volume", 0);
    out[n].fade = fnum(L, s, "fade", 0);
    out[n].parameter = (int)fnum(L, s, "parameter", 0);
    n++;
    lua_pop(L, 1);
  }
  return n;
}

static real env_volume(real volume, real fade, real elapsed) {
  real steps;
  if (fade == 0) return volume;
  steps = floorf(elapsed / (fabsf(fade) / 64.0f));
  if (fade > 0) { real v = volume - steps; return v > 0 ? v : 0; }
  { real v = volume + steps; return v < 15 ? v : 15; }
}

static void clock_noise(Chan *c, int width7) {
  uint32_t feedback = (c->lfsr & 1) ^ ((c->lfsr >> 1) & 1);
  c->lfsr = (c->lfsr >> 1) | (feedback << 14);
  if (width7) c->lfsr = (c->lfsr & ~0x40u) | (feedback << 6);
}

static real sample_noise(Chan *c, int parameter, real rate) {
  real divisor = NOISE_DIVISORS[parameter & 7];
  int shift = parameter >> 4;
  if (shift < 14) {
    real cycles = GB_CLOCK / divisor / ldexpf(1.0, shift) / rate * c->pitch;
    int width7 = (parameter & 8) != 0;
    real remaining = cycles;
    while (remaining > 0) {
      real until = 1 - c->noiseClock;
      real span = remaining < until ? remaining : until;
      c->noiseClock += span;
      remaining -= span;
      if (c->noiseClock >= 1.0f - 1e-6f) {
        c->noiseClock = 0;
        clock_noise(c, width7);
      }
    }
  }
  return (c->lfsr & 1) == 0 ? 1.0 : 0.0;
}

static real sweep_calc(real reg, const Chan *c) {
  real delta = floorf(reg / ldexpf(1.0, c->sweepShift));
  return c->sweepSub ? reg - delta : reg + delta;
}
/* returns 0 and sets *ok = 0 when the sweep overflows (Lua: nil) */
static real swept_register(real reg, const Chan *c, real elapsed, int *ok) {
  real next, iterations, i;
  *ok = 1;
  if (c->sweepShift == 0) return reg;
  next = sweep_calc(reg, c);
  if (next > 0x7FF || next < 0) { *ok = 0; return 0; }
  if (c->sweepPace == 0) return reg;
  iterations = floorf(elapsed * 128 / c->sweepPace);
  for (i = 0; i < iterations; i++) {
    reg = next;
    next = sweep_calc(reg, c);
    if (next > 0x7FF || next < 0) { *ok = 0; return 0; }
  }
  return reg;
}

static real sample_drum(Chan *c, Seg *segs, int nsegs, int *segIndex, real idx, real rate) {
  int index = *segIndex ? *segIndex : 1;
  Seg *seg = index <= nsegs ? &segs[index - 1] : NULL;
  real elapsed, volume;
  while (seg && idx >= seg->end) {
    index++;
    seg = index <= nsegs ? &segs[index - 1] : NULL;
  }
  if (!seg || idx < seg->start) return 0;
  if (*segIndex != index) {
    *segIndex = index;
    c->lfsr = 0x7FFF;
    c->noiseClock = 0;
  }
  elapsed = (idx - seg->start) / rate;
  volume = env_volume(seg->volume, seg->fade, elapsed);
  return sample_noise(c, seg->parameter, rate) * volume / 15.0f;
}

static real tail_sample(Chan *c, real rate) {
  real idx, tailEnd;
  if (!c->hasTail) return 0;
  idx = c->tsample;
  c->tsample = idx + 1;
  tailEnd = c->ntsegs ? c->tsegs[c->ntsegs - 1].end : 0;
  if (idx >= tailEnd) { c->hasTail = 0; return 0; }
  return sample_drum(c, c->tsegs, c->ntsegs, &c->tsegIndex, idx, rate) * c->gain;
}

static real chan_sample(Chan *c, real rate) {
  real idx, elapsed, volume, reg, frame, frequency, phase;
  if (!c->hasEvent) return tail_sample(c, rate);
  idx = c->sample;
  elapsed = idx / rate;
  c->sample = idx + 1;
  if (c->silence) return tail_sample(c, rate);
  if (c->drum) return sample_drum(c, c->segs, c->nsegs, &c->segIndex, idx, rate) * c->gain;
  c->hasTail = 0;
  volume = env_volume(c->volume, c->fade, elapsed);
  if (c->noise) return sample_noise(c, c->noiseParameter, rate) * volume / 15.0f * c->gain;

  reg = c->reg;
  frame = floorf(elapsed * 60);
  if (c->hasSweep) {
    int ok;
    reg = swept_register(reg, c, elapsed, &ok);
    if (!ok) return 0;
  } else if (c->hasSlide) {
    real amount = frame / c->slideFrames;
    if (amount > 1) amount = 1;
    reg = reg + (c->slideTarget - reg) * amount;
  } else if (c->hasVibrato && frame >= c->vibDelay) {
    real toggles = floorf((frame - c->vibDelay + 1) / (c->vibRate + 1));
    if (toggles > 0) {
      int32_t r = (int32_t)reg;
      int32_t low = r & 0xFF, high = r & 0x700;
      if (((int64_t)toggles) & 1) {
        real v = low + c->vibAbove;
        reg = high + (v < 0xFF ? v : 0xFF);
      } else {
        real v = low - c->vibBelow;
        reg = high + (v > 0 ? v : 0);
      }
    }
  }
  frequency = 131072.0f / (2048.0f - (reg < 2047 ? reg : 2047)) * c->pitch;
  if (c->wave) frequency *= 0.5;
  phase = c->phase;
  c->phase = phase + frequency / rate;
  c->phase -= floorf(c->phase);
  if (c->wave) {
    int index;
    real nibble;
    if (!c->hasWaveTab) return 0;
    index = (int)floorf(phase * 32);
    if (index > 31) index = 31;
    if (index < 0) index = 0;
    nibble = c->waveTab[index] * 8 + 8;
    if (nibble < 0) nibble = 0;
    if (nibble > 15) nibble = 15;
    return (nibble / 15.0f) * c->waveLevel * c->gain;
  }
  {
    int duty = c->dutyIsTable ? c->duty[((int64_t)frame) % 4] : c->duty[0];
    int step;
    if (duty < 0 || duty > 3) duty = 2;
    step = ((int)floorf(phase * 8)) % 8;
    if (step < 0) step += 8;
    if (PATTERNS[duty][step] == 0) return 0;
  }
  return volume / 15.0f * c->gain;
}

static real analog_out(real input, real *cap, real *lpf, real charge) {
  real hp = input - *cap;
  real lp;
  *cap = input - hp * charge;
  lp = *lpf + LPF_ALPHA * (hp - *lpf);
  *lpf = lp;
  lp *= MIX_SCALE;
  return lp > 1 ? 1 : (lp < -1 ? -1 : lp);
}

/* pull one channel's Lua state (channel table at index t) into c */
static void read_chan(lua_State *L, int t, Chan *c, int generation, int enginePan) {
  int ev, tail;
  memset(c, 0, sizeof(*c));
  c->hardware = (int)fnum(L, t, "hardware", 1);
  c->phase = fnum(L, t, "phase", 0);
  c->lfsr = (uint32_t)fnum(L, t, "noiseLfsr", 0x7FFF);
  c->noiseClock = fnum(L, t, "noiseClock", 0);
  c->panL = c->panR = 1;

  lua_getfield(L, t, "drumTail");
  tail = lua_gettop(L);
  if (lua_istable(L, tail)) {
    c->hasTail = 1;
    c->tsample = fnum(L, tail, "sample", 0);
    c->tsegIndex = (int)fnum(L, tail, "drumSegmentIndex", 0);
    lua_getfield(L, tail, "drum");
    if (lua_istable(L, -1)) c->ntsegs = read_segs(L, lua_gettop(L), c->tsegs);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);

  lua_getfield(L, t, "event");
  ev = lua_gettop(L);
  if (!lua_istable(L, ev)) { lua_pop(L, 1); return; }
  c->hasEvent = 1;
  c->sample = fnum(L, ev, "sample", 0);
  c->samples = fnum(L, ev, "samples", 0);
  c->silence = fbool(L, ev, "silence");
  lua_getfield(L, ev, "drum");
  if (lua_istable(L, -1)) {
    c->drum = 1;
    c->nsegs = read_segs(L, lua_gettop(L), c->segs);
    c->segIndex = (int)fnum(L, ev, "drumSegmentIndex", 0);
  }
  lua_pop(L, 1);
  c->noise = fbool(L, ev, "noise");
  c->volume = fnum(L, ev, "volume", 0);
  c->fade = fnum(L, ev, "fade", 0);
  c->noiseParameter = (int)fnum(L, ev, "noiseParameter", 0);
  c->reg = fnum(L, ev, "register", 0);
  c->wave = fbool(L, ev, "wave");
  c->waveLevel = fnum(L, ev, "waveLevel", 1);
  if (generation == 2) {
    int tracks = (int)fnum(L, t, "tracks", 0xFF);
    int mask = 1 << (c->hardware - 1);
    c->panL = ((tracks >> 4) & mask) != 0;
    c->panR = (tracks & mask) != 0;
  } else {
    lua_getfield(L, ev, "panLeft");
    c->panL = !(lua_isboolean(L, -1) && !lua_toboolean(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, ev, "panRight");
    c->panR = !(lua_isboolean(L, -1) && !lua_toboolean(L, -1));
    lua_pop(L, 1);
  }
  (void)enginePan;

  lua_getfield(L, ev, "sweep");
  if (lua_istable(L, -1)) {
    int s = lua_gettop(L);
    c->hasSweep = 1;
    c->sweepShift = (int)fnum(L, s, "shift", 0);
    c->sweepSub = fbool(L, s, "subtract");
    c->sweepPace = fnum(L, s, "pace", 0);
  }
  lua_pop(L, 1);
  lua_getfield(L, ev, "slide");
  if (lua_istable(L, -1)) {
    int s = lua_gettop(L);
    c->hasSlide = 1;
    c->slideTarget = fnum(L, s, "target", 0);
    c->slideFrames = fnum(L, s, "frames", 1);
  }
  lua_pop(L, 1);
  lua_getfield(L, ev, "vibrato");
  if (lua_istable(L, -1)) {
    int s = lua_gettop(L);
    c->hasVibrato = 1;
    c->vibDelay = fnum(L, s, "delay", 0);
    c->vibRate = fnum(L, s, "rate", 0);
    c->vibAbove = fnum(L, s, "above", 0);
    c->vibBelow = fnum(L, s, "below", 0);
  }
  lua_pop(L, 1);
  lua_getfield(L, ev, "duty");
  if (lua_istable(L, -1)) {
    int i;
    c->dutyIsTable = 1;
    for (i = 0; i < 4; i++) {
      lua_rawgeti(L, -1, i + 1);
      c->duty[i] = lua_isnumber(L, -1) ? (int)lua_tonumber(L, -1) : 2;
      lua_pop(L, 1);
    }
  } else {
    c->duty[0] = lua_isnumber(L, -1) ? (int)lua_tonumber(L, -1) : 2;
  }
  lua_pop(L, 1);
  lua_pop(L, 1); /* event */
}

static void read_wave(lua_State *L, int engine, Chan *c, int t) {
  int instrument, count, i;
  (void)t;
  lua_getfield(L, engine, "waves");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
  lua_len(L, -1);
  count = (int)lua_tointeger(L, -1);
  lua_pop(L, 1);
  lua_getfield(L, t, "event");
  instrument = (int)fnum(L, lua_gettop(L), "waveInstrument", 0) + 1;
  lua_pop(L, 1);
  if (instrument > count) instrument = count;
  lua_rawgeti(L, -1, instrument);
  if (lua_istable(L, -1)) {
    c->hasWaveTab = 1;
    for (i = 0; i < 32; i++) {
      lua_rawgeti(L, -1, i + 1);
      c->waveTab[i] = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 0;
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 2);
}

static void write_chan(lua_State *L, int t, const Chan *c) {
  lua_pushnumber(L, c->phase); lua_setfield(L, t, "phase");
  lua_pushinteger(L, (lua_Integer)c->lfsr); lua_setfield(L, t, "noiseLfsr");
  lua_pushnumber(L, c->noiseClock); lua_setfield(L, t, "noiseClock");
  if (c->hasEvent) {
    lua_getfield(L, t, "event");
    if (lua_istable(L, -1)) {
      lua_pushnumber(L, c->sample); lua_setfield(L, -2, "sample");
      if (c->drum && c->segIndex) { lua_pushinteger(L, c->segIndex); lua_setfield(L, -2, "drumSegmentIndex"); }
    }
    lua_pop(L, 1);
  }
  lua_getfield(L, t, "drumTail");
  if (lua_istable(L, -1)) {
    if (!c->hasTail) {
      lua_pop(L, 1);
      lua_pushnil(L);
      lua_setfield(L, t, "drumTail");
      return;
    }
    lua_pushnumber(L, c->tsample); lua_setfield(L, -2, "sample");
    if (c->tsegIndex) { lua_pushinteger(L, c->tsegIndex); lua_setfield(L, -2, "drumSegmentIndex"); }
  }
  lua_pop(L, 1);
}

int lp_apu_render(lua_State *L) {
  static Chan chans[MAX_CHANNELS];
  int engine = 1, sd = 2;
  lua_Integer offset = luaL_checkinteger(L, 3);
  lua_Integer frames = luaL_checkinteger(L, 4);
  int outChannels = (int)luaL_checkinteger(L, 5);
  int params = 6;
  int16_t *pcm; int pcmFrames, pcmChannels;
  real rate, charge, noiseGain;
  int stereo, monoFast, monoMix, generation, enginePan;
  int n = 0, i;
  real hpfCap, hpfL, hpfR, lpf, lpfL, lpfR;
  lua_Integer f;

  luaL_checktype(L, engine, LUA_TTABLE);
  luaL_checktype(L, params, LUA_TTABLE);
  pcm = lp_sounddata_samples(L, sd, &pcmFrames, &pcmChannels);
  if (!pcm) return luaL_error(L, "apu_render: SoundData expected");
  if (pcmChannels != outChannels) return luaL_error(L, "apu_render: channel count mismatch");
  if (offset < 0 || frames < 0 || offset + frames > pcmFrames) return luaL_error(L, "apu_render: range out of SoundData");

  rate = fnum(L, params, "rate", 44100);
  charge = powf(0.999958f, GB_CLOCK / rate);
  stereo = fbool(L, params, "stereo");
  monoFast = fbool(L, params, "monoFast");
  noiseGain = fnum(L, params, "noiseGain", 1);
  (void)noiseGain;
  generation = (int)fnum(L, engine, "generation", 1);
  enginePan = (int)fnum(L, engine, "pan", 0xFF);
  monoMix = fbool(L, engine, "monoMix");
  hpfCap = fnum(L, engine, "hpfCap", 0); hpfL = fnum(L, engine, "hpfCapLeft", 0); hpfR = fnum(L, engine, "hpfCapRight", 0);
  lpf = fnum(L, engine, "lpf", 0); lpfL = fnum(L, engine, "lpfLeft", 0); lpfR = fnum(L, engine, "lpfRight", 0);

  lua_getfield(L, engine, "channels");
  luaL_checktype(L, -1, LUA_TTABLE);
  {
    int chs = lua_gettop(L);
    lua_len(L, chs);
    n = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (n > MAX_CHANNELS) n = MAX_CHANNELS;
    for (i = 0; i < n; i++) {
      Chan *c = &chans[i];
      lua_rawgeti(L, chs, i + 1);
      read_chan(L, lua_gettop(L), c, generation, enginePan);
      if (c->hasEvent && c->wave) read_wave(L, engine, c, lua_gettop(L));
      lua_getfield(L, params, "gain");
      lua_rawgeti(L, -1, c->hardware);
      c->gain = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 1;
      lua_pop(L, 2);
      lua_getfield(L, params, "pitch");
      lua_rawgeti(L, -1, c->hardware);
      c->pitch = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 1;
      lua_pop(L, 2);
      lua_pop(L, 1);
    }

    for (f = 0; f < frames; f++) {
      int16_t *out = pcm + (size_t)(offset + f) * outChannels;
      real l, r, v;
      if (outChannels == 1) {
        v = 0;
        for (i = 0; i < n; i++) v += chan_sample(&chans[i], rate);
        v = analog_out(v, &hpfCap, &lpf, charge);
        out[0] = (int16_t)(v * 32767.0f);
      } else if (monoFast && monoMix && !stereo) {
        v = 0;
        for (i = 0; i < n; i++) v += chan_sample(&chans[i], rate);
        v = analog_out(v, &hpfL, &lpfL, charge);
        hpfR = hpfL; lpfR = lpfL;
        out[0] = out[1] = (int16_t)(v * 32767.0f);
      } else {
        l = r = 0;
        for (i = 0; i < n; i++) {
          v = chan_sample(&chans[i], rate);
          if (chans[i].panL) l += v;
          if (chans[i].panR) r += v;
        }
        out[0] = (int16_t)(analog_out(l, &hpfL, &lpfL, charge) * 32767.0f);
        out[1] = (int16_t)(analog_out(r, &hpfR, &lpfR, charge) * 32767.0f);
      }
    }

    for (i = 0; i < n; i++) {
      lua_rawgeti(L, chs, i + 1);
      write_chan(L, lua_gettop(L), &chans[i]);
      lua_pop(L, 1);
    }
    lua_pop(L, 1); /* channels */
  }
  lua_pushnumber(L, hpfCap); lua_setfield(L, engine, "hpfCap");
  lua_pushnumber(L, hpfL); lua_setfield(L, engine, "hpfCapLeft");
  lua_pushnumber(L, hpfR); lua_setfield(L, engine, "hpfCapRight");
  lua_pushnumber(L, lpf); lua_setfield(L, engine, "lpf");
  lua_pushnumber(L, lpfL); lua_setfield(L, engine, "lpfLeft");
  lua_pushnumber(L, lpfR); lua_setfield(L, engine, "lpfRight");
  return 0;
}

/* lovepsp.apu_copy(dst, dstOffset, src, srcOffset, frames): copy PCM frames,
 * duplicating a mono source into a stereo destination */
int lp_apu_copy(lua_State *L) {
  int16_t *d, *s;
  int df, dc, sf, sc;
  lua_Integer doff = luaL_checkinteger(L, 2), soff = luaL_checkinteger(L, 4), n = luaL_checkinteger(L, 5), i;
  d = lp_sounddata_samples(L, 1, &df, &dc);
  s = lp_sounddata_samples(L, 3, &sf, &sc);
  if (!d || !s) return luaL_error(L, "apu_copy: SoundData expected");
  if (doff < 0 || soff < 0 || n < 0 || doff + n > df || soff + n > sf) return luaL_error(L, "apu_copy: range");
  if (dc == sc) {
    memcpy(d + doff * dc, s + soff * sc, (size_t)n * dc * sizeof(int16_t));
  } else if (sc == 1) {
    for (i = 0; i < n; i++) {
      int c;
      for (c = 0; c < dc; c++) d[(doff + i) * dc + c] = s[soff + i];
    }
  } else {
    for (i = 0; i < n; i++) d[doff + i] = s[(soff + i) * sc];
  }
  return 0;
}
