// Host test of libSceSaveData directories and the save data dialog's automatic answers
// (PS4_SAVEDATA_DIALOG=auto), called through the guest ABI as a game calls them: saves are
// created with Mount2 / SetParam / Umount, listed with DirNameSearch (MTIME descending, as
// inFAMOUS asks), and offered in a list dialog.
#include "ps4_savedata.h"
#include "ps4_savedata_dialog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// The dialog's texts follow the system language (libSceSystemService); this test reads no text.
int ps4_host_choose_language(void) { return 1; }

void shim_sceSaveDataMount2(GuestContext *ctx);
void shim_sceSaveDataUmount(GuestContext *ctx);
void shim_sceSaveDataSetParam(GuestContext *ctx);
void shim_sceSaveDataDirNameSearch(GuestContext *ctx);

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

#define MEM_SIZE 0x100000
static uint8_t g_mem[MEM_SIZE];
static GuestContext g_ctx;

static int64_t call(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = a1;
  g_ctx.rsi = a2;
  g_ctx.rdx = a3;
  g_ctx.rcx = a4;
  shim(&g_ctx);
  if (g_ctx.rsp != 0x1008) {
    printf("FAIL: shim did not pop its return address\n");
    g_failures++;
  }
  return (int64_t)g_ctx.rax;
}

#define USER 0x10000000
#define DIRNAME 0x2000   // one SceSaveDataDirName (32 bytes)
#define MOUNT 0x2100     // SceSaveDataMount2
#define MOUNT_RES 0x2200 // SceSaveDataMountResult (mount point first)
#define VALUE 0x2300     // SetParam buffer

// Creates the save directory `name` with param.mtime = mtime, as a game's save does.
static void make_save(const char *name, int64_t mtime) {
  memset(g_mem + DIRNAME, 0, 32);
  strcpy((char *)g_mem + DIRNAME, name);
  memset(g_mem + MOUNT, 0, 64);
  *(int32_t *)(g_mem + MOUNT) = USER;
  *(uint64_t *)(g_mem + MOUNT + 0x08) = DIRNAME;
  *(uint64_t *)(g_mem + MOUNT + 0x10) = 96;     // blocks
  *(uint32_t *)(g_mem + MOUNT + 0x18) = 0x2 | 0x4; // RDWR | CREATE
  CHECK(call(shim_sceSaveDataMount2, MOUNT, MOUNT_RES, 0, 0) == 0, "mount %s", name);
  memcpy(g_mem + VALUE, &mtime, sizeof(mtime));
  CHECK(call(shim_sceSaveDataSetParam, MOUNT_RES, 5 /* MTIME */, VALUE, sizeof(mtime)) == 0, "mtime %s", name);
  CHECK(call(shim_sceSaveDataUmount, MOUNT_RES, 0, 0, 0) == 0, "umount %s", name);
}

#define NAMES 0x3000      // the dialog's dirName array
#define ITEMS 0x3400      // SceSaveDataDialogItems
#define PARAM 0x3500      // SceSaveDataDialogParam
#define RESULT 0x3600     // SceSaveDataDialogResult
#define RESULT_DIR 0x3700 // the result's dirName buffer

#define NEW_ITEM 0x3800   // SceSaveDataDialogNewItem
#define NEW_TITLE 0x3880  // its title
#define FOCUS_DIR 0x3900  // the focusPosDirName for FOCUS_DIRNAME

static bool g_offer_new;         // save lists offer the "new saved data" item
static const char *g_focus_dir; // focusPosDirName (NULL: none)

// Opens a list dialog over `names` (in the game's order) with the given focus, lets the automatic
// answer finish it, and returns the chosen directory ("" for none); *result_out gets the result.
static const char *list_answer(uint32_t type, const char *const *names, uint32_t n, uint32_t focus_pos,
                               int32_t *result_out) {
  memset(g_mem + NAMES, 0, 32 * 16);
  for (uint32_t i = 0; i < n; i++) strcpy((char *)g_mem + NAMES + 32 * i, names[i]);
  memset(g_mem + ITEMS, 0, 0x60);
  *(int32_t *)(g_mem + ITEMS) = USER;
  *(uint64_t *)(g_mem + ITEMS + 0x10) = NAMES;
  *(uint32_t *)(g_mem + ITEMS + 0x18) = n;
  *(uint32_t *)(g_mem + ITEMS + 0x28) = focus_pos;
  if (g_focus_dir) {
    memset(g_mem + FOCUS_DIR, 0, 32);
    strcpy((char *)g_mem + FOCUS_DIR, g_focus_dir);
    *(uint64_t *)(g_mem + ITEMS + 0x30) = FOCUS_DIR;
  }
  if (g_offer_new) {
    memset(g_mem + NEW_ITEM, 0, 0x40);
    strcpy((char *)g_mem + NEW_TITLE, "New save");
    *(uint64_t *)(g_mem + NEW_ITEM) = NEW_TITLE;
    *(uint64_t *)(g_mem + ITEMS + 0x20) = NEW_ITEM;
  }
  OrbisSaveDataDialogParam *p = (OrbisSaveDataDialogParam *)(g_mem + PARAM);
  memset(p, 0, sizeof(*p));
  p->mode = ORBIS_SAVE_DATA_DIALOG_MODE_LIST;
  p->dispType = (OrbisSaveDataDialogType)type;
  p->items = (void *)(uintptr_t)ITEMS;
  CHECK(call(shim_sceSaveDataDialogInitialize, 0, 0, 0, 0) == 0, "initialize");
  CHECK(call(shim_sceSaveDataDialogOpen, PARAM, 0, 0, 0) == 0, "open");
  CHECK(call(shim_sceSaveDataDialogUpdateStatus, 0, 0, 0, 0) == ORBIS_COMMON_DIALOG_STATUS_FINISHED,
        "the automatic answer finishes the dialog");
  OrbisSaveDataDialogResult *r = (OrbisSaveDataDialogResult *)(g_mem + RESULT);
  memset(r, 0, sizeof(*r));
  memset(g_mem + RESULT_DIR, 0x55, 32);
  r->dirName = (void *)(uintptr_t)RESULT_DIR;
  CHECK(call(shim_sceSaveDataDialogGetResult, RESULT, 0, 0, 0) == 0, "result");
  *result_out = r->result;
  call(shim_sceSaveDataDialogTerminate, 0, 0, 0, 0);
  return (const char *)g_mem + RESULT_DIR;
}

enum { FOCUS_LISTHEAD = 0, FOCUS_DATALATEST = 4, FOCUS_DATAOLDEST = 5, FOCUS_DIRNAME = 6 };

#define COND 0x4000        // SceSaveDataDirNameSearchCond
#define SEARCH_RES 0x4100  // SceSaveDataDirNameSearchResult
#define SEARCH_NAMES 0x4200 // its dirNames array

// DirNameSearch as inFAMOUS calls it before its dialogs: pattern "game%", MTIME (3) descending (1).
// Copies the found names, in the returned order, into out (32 bytes each); returns setNum.
static uint32_t search_newest_first(char out[][32], uint32_t cap) {
  memset(g_mem + COND, 0, 0x60);
  memset(g_mem + SEARCH_RES, 0, 0x40);
  memset(g_mem + SEARCH_NAMES, 0, 32 * cap);
  strcpy((char *)g_mem + DIRNAME, "game%");
  *(int32_t *)(g_mem + COND) = USER;
  *(uint64_t *)(g_mem + COND + 0x10) = DIRNAME;
  *(uint32_t *)(g_mem + COND + 0x18) = 3; // key MTIME
  *(uint32_t *)(g_mem + COND + 0x1c) = 1; // order DESCENT
  *(uint64_t *)(g_mem + SEARCH_RES + 0x08) = SEARCH_NAMES;
  *(uint32_t *)(g_mem + SEARCH_RES + 0x10) = cap;
  CHECK(call(shim_sceSaveDataDirNameSearch, COND, SEARCH_RES, 0, 0) == 0, "DirNameSearch");
  CHECK(*(uint32_t *)(g_mem + SEARCH_RES) == 3, "hitNum %u", *(uint32_t *)(g_mem + SEARCH_RES));
  uint32_t set = *(uint32_t *)(g_mem + SEARCH_RES + 0x14);
  for (uint32_t i = 0; i < set && i < cap; i++) memcpy(out[i], g_mem + SEARCH_NAMES + 32 * i, 32);
  return set;
}

// PS4_SAVEDATA_DIALOG_PICK="new,<dirName>" answers the lists in the order they open, as a game
// that asks to save before it loads opens them; the last choice repeats. Runs in its own process
// (the sequence counts the lists answered since start).
static void pick_sequence(void) {
  setenv("PS4_SAVEDATA_DIALOG_PICK", "new,gameAuto0", 1);
  const char *order[] = {"gameUser0", "gameUser1", "gameAuto0"};
  int32_t res = -1;
  g_offer_new = true;
  const char *dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_SAVE, order, 3, FOCUS_DATALATEST, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && dir[0] == 0, "1st list (save): new item, got '%.31s' %d", dir, res);
  g_offer_new = false;
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order, 3, FOCUS_DATALATEST, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && strcmp(dir, "gameAuto0") == 0, "2nd list (load): got '%.31s'", dir);
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order, 3, FOCUS_DATALATEST, &res);
  CHECK(strcmp(dir, "gameAuto0") == 0, "3rd list repeats the last choice: got '%.31s'", dir);
}

int main(int argc, char **argv) {
  const bool seq = argc > 1 && strcmp(argv[1], "sequence") == 0;
  char root[] = "/tmp/ps4_savedata_dialog_test.XXXXXX";
  if (!mkdtemp(root)) {
    perror("mkdtemp");
    return 1;
  }
  setenv("PS4_SAVEDATA_DIR", root, 1);
  setenv("PS4_SAVEDATA_DIALOG", "auto", 1);
  unsetenv("PS4_SAVEDATA_DIALOG_PICK");
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;
  sceSaveDataInitialize3(NULL);

  make_save("gameUser0", 1000);
  make_save("gameUser1", 3000); // the latest
  make_save("gameAuto0", 2000);
  if (seq) {
    pick_sequence();
    goto done;
  }
  const char *order[] = {"gameUser0", "gameUser1", "gameAuto0"};
  int32_t res = -1;

  // Listed newest first, as the game asks; this is the order its load list gets.
  char found[4][32];
  CHECK(search_newest_first(found, 4) == 3, "setNum");
  CHECK(strcmp(found[0], "gameUser1") == 0 && strcmp(found[1], "gameAuto0") == 0 && strcmp(found[2], "gameUser0") == 0,
        "MTIME descending: got %.31s, %.31s, %.31s", found[0], found[1], found[2]);
  const char *newest_first[] = {found[0], found[1], found[2]};
  const char *dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, newest_first, 3, FOCUS_DATALATEST, &res);
  CHECK(strcmp(dir, "gameUser1") == 0, "searched list, focus latest: got '%.31s'", dir);

  // A load list focused on a named save (focusPosDirName).
  g_focus_dir = "gameAuto0";
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order, 3, FOCUS_DIRNAME, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && strcmp(dir, "gameAuto0") == 0,
        "load list, focus by name: got '%.31s', want gameAuto0", dir);
  g_focus_dir = NULL;

  // A load list focused on the latest save: X on the console loads the focused save.
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order, 3, FOCUS_DATALATEST, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && strcmp(dir, "gameUser1") == 0,
        "load list, focus latest: got '%.31s' result %d, want gameUser1", dir, res);
  const char *order2[] = {"gameAuto0", "gameUser0", "gameUser1"};
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order2, 3, FOCUS_DATAOLDEST, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && strcmp(dir, "gameUser0") == 0,
        "load list, focus oldest: got '%.31s', want gameUser0", dir);
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order + 1, 2, FOCUS_LISTHEAD, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && strcmp(dir, "gameUser1") == 0,
        "load list, focus head: got '%.31s', want gameUser1", dir);

  // A listed name without a directory is not offered (the console lists existing saves only).
  const char *with_missing[] = {"gameUser9", "gameAuto0"};
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, with_missing, 2, FOCUS_LISTHEAD, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_OK && strcmp(dir, "gameAuto0") == 0,
        "missing dir skipped: got '%.31s', want gameAuto0", dir);

  // A delete list is never answered with a deletion.
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_DELETE, order, 3, FOCUS_DATALATEST, &res);
  CHECK(res == ORBIS_COMMON_DIALOG_RESULT_USER_CANCELED && dir[0] == 0, "delete list canceled: '%.31s' %d", dir, res);

  // PS4_SAVEDATA_DIALOG_PICK=<dirName> picks that save whatever the focus.
  setenv("PS4_SAVEDATA_DIALOG_PICK", "gameAuto0", 1);
  dir = list_answer(ORBIS_SAVE_DATA_DIALOG_TYPE_LOAD, order, 3, FOCUS_DATALATEST, &res);
  CHECK(strcmp(dir, "gameAuto0") == 0, "pick by name: got '%.31s'", dir);
  unsetenv("PS4_SAVEDATA_DIALOG_PICK");

done:;
  char cmd[128];
  snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root);
  if (system(cmd) != 0) printf("warning: could not remove %s\n", root);
  if (g_failures) {
    printf("savedata_dialog_test%s: FAIL (%d)\n", seq ? " sequence" : "", g_failures);
    return 1;
  }
  printf("savedata_dialog_test%s: PASS\n", seq ? " sequence" : "");
  return 0;
}
