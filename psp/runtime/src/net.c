/* HTTP download for the mod updater.  Desktop: the curl command line (the
 * build machine's proxy settings come along).  Vita: sceHttp/sceSsl, the
 * console's own TLS stack.  PSP and PS3: no network support in this port. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "plat.h"

#if defined(__vita__)
#include <psp2/sysmodule.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/net/http.h>
#include <psp2/libssl.h>

static int g_net_ready;
static void *g_net_mem;

static int vita_net_init(char *err, size_t errn) {
  SceNetInitParam p;
  int r;
  if (g_net_ready) return 0;
  sceSysmoduleLoadModule(SCE_SYSMODULE_NET);
  sceSysmoduleLoadModule(SCE_SYSMODULE_HTTP);
  sceSysmoduleLoadModule(SCE_SYSMODULE_SSL);
  g_net_mem = malloc(1024 * 1024);
  p.memory = g_net_mem; p.size = 1024 * 1024; p.flags = 0;
  r = sceNetInit(&p);
  if (r < 0 && r != (int)0x80410101 /* already initialised */) { snprintf(err, errn, "sceNetInit %08x", r); return -1; }
  sceNetCtlInit();
  r = sceHttpInit(1024 * 1024);
  if (r < 0 && r != (int)0x80431020) { snprintf(err, errn, "sceHttpInit %08x", r); return -1; }
  r = sceSslInit(300 * 1024);
  if (r < 0 && r != (int)0x80435020) { snprintf(err, errn, "sceSslInit %08x", r); return -1; }
  g_net_ready = 1;
  return 0;
}

int plat_has_network(void) { return 1; }

int plat_http_get(const char *url, const char *auth, const char *out, char *err, size_t errn) {
  int tmpl = -1, conn = -1, req = -1, r, status = 0;
  FILE *fp = NULL;
  static char buf[64 * 1024];
  int result = -1;
  if (vita_net_init(err, errn)) return -1;
  tmpl = sceHttpCreateTemplate("gen1recomp-lovepsp/1.0", SCE_HTTP_VERSION_1_1, 1);
  if (tmpl < 0) { snprintf(err, errn, "template %08x", tmpl); goto done; }
  sceHttpSetAutoRedirect(tmpl, 1);
  conn = sceHttpCreateConnectionWithURL(tmpl, url, 0);
  if (conn < 0) { snprintf(err, errn, "connection %08x", conn); goto done; }
  req = sceHttpCreateRequestWithURL(conn, SCE_HTTP_METHOD_GET, url, 0);
  if (req < 0) { snprintf(err, errn, "request %08x", req); goto done; }
  if (auth && *auth) sceHttpAddRequestHeader(req, "Authorization", auth, SCE_HTTP_HEADER_OVERWRITE);
  sceHttpAddRequestHeader(req, "Accept", "*/*", SCE_HTTP_HEADER_OVERWRITE);
  r = sceHttpSendRequest(req, NULL, 0);
  if (r < 0) { snprintf(err, errn, "send %08x", r); goto done; }
  sceHttpGetStatusCode(req, &status);
  if (status < 200 || status >= 300) { snprintf(err, errn, "HTTP %d", status); goto done; }
  fp = fopen(out, "wb");
  if (!fp) { snprintf(err, errn, "cannot write %s", out); goto done; }
  for (;;) {
    r = sceHttpReadData(req, buf, sizeof buf);
    if (r < 0) { snprintf(err, errn, "read %08x", r); goto done; }
    if (r == 0) break;
    if (fwrite(buf, 1, (size_t)r, fp) != (size_t)r) { snprintf(err, errn, "write failed"); goto done; }
  }
  result = 0;
done:
  if (fp) fclose(fp);
  if (req >= 0) sceHttpDeleteRequest(req);
  if (conn >= 0) sceHttpDeleteConnection(conn);
  if (tmpl >= 0) sceHttpDeleteTemplate(tmpl);
  return result;
}

#elif defined(__PSP__) || defined(__PSL1GHT__)
int plat_has_network(void) { return 0; }
int plat_http_get(const char *url, const char *auth, const char *out, char *err, size_t errn) {
  (void)url; (void)auth; (void)out;
  snprintf(err, errn, "no network support on this console");
  return -1;
}
#else
#include <sys/wait.h>
#include <unistd.h>
int plat_has_network(void) { return 1; }
int plat_http_get(const char *url, const char *auth, const char *out, char *err, size_t errn) {
  pid_t pid = fork();
  int status = 0;
  if (pid < 0) { snprintf(err, errn, "fork failed"); return -1; }
  if (pid == 0) {
    char header[600];
    const char *argv[16];
    int n = 0;
    argv[n++] = "curl"; argv[n++] = "-sSL"; argv[n++] = "--fail"; argv[n++] = "-m"; argv[n++] = "180";
    argv[n++] = "-A"; argv[n++] = "gen1recomp-lovepsp/1.0";
    if (auth && *auth) { snprintf(header, sizeof header, "Authorization: %s", auth); argv[n++] = "-H"; argv[n++] = header; }
    argv[n++] = "-o"; argv[n++] = out; argv[n++] = url; argv[n] = NULL;
    execvp("curl", (char *const *)argv);
    _exit(127);
  }
  waitpid(pid, &status, 0);
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
  snprintf(err, errn, "curl exit %d", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
  return -1;
}
#endif
