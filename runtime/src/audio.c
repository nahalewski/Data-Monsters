/*
 * love.sound + love.audio: SoundData, static/queueable Sources and a
 * software mixer that the platform audio thread pulls from.
 *
 * Threading: the audio thread only reads PCM and advances playback
 * positions under plat_audio_lock.  Every allocation and free happens on the
 * main thread (buffers the mixer has consumed are reaped from Lua calls), so
 * the mixer never touches the heap.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "lp.h"
#include "plat.h"

int stb_vorbis_decode_memory(const unsigned char *mem, int len, int *channels, int *sample_rate, short **output);

/* ------------------------------------------------------------ PCM buffers */

typedef struct Pcm {
  int refs;
  int frames, channels, rate, bits;
  int16_t *s;
} Pcm;

static Pcm *pcm_new(int frames, int channels, int rate, int bits) {
  Pcm *p = (Pcm *)calloc(1, sizeof(Pcm));
  if (!p) return NULL;
  if (frames < 0) frames = 0;
  p->s = (int16_t *)calloc((size_t)(frames ? frames : 1) * channels, sizeof(int16_t));
  if (!p->s) { free(p); return NULL; }
  p->refs = 1; p->frames = frames; p->channels = channels; p->rate = rate; p->bits = bits;
  return p;
}
static void pcm_release(Pcm *p) {
  if (p && --p->refs <= 0) { free(p->s); free(p); }
}

/* ------------------------------------------------------------ SoundData */

typedef struct SoundDataObj { Pcm *p; } SoundDataObj;
static LPType SoundData_type;

static Pcm *checksd(lua_State *L, int i) {
  SoundDataObj *o = (SoundDataObj *)lp_checkobj(L, i, &SoundData_type);
  if (!o->p) luaL_error(L, "SoundData has been released");
  return o->p;
}
static int sd_gc(lua_State *L) {
  SoundDataObj *o = (SoundDataObj *)lua_touserdata(L, 1);
  if (o->p) {
    plat_audio_lock();
    pcm_release(o->p);
    plat_audio_unlock();
    o->p = NULL;
  }
  return 0;
}
int16_t *lp_sounddata_samples(lua_State *L, int idx, int *frames, int *channels) {
  SoundDataObj *o = (SoundDataObj *)lp_testobj(L, idx, &SoundData_type);
  if (!o || !o->p) return NULL;
  *frames = o->p->frames;
  *channels = o->p->channels;
  return o->p->s;
}

static SoundDataObj *push_sd(lua_State *L, Pcm *p) {
  SoundDataObj *o = (SoundDataObj *)lp_newobj(L, &SoundData_type, sizeof(SoundDataObj));
  o->p = p;
  return o;
}

static int sd_getSample(lua_State *L) {
  Pcm *p = checksd(L, 1);
  lua_Integer i = luaL_checkinteger(L, 2);
  if (!lua_isnoneornil(L, 3)) i = i * p->channels + (luaL_checkinteger(L, 3) - 1);
  if (i < 0 || i >= (lua_Integer)p->frames * p->channels) return luaL_error(L, "Attempt to get out-of-range sample!");
  lua_pushnumber(L, p->s[i] / 32768.0);
  return 1;
}
static int sd_setSample(lua_State *L) {
  Pcm *p = checksd(L, 1);
  lua_Integer i = luaL_checkinteger(L, 2);
  double v;
  if (lua_gettop(L) >= 4) {
    i = i * p->channels + (luaL_checkinteger(L, 3) - 1);
    v = luaL_checknumber(L, 4);
  } else v = luaL_checknumber(L, 3);
  if (i < 0 || i >= (lua_Integer)p->frames * p->channels) return luaL_error(L, "Attempt to set out-of-range sample!");
  if (v > 1) v = 1; else if (v < -1) v = -1;
  p->s[i] = (int16_t)(v * 32767.0);
  return 0;
}
static int sd_getSampleCount(lua_State *L) { lua_pushinteger(L, checksd(L, 1)->frames); return 1; }
static int sd_getSampleRate(lua_State *L) { lua_pushinteger(L, checksd(L, 1)->rate); return 1; }
static int sd_getChannelCount(lua_State *L) { lua_pushinteger(L, checksd(L, 1)->channels); return 1; }
static int sd_getBitDepth(lua_State *L) { lua_pushinteger(L, checksd(L, 1)->bits); return 1; }
static int sd_getDuration(lua_State *L) { Pcm *p = checksd(L, 1); lua_pushnumber(L, (double)p->frames / p->rate); return 1; }
static int sd_getSize(lua_State *L) { Pcm *p = checksd(L, 1); lua_pushinteger(L, (lua_Integer)p->frames * p->channels * 2); return 1; }
static int sd_getString(lua_State *L) { Pcm *p = checksd(L, 1); lua_pushlstring(L, (const char *)p->s, (size_t)p->frames * p->channels * 2); return 1; }
static int sd_getPointer(lua_State *L) { lua_pushlightuserdata(L, checksd(L, 1)->s); return 1; }
static int sd_clone(lua_State *L) {
  Pcm *p = checksd(L, 1), *n = pcm_new(p->frames, p->channels, p->rate, p->bits);
  if (!n) return luaL_error(L, "out of memory");
  memcpy(n->s, p->s, (size_t)p->frames * p->channels * 2);
  push_sd(L, n);
  return 1;
}
static const luaL_Reg sd_methods[] = {
  {"getSample", sd_getSample}, {"setSample", sd_setSample}, {"getSampleCount", sd_getSampleCount},
  {"getSampleRate", sd_getSampleRate}, {"getChannelCount", sd_getChannelCount},
  {"getChannels", sd_getChannelCount}, {"getBitDepth", sd_getBitDepth},
  {"getDuration", sd_getDuration}, {"getSize", sd_getSize}, {"getString", sd_getString},
  {"getPointer", sd_getPointer}, {"clone", sd_clone}, {NULL, NULL}};
static const char *const sd_chain[] = {"Data", NULL};
static LPType SoundData_type = {"SoundData", sd_chain, sd_methods, sd_gc};

static uint32_t rd32(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static Pcm *decode_wav(const unsigned char *d, size_t len) {
  size_t pos = 12;
  int fmt = 0, ch = 0, rate = 0, bits = 0;
  if (len < 12 || memcmp(d, "RIFF", 4) || memcmp(d + 8, "WAVE", 4)) return NULL;
  while (pos + 8 <= len) {
    uint32_t sz = rd32(d + pos + 4);
    const unsigned char *c = d + pos + 8;
    if (!memcmp(d + pos, "fmt ", 4) && sz >= 16) {
      fmt = rd16(c); ch = rd16(c + 2); rate = (int)rd32(c + 4); bits = rd16(c + 14);
    } else if (!memcmp(d + pos, "data", 4) && fmt == 1 && ch > 0) {
      int bps = bits / 8, frames, i;
      Pcm *p;
      if (sz > len - pos - 8) sz = (uint32_t)(len - pos - 8);
      if (bps < 1) return NULL;
      frames = (int)(sz / (bps * ch));
      p = pcm_new(frames, ch, rate, 16);
      if (!p) return NULL;
      for (i = 0; i < frames * ch; i++) {
        if (bps == 1) p->s[i] = (int16_t)((c[i] - 128) << 8);
        else p->s[i] = (int16_t)rd16(c + i * bps + (bps - 2));
      }
      return p;
    }
    pos += 8 + sz + (sz & 1);
  }
  return NULL;
}

static Pcm *decode_audio(lua_State *L, int idx) {
  size_t len;
  char *buf = lp_read_source(L, idx, &len, NULL);
  Pcm *p = NULL;
  if (!buf) luaL_error(L, "could not read audio");
  p = decode_wav((const unsigned char *)buf, len);
  if (!p && len > 4 && !memcmp(buf, "OggS", 4)) {
    int ch, rate;
    short *out;
    int frames = stb_vorbis_decode_memory((const unsigned char *)buf, (int)len, &ch, &rate, &out);
    if (frames > 0) {
      p = (Pcm *)calloc(1, sizeof(Pcm));
      if (p) { p->refs = 1; p->frames = frames; p->channels = ch; p->rate = rate; p->bits = 16; p->s = out; }
      else free(out);
    }
  }
  free(buf);
  if (!p) luaL_error(L, "Could not decode audio (only WAV and Ogg Vorbis are supported on PSP)");
  return p;
}

static int snd_newSoundData(lua_State *L) {
  if (lua_isnumber(L, 1)) {
    int frames = (int)luaL_checkinteger(L, 1);
    int rate = (int)luaL_optinteger(L, 2, 44100), bits = (int)luaL_optinteger(L, 3, 16);
    int ch = (int)luaL_optinteger(L, 4, 2);
    Pcm *p;
    if (ch < 1 || ch > 2) return luaL_error(L, "Invalid channel count: %d", ch);
    p = pcm_new(frames, ch, rate, bits);
    if (!p) return luaL_error(L, "out of memory creating SoundData (%d samples)", frames);
    push_sd(L, p);
    return 1;
  }
  push_sd(L, decode_audio(L, 1));
  return 1;
}
static int snd_newDecoder(lua_State *L) { return luaL_error(L, "Decoders are not supported on PSP"); }

static const luaL_Reg snd_funcs[] = {{"newSoundData", snd_newSoundData}, {"newDecoder", snd_newDecoder}, {NULL, NULL}};

int lp_open_sound(lua_State *L) {
  lp_register_type(L, &SoundData_type);
  luaL_newlib(L, snd_funcs);
  return 1;
}

/* ------------------------------------------------------------ Sources */

#define QMAX 64
enum { ST_STOPPED, ST_PLAYING, ST_PAUSED };

typedef struct Source {
  int refs;
  int queue;          /* queueable source */
  Pcm *pcm;           /* static */
  Pcm *q[QMAX];       /* queue ring */
  int qhead, qcount;  /* guarded by the audio lock */
  int qdone;          /* consumed buffers waiting to be freed (main thread) */
  int qmax;
  int rate, channels, bits;
  double pos;         /* frame position in the current buffer */
  float volume, pitch;
  int looping;
  int state;
  int active_ref;     /* registry ref while playing */
} Source;

typedef struct SourceObj { Source *s; } SourceObj;
static LPType Source_type;

#define MAX_ACTIVE 32
static Source *g_active[MAX_ACTIVE];
static int g_nactive;
static float g_master = 1.0f;
static int g_audio_ok;

static Source *checksrc(lua_State *L, int i) {
  SourceObj *o = (SourceObj *)lp_checkobj(L, i, &Source_type);
  if (!o->s) luaL_error(L, "Source has been released");
  return o->s;
}

/* before a Lua state closes (restart): forget every playing source so the
 * mixer never touches objects the collector is about to free */
void lp_audio_reset(void) {
  plat_audio_lock();
  g_nactive = 0;
  plat_audio_unlock();
}

/* main thread: free consumed queue buffers */
static void reap(Source *s) {
  Pcm *freed[QMAX];
  int n = 0, i;
  plat_audio_lock();
  while (s->qdone > 0) {
    int idx = (s->qhead - s->qdone + QMAX * 2) % QMAX;
    freed[n++] = s->q[idx];
    s->q[idx] = NULL;
    s->qdone--;
  }
  plat_audio_unlock();
  for (i = 0; i < n; i++) pcm_release(freed[i]);
}

static void mix(int16_t *out, int frames) {
  static int32_t acc[2048 * 2];
  int i, k;
  if (frames > 2048) frames = 2048;
  memset(acc, 0, sizeof(int32_t) * frames * 2);
  for (k = 0; k < g_nactive; k++) {
    Source *s = g_active[k];
    int vol = (int)(s->volume * g_master * 256.0f);
    if (s->state != ST_PLAYING) continue;
    for (i = 0; i < frames; i++) {
      Pcm *p = s->queue ? (s->qcount ? s->q[s->qhead] : NULL) : s->pcm;
      int fi, l, r;
      double step;
      if (!p) { s->state = ST_STOPPED; s->pos = 0; break; } /* queue ran dry */
      if (p->frames == 0) {
        if (s->queue) { s->qhead = (s->qhead + 1) % QMAX; s->qcount--; s->qdone++; i--; continue; }
        s->state = ST_STOPPED;
        break;
      }
      step = (double)p->rate / PLAT_AUDIO_RATE * s->pitch;
      fi = (int)s->pos;
      if (fi >= p->frames) {
        if (s->queue) {
          s->qhead = (s->qhead + 1) % QMAX;
          s->qcount--;
          s->qdone++;
          s->pos -= p->frames;
          i--;
          continue;
        }
        if (s->looping) { s->pos = fmod(s->pos, (double)p->frames); fi = (int)s->pos; }
        else { s->state = ST_STOPPED; s->pos = 0; break; }
      }
      {
        /* linear interpolation inside the buffer */
        double frac = s->pos - fi;
        int fj = fi + 1 < p->frames ? fi + 1 : fi;
        if (p->channels == 1) {
          l = r = (int)(p->s[fi] + (p->s[fj] - p->s[fi]) * frac);
        } else {
          l = (int)(p->s[fi * 2] + (p->s[fj * 2] - p->s[fi * 2]) * frac);
          r = (int)(p->s[fi * 2 + 1] + (p->s[fj * 2 + 1] - p->s[fi * 2 + 1]) * frac);
        }
      }
      acc[i * 2] += (l * vol) >> 8;
      acc[i * 2 + 1] += (r * vol) >> 8;
      s->pos += step;
    }
  }
  for (i = 0; i < frames * 2; i++) {
    int32_t v = acc[i];
    out[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
  }
}

void audio_start(void) {
  if (!g_audio_ok) g_audio_ok = plat_audio_start(mix) == 0;
}

static void deactivate(lua_State *L, Source *s) {
  int k;
  plat_audio_lock();
  for (k = 0; k < g_nactive; k++) {
    if (g_active[k] == s) {
      g_active[k] = g_active[--g_nactive];
      break;
    }
  }
  plat_audio_unlock();
  if (s->active_ref != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, s->active_ref);
    s->active_ref = LUA_NOREF;
  }
}

/* main thread housekeeping: drop finished sources, reap queue buffers */
static int audio_update(lua_State *L) {
  int k;
  for (k = g_nactive - 1; k >= 0; k--) {
    Source *s = g_active[k];
    if (s->queue) reap(s);
    if (s->state == ST_STOPPED) deactivate(L, s);
  }
  return 0;
}

static void src_release(Source *s) {
  int i;
  if (--s->refs > 0) return;
  pcm_release(s->pcm);
  for (i = 0; i < QMAX; i++) pcm_release(s->q[i]);
  free(s);
}

static int src_gc(lua_State *L) {
  SourceObj *o = (SourceObj *)lua_touserdata(L, 1);
  if (o->s) {
    deactivate(L, o->s);
    src_release(o->s);
    o->s = NULL;
  }
  return 0;
}

static int src_play(lua_State *L) {
  Source *s = checksrc(L, 1);
  int k, found = 0;
  if (s->queue) reap(s);
  plat_audio_lock();
  for (k = 0; k < g_nactive; k++) if (g_active[k] == s) found = 1;
  if (!found && g_nactive >= MAX_ACTIVE) { plat_audio_unlock(); lua_pushboolean(L, 0); return 1; }
  if (!found) g_active[g_nactive++] = s;
  s->state = ST_PLAYING;
  plat_audio_unlock();
  if (s->active_ref == LUA_NOREF) {
    lua_pushvalue(L, 1);
    s->active_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  }
  lua_pushboolean(L, 1);
  return 1;
}
static int src_stop(lua_State *L) {
  Source *s = checksrc(L, 1);
  plat_audio_lock();
  s->state = ST_STOPPED;
  s->pos = 0;
  if (s->queue) {
    /* stopping a queueable source discards everything queued */
    s->qdone += s->qcount;
    s->qhead = (s->qhead + s->qcount) % QMAX;
    s->qcount = 0;
  }
  plat_audio_unlock();
  if (s->queue) reap(s);
  deactivate(L, s);
  return 0;
}
static int src_pause(lua_State *L) {
  Source *s = checksrc(L, 1);
  plat_audio_lock();
  if (s->state == ST_PLAYING) s->state = ST_PAUSED;
  plat_audio_unlock();
  return 0;
}
static int src_isPlaying(lua_State *L) {
  Source *s = checksrc(L, 1);
  lua_pushboolean(L, s->state == ST_PLAYING);
  return 1;
}
static int src_setVolume(lua_State *L) { checksrc(L, 1)->volume = (float)luaL_checknumber(L, 2); return 0; }
static int src_getVolume(lua_State *L) { lua_pushnumber(L, checksrc(L, 1)->volume); return 1; }
static int src_setPitch(lua_State *L) {
  float p = (float)luaL_checknumber(L, 2);
  if (p <= 0) return luaL_error(L, "Pitch has to be non-zero, positive, finite number.");
  checksrc(L, 1)->pitch = p;
  return 0;
}
static int src_getPitch(lua_State *L) { lua_pushnumber(L, checksrc(L, 1)->pitch); return 1; }
static int src_setLooping(lua_State *L) {
  Source *s = checksrc(L, 1);
  if (s->queue && lua_toboolean(L, 2)) return luaL_error(L, "Queueable Sources can not be looped.");
  s->looping = lua_toboolean(L, 2);
  return 0;
}
static int src_isLooping(lua_State *L) { lua_pushboolean(L, checksrc(L, 1)->looping); return 1; }
static int src_seek(lua_State *L) {
  Source *s = checksrc(L, 1);
  double off = luaL_checknumber(L, 2);
  const char *unit = luaL_optstring(L, 3, "seconds");
  plat_audio_lock();
  s->pos = !strcmp(unit, "samples") ? off : off * s->rate;
  plat_audio_unlock();
  return 0;
}
static int src_tell(lua_State *L) {
  Source *s = checksrc(L, 1);
  const char *unit = luaL_optstring(L, 2, "seconds");
  if (!strcmp(unit, "samples")) lua_pushinteger(L, (lua_Integer)s->pos);
  else lua_pushnumber(L, s->pos / s->rate);
  return 1;
}
static int src_getDuration(lua_State *L) {
  Source *s = checksrc(L, 1);
  const char *unit = luaL_optstring(L, 2, "seconds");
  int frames = s->pcm ? s->pcm->frames : 0;
  if (s->queue) { lua_pushnumber(L, -1); return 1; }
  if (!strcmp(unit, "samples")) lua_pushinteger(L, frames);
  else lua_pushnumber(L, (double)frames / s->rate);
  return 1;
}
static int src_queue(lua_State *L) {
  Source *s = checksrc(L, 1);
  Pcm *src, *copy;
  size_t n;
  if (!s->queue) return luaL_error(L, "Only queueable Sources can be queued with sound data.");
  reap(s);
  if (lua_type(L, 2) == LUA_TLIGHTUSERDATA) return luaL_error(L, "queue(pointer) is not supported");
  src = checksd(L, 2);
  if (s->qcount + s->qdone >= s->qmax) { lua_pushboolean(L, 0); return 1; }
  n = (size_t)src->frames;
  copy = pcm_new((int)n, src->channels, src->rate, src->bits);
  if (!copy) return luaL_error(L, "out of memory queueing audio");
  memcpy(copy->s, src->s, n * src->channels * 2);
  plat_audio_lock();
  s->q[(s->qhead + s->qcount) % QMAX] = copy;
  s->qcount++;
  plat_audio_unlock();
  lua_pushboolean(L, 1);
  return 1;
}
static int src_getFreeBufferCount(lua_State *L) {
  Source *s = checksrc(L, 1);
  if (!s->queue) { lua_pushinteger(L, 0); return 1; }
  reap(s);
  lua_pushinteger(L, s->qmax - s->qcount - s->qdone);
  return 1;
}
static int src_getType(lua_State *L) { lua_pushstring(L, checksrc(L, 1)->queue ? "queue" : "static"); return 1; }
static int src_getChannelCount(lua_State *L) { lua_pushinteger(L, checksrc(L, 1)->channels); return 1; }
static int src_noop(lua_State *L) { (void)L; return 0; }
static int src_false(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int src_zero3(lua_State *L) { lua_pushnumber(L, 0); lua_pushnumber(L, 0); lua_pushnumber(L, 0); return 3; }
static int src_getVolumeLimits(lua_State *L) { lua_pushnumber(L, 0); lua_pushnumber(L, 1); return 2; }
static int src_clone(lua_State *L);
static int src_getActiveEffects(lua_State *L) { lua_newtable(L); return 1; }

static const luaL_Reg src_methods[] = {
  {"play", src_play}, {"stop", src_stop}, {"pause", src_pause}, {"resume", src_play},
  {"isPlaying", src_isPlaying}, {"setVolume", src_setVolume}, {"getVolume", src_getVolume},
  {"setPitch", src_setPitch}, {"getPitch", src_getPitch}, {"setLooping", src_setLooping},
  {"isLooping", src_isLooping}, {"seek", src_seek}, {"tell", src_tell},
  {"getDuration", src_getDuration}, {"queue", src_queue}, {"getFreeBufferCount", src_getFreeBufferCount},
  {"getType", src_getType}, {"getChannelCount", src_getChannelCount}, {"clone", src_clone},
  {"setPosition", src_noop}, {"getPosition", src_zero3}, {"setVelocity", src_noop},
  {"getVelocity", src_zero3}, {"setDirection", src_noop}, {"getDirection", src_zero3},
  {"setRelative", src_noop}, {"isRelative", src_false}, {"setAttenuationDistances", src_noop},
  {"setRolloff", src_noop}, {"setCone", src_noop}, {"setAirAbsorption", src_noop},
  {"setVolumeLimits", src_noop}, {"getVolumeLimits", src_getVolumeLimits},
  {"setFilter", src_noop}, {"getFilter", src_noop}, {"setEffect", src_false},
  {"getActiveEffects", src_getActiveEffects}, {NULL, NULL}};
static const char *const src_chain[] = {NULL};
static LPType Source_type = {"Source", src_chain, src_methods, src_gc};

static Source *src_alloc(void) {
  Source *s = (Source *)calloc(1, sizeof(Source));
  if (!s) return NULL;
  s->refs = 1;
  s->volume = 1; s->pitch = 1;
  s->active_ref = LUA_NOREF;
  return s;
}
static void push_src(lua_State *L, Source *s) {
  SourceObj *o = (SourceObj *)lp_newobj(L, &Source_type, sizeof(SourceObj));
  o->s = s;
}

static int src_clone(lua_State *L) {
  Source *s = checksrc(L, 1), *n = src_alloc();
  if (!n) return luaL_error(L, "out of memory");
  n->queue = s->queue; n->qmax = s->qmax;
  n->rate = s->rate; n->channels = s->channels; n->bits = s->bits;
  n->volume = s->volume; n->pitch = s->pitch; n->looping = s->looping;
  n->pcm = s->pcm;
  if (n->pcm) n->pcm->refs++;
  push_src(L, n);
  return 1;
}

static int au_newSource(lua_State *L) {
  Source *s = src_alloc();
  SoundDataObj *sd;
  if (!s) return luaL_error(L, "out of memory");
  sd = (SoundDataObj *)lp_testobj(L, 1, &SoundData_type);
  if (sd) {
    if (!sd->p) { free(s); return luaL_error(L, "SoundData has been released"); }
    s->pcm = sd->p;
    s->pcm->refs++;
  } else {
    s->pcm = decode_audio(L, 1);
  }
  s->rate = s->pcm->rate; s->channels = s->pcm->channels; s->bits = s->pcm->bits;
  push_src(L, s);
  return 1;
}
static int au_newQueueableSource(lua_State *L) {
  Source *s = src_alloc();
  if (!s) return luaL_error(L, "out of memory");
  s->queue = 1;
  s->rate = (int)luaL_checkinteger(L, 1);
  s->bits = (int)luaL_checkinteger(L, 2);
  s->channels = (int)luaL_checkinteger(L, 3);
  s->qmax = (int)luaL_optinteger(L, 4, 8);
  if (s->qmax < 1) s->qmax = 1;
  if (s->qmax > QMAX - 1) s->qmax = QMAX - 1;
  push_src(L, s);
  return 1;
}

static int au_play(lua_State *L) {
  if (lua_istable(L, 1)) {
    int n = (int)lua_rawlen(L, 1), i;
    for (i = 1; i <= n; i++) {
      lua_pushcfunction(L, src_play);
      lua_rawgeti(L, 1, i);
      lua_call(L, 1, 0);
    }
    lua_pushboolean(L, 1);
    return 1;
  }
  return src_play(L);
}
static int au_stop(lua_State *L) {
  if (lua_gettop(L) == 0) {
    while (g_nactive > 0) {
      Source *s = g_active[g_nactive - 1];
      plat_audio_lock();
      s->state = ST_STOPPED;
      s->pos = 0;
      plat_audio_unlock();
      deactivate(L, s);
    }
    return 0;
  }
  if (lua_istable(L, 1)) {
    int n = (int)lua_rawlen(L, 1), i;
    for (i = 1; i <= n; i++) { lua_pushcfunction(L, src_stop); lua_rawgeti(L, 1, i); lua_call(L, 1, 0); }
    return 0;
  }
  return src_stop(L);
}
static int au_pause(lua_State *L) {
  if (lua_gettop(L) == 0) {
    int k, n = 0;
    lua_newtable(L);
    for (k = 0; k < g_nactive; k++) {
      Source *s = g_active[k];
      if (s->state == ST_PLAYING) {
        s->state = ST_PAUSED;
        if (s->active_ref != LUA_NOREF) {
          lua_rawgeti(L, LUA_REGISTRYINDEX, s->active_ref);
          lua_rawseti(L, -2, ++n);
        }
      }
    }
    return 1;
  }
  if (lua_istable(L, 1)) {
    int n = (int)lua_rawlen(L, 1), i;
    for (i = 1; i <= n; i++) { lua_pushcfunction(L, src_pause); lua_rawgeti(L, 1, i); lua_call(L, 1, 0); }
    return 0;
  }
  return src_pause(L);
}
static int au_setVolume(lua_State *L) { g_master = (float)luaL_checknumber(L, 1); return 0; }
static int au_getVolume(lua_State *L) { lua_pushnumber(L, g_master); return 1; }
static int au_getActiveSourceCount(lua_State *L) {
  int k, n = 0;
  for (k = 0; k < g_nactive; k++) if (g_active[k]->state == ST_PLAYING) n++;
  lua_pushinteger(L, n);
  return 1;
}
static int au_noop(lua_State *L) { (void)L; return 0; }
static int au_false(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int au_emptytable(lua_State *L) { lua_newtable(L); return 1; }
static int au_zero3(lua_State *L) { lua_pushnumber(L, 0); lua_pushnumber(L, 0); lua_pushnumber(L, 0); return 3; }
static int au_getDistanceModel(lua_State *L) { lua_pushliteral(L, "none"); return 1; }
static int au_getMaxSceneEffects(lua_State *L) { lua_pushinteger(L, 0); return 1; }

static const luaL_Reg au_funcs[] = {
  {"newSource", au_newSource}, {"newQueueableSource", au_newQueueableSource},
  {"play", au_play}, {"stop", au_stop}, {"pause", au_pause}, {"resume", au_play},
  {"setVolume", au_setVolume}, {"getVolume", au_getVolume},
  {"getActiveSourceCount", au_getActiveSourceCount}, {"getSourceCount", au_getActiveSourceCount},
  {"setPosition", au_noop}, {"getPosition", au_zero3}, {"setOrientation", au_noop},
  {"setVelocity", au_noop}, {"getVelocity", au_zero3}, {"setDopplerScale", au_noop},
  {"setDistanceModel", au_noop}, {"getDistanceModel", au_getDistanceModel},
  {"setEffect", au_false}, {"getEffect", au_noop}, {"getActiveEffects", au_emptytable},
  {"isEffectsSupported", au_false}, {"getMaxSceneEffects", au_getMaxSceneEffects},
  {"getMaxSourceEffects", au_getMaxSceneEffects}, {"getRecordingDevices", au_emptytable},
  {"setMixWithSystem", au_false}, {"_update", audio_update}, {NULL, NULL}};

int lp_open_audio(lua_State *L) {
  lp_register_type(L, &Source_type);
  lp_register_type(L, &SoundData_type);
  audio_start();
  luaL_newlib(L, au_funcs);
  return 1;
}
