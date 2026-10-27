// Host test: /app0 is read-only, as on the console (the application package is a read-only PFS
// mount). Opening a file there for writing, creating or truncating it, and unlink, mkdir, rmdir,
// rename, truncate, chmod and utimes fail with EROFS and leave the host directory untouched; the
// errors that come before the read-only check (ENOENT, EEXIST) stay. A writable mount (/temp0)
// is not affected. Everything is called through the guest ABI.
#define RUNTIME_STUBS_HAVE_VFS
#include "runtime_stubs.h"
#include "ps4_syscalls.h"
#include "ps4_vfs.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// GPU hooks of ps4_direct_mem.c (linked for SYS_mprotect in ps4_syscalls.c); no GPU here.
void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size) { (void)addr; (void)size; }
void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) { (void)addr; (void)size; }

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

#define MEM_SIZE 0x10000
#define STR_A 0x2000 // guest address of the first path argument
#define STR_B 0x2400 // guest address of the second path argument
#define FREEBSD_O_WRONLY 0x1
#define FREEBSD_O_RDWR 0x2
#define FREEBSD_O_CREAT 0x200
#define FREEBSD_O_TRUNC 0x400
#define FREEBSD_O_EXCL 0x800
#define FREEBSD_EROFS 30
#define FREEBSD_ENOENT 2
#define FREEBSD_EEXIST 17
static uint8_t g_mem[MEM_SIZE];
static GuestContext g_ctx;
static char g_root[512];

static int guest_errno(void) { return *(int *)(g_mem + g_ctx.fs_base + 0x100); }

static int64_t call4(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = a1;
  g_ctx.rsi = a2;
  g_ctx.rdx = a3;
  g_ctx.rcx = a4;
  *(int *)(g_mem + g_ctx.fs_base + 0x100) = 0;
  shim(&g_ctx);
  if (g_ctx.rsp != 0x1008) {
    printf("FAIL: shim did not pop its return address\n");
    g_failures++;
  }
  return (int64_t)g_ctx.rax;
}

static int64_t call(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  return call4(shim, a1, a2, a3, 0);
}

static uint64_t guest_str(uint64_t at, const char *s) {
  strcpy((char *)g_mem + at, s);
  return at;
}

static const char *host(const char *rel) {
  static char buf[1024];
  snprintf(buf, sizeof(buf), "%s/%s", g_root, rel);
  return buf;
}

static int host_exists(const char *rel) {
  struct stat st;
  return lstat(host(rel), &st) == 0;
}

static void write_host(const char *rel, const char *content) {
  FILE *f = fopen(host(rel), "w");
  fputs(content, f);
  fclose(f);
}

static int host_content_is(const char *rel, const char *content) {
  char buf[64] = {0};
  FILE *f = fopen(host(rel), "r");
  if (!f) return 0;
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  return n == strlen(content) && memcmp(buf, content, n) == 0;
}

// open(path, flags) on /app0 must fail with EROFS and leave the host side as it was.
static void expect_open_erofs(const char *guest_path, int flags, const char *what) {
  int64_t fd = call(shim_open, guest_str(STR_A, guest_path), (uint64_t)flags, 0644);
  CHECK((int32_t)fd == -1, "%s: open returned %lld", what, (long long)fd);
  CHECK(guest_errno() == FREEBSD_EROFS, "%s: errno %d", what, guest_errno());
  if ((int32_t)fd >= 0) close((int)fd);
}

static void test_open(void) {
  // The inFAMOUS probe: fopen("/app0/delete_me.snt", "w") is open(O_WRONLY|O_CREAT|O_TRUNC).
  expect_open_erofs("/app0/delete_me.snt", FREEBSD_O_WRONLY | FREEBSD_O_CREAT | FREEBSD_O_TRUNC, "create new");
  CHECK(!host_exists("delete_me.snt"), "no file was created in the application directory");
  // The same through syscall(SYS_open, ...).
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = 5;
  g_ctx.rsi = guest_str(STR_A, "/app0/delete_me.snt");
  g_ctx.rdx = FREEBSD_O_WRONLY | FREEBSD_O_CREAT | FREEBSD_O_TRUNC;
  g_ctx.rcx = 0644;
  *(int *)(g_mem + g_ctx.fs_base + 0x100) = 0;
  shim_syscall(&g_ctx);
  CHECK((int32_t)g_ctx.rax == -1 && guest_errno() == FREEBSD_EROFS, "SYS_open create: rax %lld errno %d",
        (long long)g_ctx.rax, guest_errno());
  CHECK(!host_exists("delete_me.snt"), "SYS_open created no file");

  // An existing file: write access or truncation fails and the content stays.
  expect_open_erofs("/app0/keep.bin", FREEBSD_O_WRONLY, "write existing");
  expect_open_erofs("/app0/keep.bin", FREEBSD_O_RDWR, "read-write existing");
  expect_open_erofs("/app0/keep.bin", FREEBSD_O_WRONLY | FREEBSD_O_CREAT | FREEBSD_O_TRUNC, "truncate existing");
  expect_open_erofs("/app0/keep.bin", FREEBSD_O_TRUNC, "O_RDONLY|O_TRUNC existing");
  CHECK(host_content_is("keep.bin", "original"), "the existing file kept its content");

  // O_CREAT|O_EXCL on an existing file is EEXIST (the name lookup fails before any write).
  int64_t fd = call(shim_open, guest_str(STR_A, "/app0/keep.bin"), FREEBSD_O_WRONLY | FREEBSD_O_CREAT | FREEBSD_O_EXCL, 0644);
  CHECK((int32_t)fd == -1 && guest_errno() == FREEBSD_EEXIST, "O_EXCL existing: fd %lld errno %d", (long long)fd,
        guest_errno());
  // Write access to a missing file without O_CREAT is ENOENT.
  fd = call(shim_open, guest_str(STR_A, "/app0/missing.bin"), FREEBSD_O_WRONLY, 0);
  CHECK((int32_t)fd == -1 && guest_errno() == FREEBSD_ENOENT, "write missing: fd %lld errno %d", (long long)fd,
        guest_errno());

  // Reading works, also with O_CREAT on a file that exists.
  fd = call(shim_open, guest_str(STR_A, "/app0/keep.bin"), 0, 0);
  CHECK((int32_t)fd >= 0, "read existing: fd %lld errno %d", (long long)fd, guest_errno());
  if ((int32_t)fd >= 0) close((int)fd);
  fd = call(shim_open, guest_str(STR_A, "/app0/keep.bin"), FREEBSD_O_CREAT, 0644);
  CHECK((int32_t)fd >= 0, "O_RDONLY|O_CREAT existing: fd %lld errno %d", (long long)fd, guest_errno());
  if ((int32_t)fd >= 0) close((int)fd);
}

static void test_path_ops(void) {
  CHECK((int32_t)call(shim_unlink, guest_str(STR_A, "/app0/keep.bin"), 0, 0) == -1 && guest_errno() == FREEBSD_EROFS,
        "unlink existing: errno %d", guest_errno());
  CHECK(host_exists("keep.bin"), "unlink left the file");
  CHECK((int32_t)call(shim_unlink, guest_str(STR_A, "/app0/missing.bin"), 0, 0) == -1 &&
            guest_errno() == FREEBSD_ENOENT,
        "unlink missing: errno %d", guest_errno());

  CHECK((int32_t)call(shim_mkdir, guest_str(STR_A, "/app0/newdir"), 0755, 0) == -1 && guest_errno() == FREEBSD_EROFS,
        "mkdir new: errno %d", guest_errno());
  CHECK(!host_exists("newdir"), "mkdir created nothing");
  CHECK((int32_t)call(shim_mkdir, guest_str(STR_A, "/app0/sub"), 0755, 0) == -1 && guest_errno() == FREEBSD_EEXIST,
        "mkdir existing: errno %d", guest_errno());

  CHECK((int32_t)call(shim_rmdir, guest_str(STR_A, "/app0/empty"), 0, 0) == -1 && guest_errno() == FREEBSD_EROFS,
        "rmdir: errno %d", guest_errno());
  CHECK(host_exists("empty"), "rmdir left the directory");
  CHECK((int32_t)call(shim_sceKernelRmdir, guest_str(STR_A, "/app0/empty"), 0, 0) == (int32_t)(0x80020000 | FREEBSD_EROFS),
        "sceKernelRmdir: rax 0x%llx", (unsigned long long)g_ctx.rax);
  CHECK(host_exists("empty"), "sceKernelRmdir left the directory");

  CHECK((int32_t)call(shim_rename, guest_str(STR_A, "/app0/keep.bin"), guest_str(STR_B, "/app0/moved.bin"), 0) == -1 &&
            guest_errno() == FREEBSD_EROFS,
        "rename within /app0: errno %d", guest_errno());
  CHECK(host_exists("keep.bin") && !host_exists("moved.bin"), "rename moved nothing");
  CHECK((int32_t)call(shim_rename, guest_str(STR_A, "/app0/keep.bin"), guest_str(STR_B, "/temp0/stolen.bin"), 0) == -1 &&
            guest_errno() == FREEBSD_EROFS,
        "rename out of /app0: errno %d", guest_errno());
  CHECK(host_exists("keep.bin"), "rename out of /app0 left the file");

  CHECK((int32_t)call(shim_truncate, guest_str(STR_A, "/app0/keep.bin"), 0, 0) == -1 && guest_errno() == FREEBSD_EROFS,
        "truncate: errno %d", guest_errno());
  CHECK((int32_t)call(shim_chmod, guest_str(STR_A, "/app0/keep.bin"), 0600, 0) == -1 && guest_errno() == FREEBSD_EROFS,
        "chmod: errno %d", guest_errno());
  CHECK((int32_t)call(shim_utimes, guest_str(STR_A, "/app0/keep.bin"), 0, 0) == -1 && guest_errno() == FREEBSD_EROFS,
        "utimes: errno %d", guest_errno());
  CHECK(host_content_is("keep.bin", "original"), "the existing file kept its content");
}

static void test_writable_mount(void) {
  // /temp0 is writable: create, write and remove a file there.
  int64_t fd = call(shim_open, guest_str(STR_A, "/temp0/w.bin"), FREEBSD_O_WRONLY | FREEBSD_O_CREAT | FREEBSD_O_TRUNC, 0644);
  CHECK((int32_t)fd >= 0, "create in /temp0: fd %lld errno %d", (long long)fd, guest_errno());
  if ((int32_t)fd >= 0) close((int)fd);
  CHECK(host_exists("tmp/w.bin"), "the /temp0 file exists on the host");
  CHECK((int32_t)call(shim_unlink, guest_str(STR_A, "/temp0/w.bin"), 0, 0) == 0, "unlink in /temp0: errno %d",
        guest_errno());
  CHECK(!host_exists("tmp/w.bin"), "the /temp0 file is gone");
}

int main(void) {
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;
  g_ctx.fs_base = 0x400;
  char tmpl[] = "/tmp/vfs_readonly_test.XXXXXX";
  if (!mkdtemp(tmpl)) {
    perror("mkdtemp");
    return 1;
  }
  if (!realpath(tmpl, g_root)) {
    perror("realpath");
    return 1;
  }
  mkdir(host("sce_sys"), 0755);
  mkdir(host("sub"), 0755);
  mkdir(host("empty"), 0755);
  mkdir(host("tmp"), 0755);
  write_host("keep.bin", "original");
  setenv("PS4_APP_DIR", g_root, 1);
  ps4_vfs_init(NULL);
  ps4_vfs_mount("/temp0", host("tmp"));

  test_open();
  test_path_ops();
  test_writable_mount();

  ps4_vfs_destroy();
  unlink(host("delete_me.snt"));
  unlink(host("moved.bin"));
  unlink(host("keep.bin"));
  unlink(host("tmp/stolen.bin"));
  rmdir(host("newdir"));
  rmdir(host("tmp"));
  rmdir(host("empty"));
  rmdir(host("sub"));
  rmdir(host("sce_sys"));
  rmdir(g_root);
  if (g_failures) {
    printf("vfs_readonly_test: %d failures\n", g_failures);
    return 1;
  }
  printf("vfs_readonly_test: PASS\n");
  return 0;
}
