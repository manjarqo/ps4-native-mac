// Host test of the DLC scan of libSceAppContent: <app>/addcont, then the directory named by
// PS4_ADDCONT_DIR (the game manager's games/<TITLE_ID>/addcont for a game used in place). A label
// found twice is listed once, from the first scan, and sceAppContentAddcontMount mounts the
// directory the scan found, so the DLC's files resolve through /addcont<n>.
//
// Usage: app_content_addcont_test <scratch dir> [noenv]. With "noenv" PS4_ADDCONT_DIR is unset
// and only <app>/addcont is found (the scan runs once per process, so this is its own run).
#include "ps4_app_content.h"
#include "ps4_vfs.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int g_failures;
#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      printf("FAIL line %d: %s  ", __LINE__, #cond);                           \
      printf(__VA_ARGS__);                                                     \
      printf("\n");                                                            \
      g_failures++;                                                            \
    }                                                                          \
  } while (0)

static void put_le(uint8_t *p, uint32_t v, int n) {
  for (int i = 0; i < n; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void make_dirs(const char *path) {
  char tmp[1024];
  snprintf(tmp, sizeof(tmp), "%s", path);
  for (char *p = tmp + 1; *p; p++) {
    if (*p == '/') {
      *p = '\0';
      mkdir(tmp, 0755);
      *p = '/';
    }
  }
  mkdir(tmp, 0755);
}

static void write_file(const char *path, const void *data, size_t n) {
  FILE *f = fopen(path, "wb");
  if (!f || fwrite(data, 1, n, f) != n) {
    perror(path);
    exit(1);
  }
  fclose(f);
}

// Writes <dir>/sce_sys/param.sfo with the string entries CATEGORY and CONTENT_ID (and TITLE_ID
// when title_id is not NULL), in key order as the PS4 tools write them.
static void write_sfo(const char *dir, const char *category, const char *content_id, const char *title_id) {
  const char *keys[3] = {"CATEGORY", "CONTENT_ID", "TITLE_ID"};
  const char *vals[3] = {category, content_id, title_id};
  const uint32_t count = title_id ? 3 : 2;
  uint8_t b[512] = {0x00, 'P', 'S', 'F'};
  const uint32_t key_table = 20 + 16 * count;
  uint32_t key_len = 0;
  for (uint32_t i = 0; i < count; i++) key_len += (uint32_t)strlen(keys[i]) + 1;
  const uint32_t data_table = (key_table + key_len + 3) & ~3u;
  put_le(b + 4, 0x101, 4);
  put_le(b + 8, key_table, 4);
  put_le(b + 12, data_table, 4);
  put_le(b + 16, count, 4);
  uint32_t koff = 0, doff = 0;
  for (uint32_t i = 0; i < count; i++) {
    uint8_t *e = b + 20 + 16 * i;
    const uint32_t len = (uint32_t)strlen(vals[i]) + 1, max = (len + 3) & ~3u;
    put_le(e, koff, 2);
    put_le(e + 2, 0x0204, 2); // UTF-8 string
    put_le(e + 4, len, 4);
    put_le(e + 8, max, 4);
    put_le(e + 12, doff, 4);
    memcpy(b + key_table + koff, keys[i], strlen(keys[i]) + 1);
    memcpy(b + data_table + doff, vals[i], len);
    koff += (uint32_t)strlen(keys[i]) + 1;
    doff += max;
  }
  char p[1024];
  snprintf(p, sizeof(p), "%s/sce_sys", dir);
  make_dirs(p);
  snprintf(p, sizeof(p), "%s/sce_sys/param.sfo", dir);
  write_file(p, b, data_table + doff);
}

// A DLC directory <root>/<label> of CATEGORY cat with one file, "which.txt", holding which.
static void make_dlc(const char *root, const char *label, const char *cat, const char *which) {
  char dir[1024], cid[128], p[1100];
  snprintf(dir, sizeof(dir), "%s/%s", root, label);
  snprintf(cid, sizeof(cid), "UP9000-CUSA04529_00-%s", label);
  write_sfo(dir, cat, cid, NULL);
  snprintf(p, sizeof(p), "%s/which.txt", dir);
  write_file(p, which, strlen(which));
}

// The contents of the guest file path, through the VFS; "" when it does not resolve or read.
static const char *read_guest(const char *path) {
  static char buf[64];
  char host[1024];
  buf[0] = '\0';
  if (ps4_vfs_resolve(path, host, sizeof(host)) != 0) return buf;
  FILE *f = fopen(host, "rb");
  if (!f) return buf;
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  buf[n] = '\0';
  fclose(f);
  return buf;
}

static OrbisNpUnifiedEntitlementLabel label_of(const char *s) {
  OrbisNpUnifiedEntitlementLabel l;
  memset(&l, 0, sizeof(l));
  strncpy(l.data, s, sizeof(l.data) - 1);
  return l;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <scratch dir> [noenv]\n", argv[0]);
    return 2;
  }
  const int noenv = argc > 2 && strcmp(argv[2], "noenv") == 0;
  char base[1024], app[1100], app_dlc[1200], env_dlc[1100], data[1100], p[1300];
  snprintf(base, sizeof(base), "%s/%s", argv[1], noenv ? "noenv" : "env");
  snprintf(app, sizeof(app), "%s/app", base);
  snprintf(app_dlc, sizeof(app_dlc), "%s/addcont", app);
  snprintf(env_dlc, sizeof(env_dlc), "%s/games/CUSA04529/addcont", base);
  snprintf(data, sizeof(data), "%s/data", base);

  write_sfo(app, "gd", "UP9000-CUSA04529_00-GAME000000000000", "CUSA04529");
  snprintf(p, sizeof(p), "%s/eboot.bin", app);
  write_file(p, "ELF", 3);
  make_dlc(app_dlc, "EXTRAPACK", "ac", "app");
  make_dlc(env_dlc, "EXTRAPACK", "ac", "env"); // the same label again: skipped
  make_dlc(env_dlc, "SECONDPACK", "ac", "second");
  make_dlc(env_dlc, "NOTADLC", "gd", "game"); // not CATEGORY ac: skipped
  snprintf(p, sizeof(p), "%s/empty", env_dlc); // no param.sfo: skipped
  make_dirs(p);

  setenv("PS4RECOMP_DATA_DIR", data, 1); // /temp0 and /download0 in the scratch dir
  setenv("PS4_APP_DIR", app, 1);
  if (noenv) {
    unsetenv("PS4_ADDCONT_DIR");
  } else {
    setenv("PS4_ADDCONT_DIR", env_dlc, 1);
  }
  ps4_vfs_init(app);

  OrbisAppContentBootParam boot;
  CHECK(sceAppContentInitialize(NULL, &boot) == 0, "initialize");

  uint32_t hit = 0;
  CHECK(sceAppContentGetAddcontInfoList(0, NULL, 0, &hit) == 0, "count");
  const uint32_t want = noenv ? 1 : 2;
  CHECK(hit == want, "%u DLC found, want %u", hit, want);
  OrbisAppContentAddcontInfo list[4];
  memset(list, 0, sizeof(list));
  CHECK(sceAppContentGetAddcontInfoList(0, list, 4, &hit) == 0 && hit == want, "list: %u", hit);
  CHECK(strcmp(list[0].entitlement_label.data, "EXTRAPACK") == 0, "first label %s", list[0].entitlement_label.data);
  CHECK(list[0].status == ORBIS_APP_CONTENT_ADDCONT_DOWNLOAD_STATUS_INSTALLED, "status %u", list[0].status);

  // The first scan's EXTRAPACK wins: its mount reads <app>/addcont/EXTRAPACK.
  OrbisNpUnifiedEntitlementLabel extra = label_of("EXTRAPACK"), second = label_of("SECONDPACK");
  OrbisAppContentMountPoint mp;
  memset(&mp, 0, sizeof(mp));
  CHECK(sceAppContentAddcontMount(0, &extra, &mp) == 0, "mount EXTRAPACK");
  snprintf(p, sizeof(p), "%s/which.txt", mp.data);
  CHECK(strcmp(read_guest(p), "app") == 0, "%s = \"%s\", want app", p, read_guest(p));

  OrbisAppContentAddcontInfo info;
  memset(&mp, 0, sizeof(mp));
  if (noenv) {
    CHECK(sceAppContentGetAddcontInfo(0, &second, &info) == (int32_t)ORBIS_APP_CONTENT_ERROR_DRM_NO_ENTITLEMENT,
          "SECONDPACK found without PS4_ADDCONT_DIR");
    CHECK(sceAppContentAddcontMount(0, &second, &mp) == (int32_t)ORBIS_APP_CONTENT_ERROR_NOT_FOUND, "mount SECONDPACK");
  } else {
    CHECK(strcmp(list[1].entitlement_label.data, "SECONDPACK") == 0, "second label %s", list[1].entitlement_label.data);
    CHECK(sceAppContentGetAddcontInfo(0, &second, &info) == 0 && strcmp(info.entitlement_label.data, "SECONDPACK") == 0,
          "info SECONDPACK");
    CHECK(sceAppContentAddcontMount(0, &second, &mp) == 0, "mount SECONDPACK");
    snprintf(p, sizeof(p), "%s/which.txt", mp.data);
    CHECK(strcmp(read_guest(p), "second") == 0, "%s = \"%s\", want second", p, read_guest(p));
    snprintf(p, sizeof(p), "%s/sce_sys/param.sfo", mp.data);
    char host[1024];
    struct stat st;
    CHECK(ps4_vfs_resolve(p, host, sizeof(host)) == 0 && stat(host, &st) == 0 && st.st_size > 0, "%s is missing", p);
    // The mount by entitlement id resolves to the same directory.
    memset(&mp, 0, sizeof(mp));
    CHECK(sceAppContentAddcontMountByEntitlementId("SECONDPACK", &mp) == 0, "mount by id");
    snprintf(p, sizeof(p), "%s/which.txt", mp.data);
    CHECK(strcmp(read_guest(p), "second") == 0, "%s = \"%s\", want second", p, read_guest(p));
  }

  ps4_vfs_destroy();
  if (g_failures) {
    printf("app_content_addcont_test (%s): FAIL (%d)\n", noenv ? "noenv" : "env", g_failures);
    return 1;
  }
  printf("app_content_addcont_test (%s): PASS\n", noenv ? "noenv" : "env");
  return 0;
}
