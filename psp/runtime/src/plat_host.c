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

int lp_write_png(const char *path, const uint32_t *px, int w, int h);

static SDL_Window *g_win;
static SDL_GameController *g_pad;
static SDL_Joystick *g_joy; /* raw pad when no controller mapping exists (PS3) */
static SDL_Renderer *g_ren;
static SDL_Texture *g_tex;
static uint32_t g_screen[PLAT_SCREEN_W * PLAT_SCREEN_H];
static char g_base[1024], g_save[1100], g_self[1100];
static int g_headless, g_quit;
static long g_frame, g_max_frames = -1;
static long g_subframe; /* headless: ticks within a frame so time never stalls */
static SDL_AudioDeviceID g_adev;
static plat_audio_cb g_acb;
static SDL_mutex *g_amutex;

typedef struct { long frame; char path[512]; } Shot;
static Shot g_shots[64];
static int g_nshots;
typedef struct { long from, len; uint32_t btn; float tx, ty; } Hold; /* tx >= 0: a synthetic finger */
static Hold g_holds[256];
static int g_nholds;
static long g_pad_frame, g_touch_frame; /* last frame each source was used, for the overlay */

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
        if (sscanf(name, "touch@%f@%f", &tx, &ty) == 2) {
          /* touch@X@Y: hold a finger at logical screen coordinates */
          g_holds[g_nholds].btn = 0;
          g_holds[g_nholds].tx = tx / PLAT_SCREEN_W; g_holds[g_nholds].ty = ty / PLAT_SCREEN_H;
        } else g_holds[g_nholds].btn = btn_from_name(name);
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
#ifdef __vita__
  touch_set_enabled(1);
#else
  if (getenv("LOVEPSP_TOUCH")) touch_set_enabled(atoi(getenv("LOVEPSP_TOUCH")));
#endif
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
#elif defined(__PSL1GHT__)
  snprintf(g_self, sizeof g_self, "%sgame.pak", g_base);
#else
  if (getenv("LOVEPSP_ARCHIVE")) strncpy(g_self, getenv("LOVEPSP_ARCHIVE"), sizeof g_self - 1);
  else snprintf(g_self, sizeof g_self, "%sEBOOT.PBP", g_base);
#endif

  if (SDL_Init((g_headless ? 0 : SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER) | SDL_INIT_TIMER) != 0) {
    fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
    return -1;
  }
  if (!g_headless) {
    g_win = SDL_CreateWindow("lovepsp", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
#if defined(__PSL1GHT__)
                             1280, 720, SDL_WINDOW_FULLSCREEN);
#elif defined(__vita__)
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
int plat_touch_get(int i, float *x, float *y) { return touch_get(i, x, y); }

void plat_present(const uint32_t *px, int w, int h, int mode, int smooth) {
  int i;
  if (touch_enabled()) {
    /* a game (small source) sits between the control bars; the launcher
     * fills the screen and takes taps directly through lovepsp.touches() */
    mode = 4;
    touch_set_visible(w * 2 <= PLAT_SCREEN_W);
  }
  plat_blit_scaled(px, w, h, g_screen, PLAT_SCREEN_W, PLAT_SCREEN_W, PLAT_SCREEN_H, mode, smooth);
  if (touch_visible()) touch_draw(g_screen, PLAT_SCREEN_W, PLAT_SCREEN_H, g_pad_frame > g_touch_frame);
  g_frame++;
  for (i = 0; i < g_nshots; i++)
    if (g_shots[i].frame == g_frame) lp_write_png(g_shots[i].path, g_screen, PLAT_SCREEN_W, PLAT_SCREEN_H);
  if (g_max_frames >= 0 && g_frame >= g_max_frames) g_quit = 1;
  if (g_headless) return;
  SDL_UpdateTexture(g_tex, NULL, g_screen, PLAT_SCREEN_W * 4);
  SDL_RenderClear(g_ren);
  SDL_RenderCopy(g_ren, g_tex, NULL, NULL);
  SDL_RenderPresent(g_ren);
}

void plat_vsync(void) {
  if (g_headless) return;
  SDL_Delay(1);
}

void plat_poll(PlatInput *in) {
  SDL_Event e;
  uint32_t b = 0;
  int i;
  if (!g_headless) {
    const Uint8 *k;
    while (SDL_PollEvent(&e)) {
      if (e.type == SDL_QUIT) g_quit = 1;
      else if (e.type == SDL_FINGERDOWN || e.type == SDL_FINGERUP || e.type == SDL_FINGERMOTION) {
        /* front panel only: the Vita reports the rear pad as a second device */
        if (e.tfinger.touchId == SDL_GetTouchDevice(0))
          touch_finger((long)e.tfinger.fingerId, e.type != SDL_FINGERUP, e.tfinger.x, e.tfinger.y);
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
        SDL_RenderWindowToLogical(g_ren, mx, my, &lx, &ly);
        touch_finger(-1, down, lx / PLAT_SCREEN_W, ly / PLAT_SCREEN_H);
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
  for (i = 0; i < g_nholds; i++) {
    int on = g_frame >= g_holds[i].from && g_frame < g_holds[i].from + g_holds[i].len;
    if (g_holds[i].tx >= 0) touch_finger(1000 + i, on, g_holds[i].tx, g_holds[i].ty);
    else if (on) b |= g_holds[i].btn;
  }
  {
    uint32_t t = touch_buttons();
    if (t) g_touch_frame = g_frame;
    b |= t;
  }
  in->buttons = b;
  if (!g_pad && !g_joy) in->ax = in->ay = 0;
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
#else
const char *plat_os_name(void) { return "PSP"; }
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
  vfprintf(stderr, fmt, ap);
  va_end(ap);
}
#endif
