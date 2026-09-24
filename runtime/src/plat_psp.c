/* PSP platform backend (pspsdk). */
#ifdef __PSP__
#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspctrl.h>
#include <psppower.h>
#include <pspaudio.h>
#include <pspge.h>
#include <psputils.h>
#include <malloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "plat.h"
#include "plat_common.h"

PSP_MODULE_INFO("gen1recomp", PSP_MODULE_USER, 0, 1);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER | THREAD_ATTR_VFPU);
/* everything but 1 MiB for thread stacks and the audio thread; on a
 * PSP-2000 or later PSP_LARGE_MEMORY in the Makefile raises this to ~52 MiB */
PSP_HEAP_SIZE_KB(-1024);
PSP_MAIN_THREAD_STACK_SIZE_KB(512);

#define FB_STRIDE 512

static char g_base[256] = "ms0:/PSP/GAME/gen1recomp/";
static char g_save[288];
static char g_self[288];
static volatile int g_exit_requested = 0;
static uint32_t *g_fb[2];
static int g_back = 1;
static FILE *g_log;

static int exit_cb(int a, int b, void *c) {
  (void)a; (void)b; (void)c;
  g_exit_requested = 1;
  return 0;
}

static int callback_thread(SceSize args, void *argp) {
  (void)args; (void)argp;
  int cbid = sceKernelCreateCallback("Exit Callback", exit_cb, NULL);
  sceKernelRegisterExitCallback(cbid);
  sceKernelSleepThreadCB();
  return 0;
}

int plat_init(int argc, char **argv) {
  int thid;
  if (argc > 0 && argv[0]) {
    char *slash;
    strncpy(g_self, argv[0], sizeof g_self - 1);
    strncpy(g_base, argv[0], sizeof g_base - 1);
    slash = strrchr(g_base, '/');
    if (slash) slash[1] = 0;
  } else {
    snprintf(g_self, sizeof g_self, "%sEBOOT.PBP", g_base);
  }
  snprintf(g_save, sizeof g_save, "%ssave/", g_base);
  sceIoMkdir(g_save, 0777);

  thid = sceKernelCreateThread("update_thread", callback_thread, 0x11, 0xFA0, 0, 0);
  if (thid >= 0) sceKernelStartThread(thid, 0, 0);

  scePowerSetClockFrequency(333, 333, 166);

  g_fb[0] = (uint32_t *)(0x04000000); /* cached VRAM */
  g_fb[1] = g_fb[0] + FB_STRIDE * 272;
  memset(g_fb[0], 0, FB_STRIDE * 272 * 4 * 2);
  sceKernelDcacheWritebackAll();
  sceDisplaySetMode(0, 480, 272);
  sceDisplaySetFrameBuf((void *)g_fb[0], FB_STRIDE, PSP_DISPLAY_PIXEL_FORMAT_8888,
                        PSP_DISPLAY_SETBUF_NEXTFRAME);

  sceCtrlSetSamplingCycle(0);
  sceCtrlSetSamplingMode(PSP_CTRL_MODE_ANALOG);
  return 0;
}

void plat_shutdown(void) {
  if (g_log) fclose(g_log);
  sceKernelExitGame();
}

static SceInt64 g_last_present;

void plat_present(const uint32_t *px, int w, int h, int mode, int smooth) {
  uint32_t *fb = g_fb[g_back];
  SceInt64 now;
  plat_blit_scaled(px, w, h, fb, FB_STRIDE, 480, 272, mode, smooth);
  sceKernelDcacheWritebackRange(fb, FB_STRIDE * 272 * 4);
  /* a fast frame waits for vblank (60 Hz cap); a slow one flips at the next
   * vblank without waiting, so it does not lose up to a whole extra vblank */
  now = sceKernelGetSystemTimeWide();
  if (now - g_last_present < 15000) sceDisplayWaitVblankStart();
  sceDisplaySetFrameBuf((void *)fb, FB_STRIDE, PSP_DISPLAY_PIXEL_FORMAT_8888,
                        PSP_DISPLAY_SETBUF_NEXTFRAME);
  g_last_present = sceKernelGetSystemTimeWide();
  g_back ^= 1;
}

void plat_vsync(void) { sceDisplayWaitVblankStart(); }

void plat_poll(PlatInput *in) {
  SceCtrlData pad;
  uint32_t b = 0;
  memset(&pad, 0, sizeof pad);
  sceCtrlPeekBufferPositive(&pad, 1);
  if (pad.Buttons & PSP_CTRL_UP) b |= PB_UP;
  if (pad.Buttons & PSP_CTRL_DOWN) b |= PB_DOWN;
  if (pad.Buttons & PSP_CTRL_LEFT) b |= PB_LEFT;
  if (pad.Buttons & PSP_CTRL_RIGHT) b |= PB_RIGHT;
  if (pad.Buttons & PSP_CTRL_CROSS) b |= PB_CROSS;
  if (pad.Buttons & PSP_CTRL_CIRCLE) b |= PB_CIRCLE;
  if (pad.Buttons & PSP_CTRL_SQUARE) b |= PB_SQUARE;
  if (pad.Buttons & PSP_CTRL_TRIANGLE) b |= PB_TRIANGLE;
  if (pad.Buttons & PSP_CTRL_LTRIGGER) b |= PB_LTRIGGER;
  if (pad.Buttons & PSP_CTRL_RTRIGGER) b |= PB_RTRIGGER;
  if (pad.Buttons & PSP_CTRL_START) b |= PB_START;
  if (pad.Buttons & PSP_CTRL_SELECT) b |= PB_SELECT;
  in->buttons = b;
  in->ax = ((int)pad.Lx - 128) / 127.0f;
  in->ay = ((int)pad.Ly - 128) / 127.0f;
  if (in->ax > 1) in->ax = 1;
  if (in->ay > 1) in->ay = 1;
  in->quit = g_exit_requested;
}

double plat_time(void) { return sceKernelGetSystemTimeWide() / 1000000.0; }

void plat_sleep(double s) {
  if (s <= 0) { sceKernelDelayThread(0); return; }
  sceKernelDelayThread((SceUInt)(s * 1000000.0));
}

const char *plat_base_dir(void) { return g_base; }
const char *plat_save_dir(void) { return g_save; }
const char *plat_self_path(void) { return g_self; }
const char *plat_os_name(void) { return "PSP"; }
int plat_touch(int on) { (void)on; return 0; }
int plat_touch_pad(int on) { (void)on; return 0; }
void plat_inject(uint32_t buttons) { (void)buttons; }
void plat_set_game_rect(int x, int y, int w, int h) { (void)x; (void)y; (void)w; (void)h; }
int plat_touch_get(int i, float *x, float *y) { (void)i; (void)x; (void)y; return 0; }
void plat_set_overlay(const uint32_t *px, int w, int h) { (void)px; (void)w; (void)h; }
void plat_set_bars(int left, int right) { (void)left; (void)right; }
void plat_set_layout(int ds) { (void)ds; }
void plat_set_split(int top, int bottom) { (void)top; (void)bottom; }
void plat_get_split(int *top, int *bottom) { *top = PLAT_SCREEN_H; *bottom = 0; }
void plat_set_hinge(float d) { (void)d; }
int plat_open_url(const char *url) { (void)url; return 0; }
float plat_hinge(void) { return -1; }
int plat_get_layout(void) { return 0; }
void plat_screen_size(int *w, int *h) { *w = PLAT_SCREEN_W; *h = PLAT_SCREEN_H; }
void plat_output_size(int *w, int *h) { *w = PLAT_SCREEN_W; *h = PLAT_SCREEN_H; }

/* ------------------------------------------------------------ audio */
#define AUDIO_FRAMES 1024
static plat_audio_cb g_audio_cb;
static SceUID g_audio_sema = -1;
static int16_t g_abuf[2][AUDIO_FRAMES * 2] __attribute__((aligned(64)));

static int audio_thread(SceSize args, void *argp) {
  int ch, cur = 0;
  (void)args; (void)argp;
  ch = sceAudioChReserve(PSP_AUDIO_NEXT_CHANNEL, AUDIO_FRAMES, PSP_AUDIO_FORMAT_STEREO);
  if (ch < 0) return 0;
  while (!g_exit_requested) {
    plat_audio_lock();
    g_audio_cb(g_abuf[cur], AUDIO_FRAMES);
    plat_audio_unlock();
    sceAudioOutputPannedBlocking(ch, PSP_AUDIO_VOLUME_MAX, PSP_AUDIO_VOLUME_MAX, g_abuf[cur]);
    cur ^= 1;
  }
  sceAudioChRelease(ch);
  return 0;
}

int plat_audio_start(plat_audio_cb cb) {
  int thid;
  g_audio_cb = cb;
  g_audio_sema = sceKernelCreateSema("audio", 0, 1, 1, 0);
  /* priority higher (lower number) than the main thread's 0x20 */
  thid = sceKernelCreateThread("audio_thread", audio_thread, 0x12, 0x10000,
                               PSP_THREAD_ATTR_USER, 0);
  if (thid < 0) return -1;
  sceKernelStartThread(thid, 0, 0);
  return 0;
}

void plat_audio_lock(void) { if (g_audio_sema >= 0) sceKernelWaitSema(g_audio_sema, 1, 0); }
void plat_audio_unlock(void) { if (g_audio_sema >= 0) sceKernelSignalSema(g_audio_sema, 1); }

void plat_power(int *percent, int *charging, int *seconds) {
  int life;
  *percent = scePowerIsBatteryExist() ? scePowerGetBatteryLifePercent() : -1;
  *charging = scePowerIsBatteryCharging();
  life = scePowerGetBatteryLifeTime();
  *seconds = life >= 0 ? life * 60 : -1;
}

long plat_free_memory(void) {
  struct mallinfo mi = mallinfo();
  /* arena is what malloc has claimed from the heap so far; the fixed-size
   * newlib heap is reported by sceKernelMaxFreeMemSize once claimed. */
  return (long)sceKernelMaxFreeMemSize() + (long)mi.fordblks;
}

void plat_debug(const char *fmt, ...) {
  va_list ap;
  if (!g_log) {
    char p[300];
    snprintf(p, sizeof p, "%slovepsp.log", g_base);
    g_log = fopen(p, "w");
    if (!g_log) return;
  }
  va_start(ap, fmt);
  vfprintf(g_log, fmt, ap);
  va_end(ap);
  fflush(g_log);
}
#endif
