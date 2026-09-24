/*
 * Desktop backend (SDL2) for developing and testing the runtime off the
 * console.  Keyboard: arrows = D-pad, Z = Cross, X = Circle, A = Square,
 * S = Triangle, Q/W = L/R, Enter = Start, Right Shift/Backspace = Select.
 *
 * Automation (used by the test scripts):
 *   LOVEPSP_HEADLESS=1          no window, no audio device
 *   LOVEPSP_FRAMES=N            quit after N presented frames
 *   LOVEPSP_SHOT=N:path[,..]    write the PSP screen as PNG at frame N
 *   LOVEPSP_INPUT=F:BTN:D[,..]  hold BTN (up/down/left/right/cross/circle/
 *                               square/triangle/l/r/start/select, or
 *                               touch@X@Y for a finger at logical X,Y) from
 *                               frame F for D frames
 *   LOVEPSP_TOUCH=1             on-screen touch controls (always on for the Vita)
 *   LOVEPSP_BASE / LOVEPSP_SAVE override the base and save directories
 */
#ifndef __PSP__
#include <SDL2/SDL.h>
#ifdef __vita__
#include <psp2/kernel/processmgr.h>
#include <psp2/power.h>
/* the Vita's default newlib heap is 32 MiB; the engine wants far more */
int _newlib_heap_size_user = 256 * 1024 * 1024;
#define VITA_BASE "ux0:data/gen1recomp/"
#endif
#ifdef __ANDROID__
#include <android/log.h>
#include <jni.h>
#endif
#ifdef __PSL1GHT__
#include <sysutil/sysutil.h>
/* installed from the .pkg (or the folder) as /dev_hdd0/game/GEN1RECMP/ */
#define PS3_BASE "/dev_hdd0/game/GEN1RECMP/USRDIR/"
#endif
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "plat.h"
#include "plat_common.h"
#include "lp.h"

int lp_write_png(const char *path, const uint32_t *px, int w, int h);

static SDL_Window *g_win;
static SDL_GameController *g_pad;
static SDL_Joystick *g_joy; /* raw pad when no controller mapping exists (PS3) */
static SDL_Renderer *g_ren;
static SDL_Texture *g_tex;
static uint32_t *g_screen; /* PLAT_SCREEN_W x PLAT_MAX_LH, allocated at init: tall enough for a portrait phone (a static array this size upsets vita-elf-create) */
static int g_lh = PLAT_SCREEN_H; /* current logical height */
static int g_ds;
static int g_top = PLAT_SCREEN_H, g_bottom = PLAT_SCREEN_H; /* DS halves */
static float g_hinge = -1;
static char g_base[1024], g_save[1100], g_self[1100];
static int g_headless, g_quit;
static long g_frame, g_max_frames = -1;
static long g_subframe; /* headless: ticks within a frame so time never stalls */
static SDL_AudioDeviceID g_adev;
static void sdl_audio(void *ud, Uint8 *stream, int len);
static plat_audio_cb g_acb;
static SDL_mutex *g_amutex;

typedef struct { long frame; char path[512]; } Shot;
static Shot g_shots[64];
static int g_nshots;
typedef struct { long from, len; uint32_t btn; float tx, ty; int axis; } Hold; /* tx >= 0: a synthetic finger; axis: 1 rup 2 rdown 3 lup 4 ldown 5 l2 6 r2 */
static Hold g_holds[256];
static int g_nholds;
static long g_pad_frame, g_touch_frame; /* last frame each source was used, for the overlay */
static const uint32_t *g_hud; static int g_hud_w, g_hud_h; /* shell HUD layer (sidebars) */
static int g_hud_k = 1;               /* the HUD's scale over the logical frame (1..4) */
static SDL_Texture *g_hudtex; static int g_hudtex_w, g_hudtex_h;
static uint32_t g_inject; /* buttons held by a shell-drawn skin */

static uint32_t btn_from_name(const char *n) {
  static const struct { const char *n; uint32_t b; } map[] = {
    {"up", PB_UP}, {"down", PB_DOWN}, {"left", PB_LEFT}, {"right", PB_RIGHT},
    {"cross", PB_CROSS}, {"circle", PB_CIRCLE}, {"square", PB_SQUARE},
    {"triangle", PB_TRIANGLE}, {"l", PB_LTRIGGER}, {"r", PB_RTRIGGER},
    {"start", PB_START}, {"select", PB_SELECT}, {0, 0}};
  int i;
  for (i = 0; map[i].n; i++) if (!strcmp(map[i].n, n)) return map[i].b;
  return 0;
}

static void parse_env(void) {
  const char *s = getenv("LOVEPSP_SHOT");
  char buf[8192], *tok, *save;
  if (getenv("LOVEPSP_FRAMES")) g_max_frames = atol(getenv("LOVEPSP_FRAMES"));
  if (s) {
    strncpy(buf, s, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    for (tok = strtok_r(buf, ",", &save); tok && g_nshots < 64; tok = strtok_r(NULL, ",", &save)) {
      char *c = strchr(tok, ':');
      if (!c) continue;
      *c = 0;
      g_shots[g_nshots].frame = atol(tok);
      strncpy(g_shots[g_nshots].path, c + 1, 511);
      g_nshots++;
    }
  }
  s = getenv("LOVEPSP_INPUT");
  if (s) {
    strncpy(buf, s, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    for (tok = strtok_r(buf, ",", &save); tok && g_nholds < 256; tok = strtok_r(NULL, ",", &save)) {
      char name[32]; long f, d;
      if (sscanf(tok, "%ld:%31[a-z@0-9]:%ld", &f, name, &d) == 3) {
        float tx, ty;
        g_holds[g_nholds].from = f; g_holds[g_nholds].len = d;
        g_holds[g_nholds].tx = g_holds[g_nholds].ty = -1;
        g_holds[g_nholds].axis = 0;
        if (sscanf(name, "touch@%f@%f", &tx, &ty) == 2) {
          /* touch@X@Y: hold a finger at logical screen coordinates */
          g_holds[g_nholds].btn = 0;
          g_holds[g_nholds].tx = tx; g_holds[g_nholds].ty = ty;
        } else if (!strcmp(name, "rup")) g_holds[g_nholds].axis = 1;
        else if (!strcmp(name, "rdown")) g_holds[g_nholds].axis = 2;
        else if (!strcmp(name, "lup")) g_holds[g_nholds].axis = 3;
        else if (!strcmp(name, "ldown")) g_holds[g_nholds].axis = 4;
        else if (!strcmp(name, "l2")) g_holds[g_nholds].axis = 5;
        else if (!strcmp(name, "r2")) g_holds[g_nholds].axis = 6;
        else g_holds[g_nholds].btn = btn_from_name(name);
        g_nholds++;
      }
    }
  }
}

static void ensure_slash(char *p, size_t n) {
  size_t l = strlen(p);
  if (l && p[l - 1] != '/' && l + 1 < n) { p[l] = '/'; p[l + 1] = 0; }
}

int plat_init(int argc, char **argv) {
  const char *b = getenv("LOVEPSP_BASE"), *sv = getenv("LOVEPSP_SAVE");
  g_headless = getenv("LOVEPSP_HEADLESS") && atoi(getenv("LOVEPSP_HEADLESS"));
  parse_env();
#if defined(__vita__) || defined(__ANDROID__)
  touch_set_enabled(1);
#ifdef __vita__
  touch_set_pad(0); /* real buttons: taps only, no drawn pad */
#endif
#else
  if (getenv("LOVEPSP_TOUCH")) touch_set_enabled(atoi(getenv("LOVEPSP_TOUCH")));
#endif
  if (getenv("LOVEPSP_LAYOUT") && !strcmp(getenv("LOVEPSP_LAYOUT"), "ds")) plat_set_layout(1);
  if (getenv("LOVEPSP_HINGE")) g_hinge = (float)atof(getenv("LOVEPSP_HINGE"));
#if defined(__PSL1GHT__)
  strcpy(g_base, PS3_BASE);
  mkdir(g_base, 0777);
#elif defined(__vita__)
  strcpy(g_base, VITA_BASE);
  mkdir("ux0:data", 0777);
  mkdir(g_base, 0777);
  scePowerSetArmClockFrequency(444);
  scePowerSetBusClockFrequency(222);
  scePowerSetGpuClockFrequency(222);
#elif defined(__ANDROID__)
  {
    /* the app's external files dir: /sdcard/Android/data/com.nahalewski.g1rports/files/
     * (ROMs go there, or in roms/ under it); game.pak is copied out of the
     * APK's assets once, so the C side can read it with stdio */
    const char *ext = SDL_AndroidGetExternalStoragePath();
    SDL_RWops *in;
    snprintf(g_base, sizeof g_base, "%s/", ext ? ext : "/sdcard");
    mkdir(g_base, 0777);
    snprintf(g_self, sizeof g_self, "%sgame.pak", g_base);
    in = SDL_RWFromFile("game.pak", "rb");
    if (in) {
      Sint64 want = SDL_RWsize(in);
      struct stat st;
      if (stat(g_self, &st) != 0 || (Sint64)st.st_size != want) {
        FILE *out = fopen(g_self, "wb");
        if (out) {
          static char buf[65536];
          size_t n;
          while ((n = SDL_RWread(in, buf, 1, sizeof buf)) > 0) fwrite(buf, 1, n, out);
          fclose(out);
        }
      }
      SDL_RWclose(in);
    }
  }
#else
  if (b) strncpy(g_base, b, sizeof g_base - 2);
  else if (argc > 0) {
    char *slash;
    strncpy(g_base, argv[0], sizeof g_base - 2);
    slash = strrchr(g_base, '/');
    if (slash) slash[1] = 0; else strcpy(g_base, "./");
  } else strcpy(g_base, "./");
#endif
  ensure_slash(g_base, sizeof g_base);
  if (sv) { strncpy(g_save, sv, sizeof g_save - 2); ensure_slash(g_save, sizeof g_save); }
  else snprintf(g_save, sizeof g_save, "%ssave/", g_base);
  mkdir(g_save, 0777);
  /* the host build reads its archive from EBOOT.PBP or game.pak next to it;
   * the Vita's lives inside the installed app (app0:) */
#if defined(__vita__)
  strcpy(g_self, "app0:game.pak");
#elif defined(__ANDROID__)
  /* set above */
#elif defined(__PSL1GHT__)
  snprintf(g_self, sizeof g_self, "%sgame.pak", g_base);
#else
  if (getenv("LOVEPSP_ARCHIVE")) strncpy(g_self, getenv("LOVEPSP_ARCHIVE"), sizeof g_self - 1);
  else snprintf(g_self, sizeof g_self, "%sEBOOT.PBP", g_base);
#endif

  if (!g_screen) g_screen = (uint32_t *)calloc((size_t)PLAT_SCREEN_W * PLAT_MAX_LH, sizeof(uint32_t));
  if (SDL_Init((g_headless ? 0 : SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER) | SDL_INIT_TIMER) != 0) {
    fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
    return -1;
  }
  if (!g_headless) {
    g_win = SDL_CreateWindow("lovepsp", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
#if defined(__PSL1GHT__)
                             1280, 720, SDL_WINDOW_FULLSCREEN);
#elif defined(__vita__) || defined(__ANDROID__)
                             PLAT_SCREEN_W * 2, PLAT_SCREEN_H * 2, SDL_WINDOW_FULLSCREEN);
#else
                             PLAT_SCREEN_W * 2, PLAT_SCREEN_H * 2, SDL_WINDOW_RESIZABLE);
#endif
    if (SDL_NumJoysticks() > 0) {
      if (SDL_IsGameController(0)) g_pad = SDL_GameControllerOpen(0);
      else g_joy = SDL_JoystickOpen(0);
    }
    g_ren = SDL_CreateRenderer(g_win, -1, SDL_RENDERER_PRESENTVSYNC);
    if (!g_ren) g_ren = SDL_CreateRenderer(g_win, -1, 0);
    SDL_RenderSetLogicalSize(g_ren, PLAT_SCREEN_W, PLAT_SCREEN_H);
    /* RGBA32 is the byte-order alias: R,G,B,A in memory on any endianness */
    g_tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STREAMING,
                              PLAT_SCREEN_W, PLAT_SCREEN_H);
  }
  return 0;
}

void plat_shutdown(void) {
  if (g_adev) SDL_CloseAudioDevice(g_adev);
  SDL_Quit();
#ifdef __vita__
  sceKernelExitProcess(0);
#endif
  exit(0);
}

int plat_touch(int on) {
  if (on >= 0) touch_set_enabled(on);
  return touch_enabled();
}
int plat_touch_pad(int on) {
  if (on >= 0) touch_set_pad(on);
  return touch_pad();
}
void plat_inject(uint32_t buttons) { g_inject = buttons; }
void plat_set_game_rect(int x, int y, int w, int h) { plat_layout_set_game_rect(x, y, w, h); }

void plat_screen_size(int *w, int *h) { *w = PLAT_SCREEN_W; *h = g_lh; }
int plat_get_layout(void) { return g_ds; }
/* 0: one screen.  1 (ds): double-height logical screen, game above,
 * controls below.  2 (dual): the same double-height screen, but the window
 * shows only the top half; the bottom half is read by plat_bottom_half()
 * for a second display. */
static void relayout(void) {
  int shown;
  g_lh = g_ds ? g_top + g_bottom : PLAT_SCREEN_H;
  shown = g_ds == 1 ? g_lh : (g_ds == 2 ? g_top : PLAT_SCREEN_H);
  touch_set_offset(g_ds ? g_top : 0);
  if (g_ren) {
    if (g_tex) SDL_DestroyTexture(g_tex);
    SDL_RenderSetLogicalSize(g_ren, PLAT_SCREEN_W, shown);
    g_tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STREAMING, PLAT_SCREEN_W, shown);
  }
}
void plat_set_layout(int mode) {
  if (mode < 0 || mode > 2) mode = 0;
  if (mode == g_ds) return;
  g_ds = mode;
  relayout();
}
void plat_set_split(int top, int bottom) {
  if (top < 64) top = PLAT_SCREEN_H;
  if (bottom < 64) bottom = PLAT_SCREEN_H;
  if (top + bottom > PLAT_MAX_LH) { top = PLAT_SCREEN_H; bottom = PLAT_SCREEN_H; }
  if (top == g_top && bottom == g_bottom) return;
  g_top = top; g_bottom = bottom;
  if (g_ds) relayout();
}
void plat_get_split(int *top, int *bottom) { *top = g_top; *bottom = g_bottom; }
void plat_set_hinge(float d) { g_hinge = d; }
#ifdef __ANDROID__
int plat_open_url(const char *url) {
  JNIEnv *env = (JNIEnv *)SDL_AndroidGetJNIEnv();
  jobject activity = (jobject)SDL_AndroidGetActivity();
  jclass cls;
  jmethodID mid;
  jstring js;
  if (!env || !activity) return 0;
  cls = (*env)->GetObjectClass(env, activity);
  mid = (*env)->GetMethodID(env, cls, "openUrl", "(Ljava/lang/String;)V");
  if (!mid) { (*env)->DeleteLocalRef(env, cls); (*env)->DeleteLocalRef(env, activity); return 0; }
  js = (*env)->NewStringUTF(env, url);
  (*env)->CallVoidMethod(env, activity, mid, js);
  (*env)->DeleteLocalRef(env, js);
  (*env)->DeleteLocalRef(env, cls);
  (*env)->DeleteLocalRef(env, activity);
  return 1;
}
#else
int plat_open_url(const char *url) { (void)url; return 0; }
#endif
float plat_hinge(void) { return g_hinge; }

/* bottom half of the logical screen as 0xAARRGGBB ints (dual mode) */
int plat_bottom_half(uint32_t *out, int w, int h) {
  int x, y;
  if (g_ds != 2 || w != PLAT_SCREEN_W || h != g_bottom) return 0;
  for (y = 0; y < h; y++) {
    const uint32_t *s = g_screen + (long)(g_top + y) * PLAT_SCREEN_W;
    for (x = 0; x < w; x++) {
      uint32_t p = s[x];
      out[(long)y * w + x] = 0xff000000u | (PX_R(p) << 16) | (PX_G(p) << 8) | PX_B(p);
    }
  }
  return 1;
}

/* the mixer's device dies with the app in the background on some hosts
 * (Vita3K): reopen it when the app comes back */
static void audio_restart(void) {
  SDL_AudioSpec want, have;
  if (g_headless || !g_acb) return;
  if (g_adev) SDL_CloseAudioDevice(g_adev);
  SDL_zero(want);
  want.freq = PLAT_AUDIO_RATE; want.format = AUDIO_S16SYS; want.channels = 2;
  want.samples = 1024; want.callback = sdl_audio;
  g_adev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
  if (g_adev) SDL_PauseAudioDevice(g_adev, 0);
}
int plat_touch_get(int i, float *x, float *y) { return touch_get(i, x, y); }
/* the overlay is the logical frame's size, or an integer multiple of it
 * (drawn sharper and blended over the frame by the GPU) */
void plat_set_overlay(const uint32_t *px, int w, int h) {
  int k;
  g_hud = px; g_hud_w = w; g_hud_h = h; g_hud_k = 1;
  if (!px) return;
  for (k = 1; k <= 4; k++)
    if (w == PLAT_SCREEN_W * k && h == g_lh * k) { g_hud_k = k; return; }
  g_hud = NULL;
}
void plat_output_size(int *w, int *h) {
  const char *env = getenv("LOVEPSP_DISPLAY");
  *w = 0; *h = 0;
  if (g_ren) { SDL_GetRendererOutputSize(g_ren, w, h); return; }
  if (env && sscanf(env, "%dx%d", w, h) == 2) return;
  *w = 0; *h = 0;
}
void plat_set_bars(int left, int right) { plat_layout_set_bars(left, right); }

/* software blend of the HUD into the frame: the 1x HUD, or (headless) a
 * scaled HUD sampled down so screenshots still show it */
static void composite_hud(void) {
  int x, y, k = g_hud_k;
  if (!g_hud) return;
  if (k > 1 && !g_headless) return;   /* the GPU blends it in plat_present */
  for (y = 0; y < g_lh; y++) {
    const uint32_t *s = g_hud + (long)y * k * g_hud_w;
    uint32_t *d = g_screen + (long)y * PLAT_SCREEN_W;
    for (x = 0; x < PLAT_SCREEN_W; x++) {
      uint32_t sp = s[x * k];
      int a = PX_A(sp);
      if (a == 0) continue;
      if (a == 255) { d[x] = sp | PX_AMASK; continue; }
      {
        uint32_t dp = d[x];
        int r = PX_R(dp) + (((int)PX_R(sp) - (int)PX_R(dp)) * a) / 255;
        int g = PX_G(dp) + (((int)PX_G(sp) - (int)PX_G(dp)) * a) / 255;
        int b = PX_B(dp) + (((int)PX_B(sp) - (int)PX_B(dp)) * a) / 255;
        d[x] = PX(r, g, b, 255);
      }
    }
  }
}

void plat_present(const uint32_t *px, int w, int h, int mode, int smooth) {
  int i;
  if (g_ds) {
    /* DS layout: the game fills the top half, the bottom half is the
     * control surface (touch pad, panels) */
    int y;
    if (mode == 4) mode = 1;
    plat_blit_scaled(px, w, h, g_screen, PLAT_SCREEN_W, PLAT_SCREEN_W, g_top, mode, smooth);
    for (y = g_top; y < g_lh; y++) {
      uint32_t *row = g_screen + (long)y * PLAT_SCREEN_W;
      int x;
      for (x = 0; x < PLAT_SCREEN_W; x++) row[x] = PX(16, 16, 20, 255);
    }
    touch_set_visible(touch_enabled() && w * 2 <= PLAT_SCREEN_W && !plat_layout_custom_bars());
  } else {
    if (touch_enabled() && (touch_pad() || plat_layout_custom_bars())) {
      /* a game (small source) sits between the control bars; the launcher
       * fills the screen and takes taps directly through lovepsp.touches() */
      if (touch_pad() || plat_layout_custom_bars()) mode = 4;
      /* the pad hides while the shell's sidebars own the bars */
      touch_set_visible(w * 2 <= PLAT_SCREEN_W && !plat_layout_custom_bars());
    }
    plat_blit_scaled(px, w, h, g_screen, PLAT_SCREEN_W, PLAT_SCREEN_W, PLAT_SCREEN_H, mode, smooth);
  }
  if (touch_visible()) touch_draw(g_screen, PLAT_SCREEN_W, g_lh, g_pad_frame > g_touch_frame);
  composite_hud();
  g_frame++;
  for (i = 0; i < g_nshots; i++)
    if (g_shots[i].frame == g_frame) lp_write_png(g_shots[i].path, g_screen, PLAT_SCREEN_W, g_lh);
  if (g_max_frames >= 0 && g_frame >= g_max_frames) g_quit = 1;
  if (g_headless) return;
  SDL_UpdateTexture(g_tex, NULL, g_screen, PLAT_SCREEN_W * 4);
  SDL_RenderClear(g_ren);
  SDL_RenderCopy(g_ren, g_tex, NULL, NULL);
  if (g_hud && g_hud_k > 1) {
    if (!g_hudtex || g_hudtex_w != g_hud_w || g_hudtex_h != g_hud_h) {
      if (g_hudtex) SDL_DestroyTexture(g_hudtex);
      g_hudtex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STREAMING, g_hud_w, g_hud_h);
      g_hudtex_w = g_hud_w; g_hudtex_h = g_hud_h;
      if (g_hudtex) {
        SDL_SetTextureBlendMode(g_hudtex, SDL_BLENDMODE_BLEND);
#if SDL_VERSION_ATLEAST(2, 0, 12)
        SDL_SetTextureScaleMode(g_hudtex, SDL_ScaleModeLinear);
#endif
      }
    }
    if (g_hudtex) {
      SDL_UpdateTexture(g_hudtex, NULL, g_hud, g_hud_w * 4);
      SDL_RenderCopy(g_ren, g_hudtex, NULL, NULL);
    }
  }
  SDL_RenderPresent(g_ren);
}

void plat_vsync(void) {
  if (g_headless) return;
  SDL_Delay(1);
}

/* a finger's normalised window position -> logical pixels.  The renderer
 * letterboxes the logical frame when the window's aspect differs (a
 * foldable's square inner screen, the cover screen), so the finger goes
 * through the same viewport and scale the frame is drawn with. */
static void finger_to_logical(float fx, float fy, float *lx, float *ly) {
  int ow = PLAT_SCREEN_W, oh = g_lh;
  SDL_Rect vp = { 0, 0, 0, 0 };
  float sx = 1, sy = 1;
  if (g_ren) {
    SDL_GetRendererOutputSize(g_ren, &ow, &oh);
    SDL_RenderGetViewport(g_ren, &vp);
    SDL_RenderGetScale(g_ren, &sx, &sy);
  }
  if (sx <= 0) sx = 1;
  if (sy <= 0) sy = 1;
  *lx = fx * ow / sx - vp.x;
  *ly = fy * oh / sy - vp.y;
}

void plat_poll(PlatInput *in) {
  SDL_Event e;
  uint32_t b = 0;
  int i;
  if (!g_headless) {
    const Uint8 *k;
    while (SDL_PollEvent(&e)) {
      if (e.type == SDL_QUIT) g_quit = 1;
      else if (e.type == SDL_APP_DIDENTERFOREGROUND
               || (e.type == SDL_WINDOWEVENT && e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED)) audio_restart();
      else if (e.type == SDL_FINGERDOWN || e.type == SDL_FINGERUP || e.type == SDL_FINGERMOTION) {
        /* front panel only: the Vita reports the rear pad as a second device */
        if (e.tfinger.touchId == SDL_GetTouchDevice(0)) {
          float lx, ly;
          finger_to_logical(e.tfinger.x, e.tfinger.y, &lx, &ly);
          touch_finger((long)e.tfinger.fingerId, e.type != SDL_FINGERUP, lx, ly);
        }
      } else if (e.type == SDL_CONTROLLERDEVICEADDED) {
        /* a pad plugged or paired after start (Bluetooth controllers on Android) */
        if (!g_pad) g_pad = SDL_GameControllerOpen(e.cdevice.which);
      } else if (e.type == SDL_CONTROLLERDEVICEREMOVED) {
        if (g_pad && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pad)) == e.cdevice.which) {
          SDL_GameControllerClose(g_pad);
          g_pad = NULL;
        }
      } else if (touch_enabled() && (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP
                                     || e.type == SDL_MOUSEMOTION)) {
        /* desktop / Vita3K: the left mouse button is a finger */
        int down = e.type == SDL_MOUSEBUTTONDOWN
                   || (e.type == SDL_MOUSEMOTION && (e.motion.state & SDL_BUTTON_LMASK));
        int mx = e.type == SDL_MOUSEMOTION ? e.motion.x : e.button.x;
        int my = e.type == SDL_MOUSEMOTION ? e.motion.y : e.button.y;
        float lx, ly;
        if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button != SDL_BUTTON_LEFT) continue;
        if (e.type == SDL_MOUSEBUTTONUP && e.button.button != SDL_BUTTON_LEFT) continue;
        if (e.type == SDL_MOUSEMOTION && !down) continue;
        {
          /* window -> logical (SDL_RenderWindowToLogical needs 2.0.18; the PS3's SDL2 is older) */
          int ww = PLAT_SCREEN_W, wh = PLAT_SCREEN_H;
          SDL_GetWindowSize(g_win, &ww, &wh);
          lx = (float)mx * PLAT_SCREEN_W / (ww > 0 ? ww : 1);
          ly = (float)my * (g_ds == 2 ? g_top : g_lh) / (wh > 0 ? wh : 1);
        }
        touch_finger(-1, down, lx, ly);
      }
    }
    k = SDL_GetKeyboardState(NULL);
    if (k[SDL_SCANCODE_UP]) b |= PB_UP;
    if (k[SDL_SCANCODE_DOWN]) b |= PB_DOWN;
    if (k[SDL_SCANCODE_LEFT]) b |= PB_LEFT;
    if (k[SDL_SCANCODE_RIGHT]) b |= PB_RIGHT;
    if (k[SDL_SCANCODE_Z]) b |= PB_CROSS;
    if (k[SDL_SCANCODE_X]) b |= PB_CIRCLE;
    if (k[SDL_SCANCODE_A]) b |= PB_SQUARE;
    if (k[SDL_SCANCODE_S]) b |= PB_TRIANGLE;
    if (k[SDL_SCANCODE_Q]) b |= PB_LTRIGGER;
    if (k[SDL_SCANCODE_W]) b |= PB_RTRIGGER;
    if (k[SDL_SCANCODE_RETURN]) b |= PB_START;
    if (k[SDL_SCANCODE_RSHIFT] || k[SDL_SCANCODE_BACKSPACE]) b |= PB_SELECT;
    if (k[SDL_SCANCODE_ESCAPE]) g_quit = 1;
    if (g_pad) {
      static const struct { SDL_GameControllerButton b; uint32_t m; } map[] = {
        {SDL_CONTROLLER_BUTTON_DPAD_UP, PB_UP}, {SDL_CONTROLLER_BUTTON_DPAD_DOWN, PB_DOWN},
        {SDL_CONTROLLER_BUTTON_DPAD_LEFT, PB_LEFT}, {SDL_CONTROLLER_BUTTON_DPAD_RIGHT, PB_RIGHT},
        {SDL_CONTROLLER_BUTTON_A, PB_CROSS}, {SDL_CONTROLLER_BUTTON_B, PB_CIRCLE},
        {SDL_CONTROLLER_BUTTON_X, PB_SQUARE}, {SDL_CONTROLLER_BUTTON_Y, PB_TRIANGLE},
        {SDL_CONTROLLER_BUTTON_LEFTSHOULDER, PB_LTRIGGER}, {SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, PB_RTRIGGER},
        {SDL_CONTROLLER_BUTTON_START, PB_START}, {SDL_CONTROLLER_BUTTON_BACK, PB_SELECT}};
      unsigned j;
      for (j = 0; j < sizeof map / sizeof map[0]; j++)
        if (SDL_GameControllerGetButton(g_pad, map[j].b)) b |= map[j].m;
      in->ax = SDL_GameControllerGetAxis(g_pad, SDL_CONTROLLER_AXIS_LEFTX) / 32767.0f;
      in->ay = SDL_GameControllerGetAxis(g_pad, SDL_CONTROLLER_AXIS_LEFTY) / 32767.0f;
      in->rx = SDL_GameControllerGetAxis(g_pad, SDL_CONTROLLER_AXIS_RIGHTX) / 32767.0f;
      in->ry = SDL_GameControllerGetAxis(g_pad, SDL_CONTROLLER_AXIS_RIGHTY) / 32767.0f;
      in->lt = SDL_GameControllerGetAxis(g_pad, SDL_CONTROLLER_AXIS_TRIGGERLEFT) / 32767.0f;
      in->rt = SDL_GameControllerGetAxis(g_pad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) / 32767.0f;
    } else if (g_joy) {
      /* raw button order of SDL's PSL1GHT pad: select L3 R3 start up right
       * down left L2 R2 L1 R1 triangle circle cross square */
      static const uint32_t order[16] = {
        PB_SELECT, 0, 0, PB_START, PB_UP, PB_RIGHT, PB_DOWN, PB_LEFT,
        0, 0, PB_LTRIGGER, PB_RTRIGGER, PB_TRIANGLE, PB_CIRCLE, PB_CROSS, PB_SQUARE};
      int j, n = SDL_JoystickNumButtons(g_joy);
      for (j = 0; j < n && j < 16; j++) if (SDL_JoystickGetButton(g_joy, j)) b |= order[j];
      if (SDL_JoystickNumAxes(g_joy) >= 2) {
        in->ax = SDL_JoystickGetAxis(g_joy, 0) / 32767.0f;
        in->ay = SDL_JoystickGetAxis(g_joy, 1) / 32767.0f;
      }
      if (SDL_JoystickNumAxes(g_joy) >= 4) {
        in->rx = SDL_JoystickGetAxis(g_joy, 2) / 32767.0f;
        in->ry = SDL_JoystickGetAxis(g_joy, 3) / 32767.0f;
      }
      if (n > 9) { in->lt = SDL_JoystickGetButton(g_joy, 8) ? 1.f : 0.f; in->rt = SDL_JoystickGetButton(g_joy, 9) ? 1.f : 0.f; }
      if (SDL_JoystickNumHats(g_joy) > 0) {
        Uint8 hat = SDL_JoystickGetHat(g_joy, 0);
        if (hat & SDL_HAT_UP) b |= PB_UP;
        if (hat & SDL_HAT_DOWN) b |= PB_DOWN;
        if (hat & SDL_HAT_LEFT) b |= PB_LEFT;
        if (hat & SDL_HAT_RIGHT) b |= PB_RIGHT;
      }
    }
  }
  if (b) g_pad_frame = g_frame;
  if (!g_pad && !g_joy) in->ax = in->ay = 0;
  for (i = 0; i < g_nholds; i++) {
    int on = g_frame >= g_holds[i].from && g_frame < g_holds[i].from + g_holds[i].len;
    if (g_holds[i].tx >= 0) touch_finger(1000 + i, on, g_holds[i].tx, g_holds[i].ty);
    else if (on && g_holds[i].axis) {
      switch (g_holds[i].axis) {
        case 1: in->ry = -1; break; case 2: in->ry = 1; break;
        case 3: in->ay = -1; break; case 4: in->ay = 1; break;
        case 5: in->lt = 1; break; case 6: in->rt = 1; break;
      }
    }
    else if (on) b |= g_holds[i].btn;
  }
  {
    uint32_t t = touch_buttons() | g_inject;
    if (t) g_touch_frame = g_frame;
    b |= t;
  }
  in->buttons = b;
  in->quit = g_quit;
}

double plat_time(void) {
  /* headless runs are scripted by frame count, so time advances exactly one
   * 60 Hz frame per present regardless of how fast the host is */
  if (g_headless) return g_frame / 60.0 + g_subframe * 1e-6;
  return (double)SDL_GetPerformanceCounter() / (double)SDL_GetPerformanceFrequency();
}

void plat_sleep(double s) {
  if (g_headless) { g_subframe++; return; } /* run scripted sessions as fast as possible */
  if (s > 0) SDL_Delay((Uint32)(s * 1000.0));
}

const char *plat_base_dir(void) { return g_base; }
const char *plat_save_dir(void) { return g_save; }
const char *plat_self_path(void) { return g_self; }
#if defined(__vita__)
const char *plat_os_name(void) { return "Vita"; }
#elif defined(__PSL1GHT__)
const char *plat_os_name(void) { return "PS3"; }
#elif defined(__ANDROID__)
const char *plat_os_name(void) { return "Android"; }
#else
/* desktop test build: LOVEPSP_OS=Android|Vita pretends to be that console */
const char *plat_os_name(void) { const char *o = getenv("LOVEPSP_OS"); return o && *o ? o : "PSP"; }
#endif

static void sdl_audio(void *ud, Uint8 *stream, int len) {
  (void)ud;
  SDL_LockMutex(g_amutex);
  g_acb((int16_t *)stream, len / 4);
  SDL_UnlockMutex(g_amutex);
}

int plat_audio_start(plat_audio_cb cb) {
  SDL_AudioSpec want, have;
  g_acb = cb;
  g_amutex = SDL_CreateMutex();
  if (g_headless) return 0;
  SDL_zero(want);
  want.freq = PLAT_AUDIO_RATE; want.format = AUDIO_S16SYS; want.channels = 2;
  want.samples = 1024; want.callback = sdl_audio;
  g_adev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
  if (!g_adev) return -1;
  SDL_PauseAudioDevice(g_adev, 0);
  return 0;
}

void plat_audio_lock(void) { if (g_amutex) SDL_LockMutex(g_amutex); }
void plat_audio_unlock(void) { if (g_amutex) SDL_UnlockMutex(g_amutex); }

void plat_power(int *percent, int *charging, int *seconds) {
  *percent = -1; *charging = 0; *seconds = -1;
}

long plat_free_memory(void) { return -1; }

void plat_debug(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
#ifdef __ANDROID__
  __android_log_vprint(ANDROID_LOG_INFO, "lovepsp", fmt, ap);
#else
  vfprintf(stderr, fmt, ap);
#endif
  va_end(ap);
}

#ifdef __ANDROID__
/* called from MainActivity / SecondScreen (Java) */
JNIEXPORT void JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeSetLayout(JNIEnv *env, jclass cls, jint mode) {
  (void)env; (void)cls;
  plat_set_layout(mode);
}
JNIEXPORT void JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeSetTouch(JNIEnv *env, jclass cls, jint on) {
  (void)env; (void)cls;
  touch_set_enabled(on);
}
JNIEXPORT jboolean JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeGetBottomScreen(JNIEnv *env, jclass cls, jintArray arr, jint w, jint h) {
  jint *p;
  int ok;
  (void)cls;
  if (!arr || (*env)->GetArrayLength(env, arr) < w * h) return JNI_FALSE;
  p = (*env)->GetIntArrayElements(env, arr, NULL);
  if (!p) return JNI_FALSE;
  ok = plat_bottom_half((uint32_t *)p, w, h);
  (*env)->ReleaseIntArrayElements(env, arr, p, 0);
  return ok ? JNI_TRUE : JNI_FALSE;
}
JNIEXPORT void JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeSetHinge(JNIEnv *env, jclass cls, jfloat degrees) {
  (void)env; (void)cls;
  g_hinge = degrees;
}
JNIEXPORT jint JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeBottomHeight(JNIEnv *env, jclass cls) {
  (void)env; (void)cls;
  return g_bottom;
}
JNIEXPORT jint JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeTopHeight(JNIEnv *env, jclass cls) {
  (void)env; (void)cls;
  return g_top;
}
JNIEXPORT void JNICALL Java_com_nahalewski_g1rports_MainActivity_nativeTouch(JNIEnv *env, jclass cls, jint id, jint down, jfloat lx, jfloat ly) {
  (void)env; (void)cls;
  touch_finger(id, down, lx, ly);
}
#endif
#endif
