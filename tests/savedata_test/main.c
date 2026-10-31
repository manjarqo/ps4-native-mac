#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>
#include <glob.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include "ps4_savedata.h"


// Catch deferred-only persistence: child writes must already be on disk when it exits
// with _exit(), without SyncSaveDataMemory or SaveDataTerminate running.
static void memory_path(const char *root, unsigned slot, char *out, size_t cap) {
    char pattern[1024];
    if (slot == 0) {
        snprintf(pattern, sizeof(pattern), "%s/*/user_10000000/sce_sdmemory", root);
    } else {
        snprintf(pattern, sizeof(pattern), "%s/*/user_10000000/sce_sdmemory_%u", root, slot);
    }
    glob_t paths = {0};
    assert(glob(pattern, 0, NULL, &paths) == 0);
    assert(paths.gl_pathc == 1);
    assert(snprintf(out, cap, "%s/memory.dat", paths.gl_pathv[0]) < (int)cap);
    globfree(&paths);
}

static void verify_disk(const char *path, size_t size, unsigned slot) {
    FILE *f = fopen(path, "rb");
    assert(f != NULL);
    struct stat st;
    assert(fstat(fileno(f), &st) == 0 && (size_t)st.st_size == size);
    for (size_t i = 0; i < size; i++) {
        unsigned char want = 0;
        if (i >= 128 && i < 160) want = (unsigned char)(0x40 + slot);
        if (i >= size - 32) want = (unsigned char)(0x70 + slot);
        assert(fgetc(f) == want);
    }
    assert(fgetc(f) == EOF && !ferror(f));
    assert(fclose(f) == 0);
}

static void wait_success(pid_t child) {
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void test_process_persistence(const char *root) {
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        GuestContext ctx = {0};
        ctx.mem_size = 1024 * 1024;
        ctx.mem_base = calloc(1, ctx.mem_size);
        assert(ctx.mem_base);
        assert(sceSaveDataInitialize3(NULL) == 0);
        for (unsigned slot = 0; slot < 2; slot++) {
            size_t size = slot == 0 ? 6553600 : 131072;
            OrbisSaveDataMemorySetup2 setup = {.userId = 0x10000000,
                                               .slotId = slot, .memorySize = size};
            OrbisSaveDataMemorySetupResult result = {0};
            assert(sceSaveDataSetupSaveDataMemory2(&ctx, &setup, &result) == 0);
            assert(result.existedMemorySize == 0);
            // Multiple records must persist together, including the end of each slot.
            memset(ctx.mem_base + 0x10000, 0x40 + slot, 32);
            memset(ctx.mem_base + 0x10020, 0x70 + slot, 32);
            OrbisSaveDataMemoryData *data = (void *)(ctx.mem_base + 0x20000);
            data[0] = (OrbisSaveDataMemoryData){.buf = 0x10000, .bufSize = 32, .offset = 128};
            data[1] = (OrbisSaveDataMemoryData){.buf = 0x10020, .bufSize = 32,
                                              .offset = (int64_t)size - 32};
            OrbisSaveDataMemorySet2 set = {.userId = setup.userId, .slotId = slot,
                                           .data = 0x20000, .dataNum = 2};
            assert(sceSaveDataSetSaveDataMemory2(&ctx, &set) == 0);
            char path[1024];
            memory_path(root, slot, path, sizeof(path));
            verify_disk(path, size, slot); // Before any Setup, Sync or Terminate.
            assert(sceSaveDataSetupSaveDataMemory2(&ctx, &setup, &result) == 0);
            assert(result.existedMemorySize == size);
            OrbisSaveDataMemoryGet2 get = {.userId = setup.userId, .slotId = slot,
                                           .data = 0x20000};
            data[0].buf = 0x40000;
            assert(sceSaveDataGetSaveDataMemory2(&ctx, &get) == 0);
            for (int i = 0; i < 32; i++) assert(ctx.mem_base[0x40000 + i] == 0x40 + slot);
        }
        free(ctx.mem_base);
        _exit(0);
    }
    wait_success(child);
    // The parent has never initialized SaveData, so this second child has no inherited cache.
    child = fork();
    assert(child >= 0);
    if (child == 0) {
        GuestContext ctx = {0};
        ctx.mem_size = 1024 * 1024;
        ctx.mem_base = calloc(1, ctx.mem_size);
        assert(ctx.mem_base);
        assert(sceSaveDataInitialize3(NULL) == 0);
        for (unsigned slot = 0; slot < 2; slot++) {
            size_t size = slot == 0 ? 6553600 : 131072;
            OrbisSaveDataMemorySetup2 setup = {.userId = 0x10000000,
                                               .slotId = slot, .memorySize = size};
            OrbisSaveDataMemorySetupResult result = {0};
            assert(sceSaveDataSetupSaveDataMemory2(&ctx, &setup, &result) == 0);
            assert(result.existedMemorySize == size);
            OrbisSaveDataMemoryData *data = (void *)(ctx.mem_base + 0x20000);
            OrbisSaveDataMemoryGet2 get = {.userId = setup.userId, .slotId = slot,
                                           .data = 0x20000};
            *data = (OrbisSaveDataMemoryData){.buf = 0x40000, .bufSize = 32, .offset = 128};
            assert(sceSaveDataGetSaveDataMemory2(&ctx, &get) == 0);
            for (int i = 0; i < 32; i++) assert(ctx.mem_base[0x40000 + i] == 0x40 + slot);
            data->offset = (int64_t)size - 32;
            assert(sceSaveDataGetSaveDataMemory2(&ctx, &get) == 0);
            for (int i = 0; i < 32; i++) assert(ctx.mem_base[0x40000 + i] == 0x70 + slot);
            OrbisSaveDataMemorySync sync = {.userId = setup.userId, .slotId = slot};
            assert(sceSaveDataSyncSaveDataMemory(&ctx, &sync) == 0);
        }
        assert(sceSaveDataTerminate() == 0);
        free(ctx.mem_base);
        _exit(0);
    }
    wait_success(child);
    puts("[+] Both Sonic-sized slots persisted immediately and survived _exit without Terminate");
}

// A small stdio write fits in its buffer: RLIMIT_FSIZE=0 fails the flush rather
// than fwrite. Ignoring that error used to replace a valid save with an empty file.
static void test_flush_failure(const char *root) {
    GuestContext ctx = {0};
    ctx.mem_size = 1024 * 1024;
    ctx.mem_base = calloc(1, ctx.mem_size);
    assert(ctx.mem_base);
    assert(sceSaveDataInitialize3(NULL) == 0);
    OrbisSaveDataMemorySetup2 setup = {.userId = 0x10000000, .slotId = 2, .memorySize = 128};
    assert(sceSaveDataSetupSaveDataMemory2(&ctx, &setup, NULL) == 0);
    OrbisSaveDataMemoryData *data = (void *)(ctx.mem_base + 0x20000);
    *data = (OrbisSaveDataMemoryData){.buf = 0x10000, .bufSize = 128};
    OrbisSaveDataMemorySet2 set = {.userId = setup.userId, .slotId = 2,
                                   .data = 0x20000, .dataNum = 1};
    memset(ctx.mem_base + 0x10000, 0x55, 128);
    assert(sceSaveDataSetSaveDataMemory2(&ctx, &set) == 0);
    char path[1024], tmp[1100];
    memory_path(root, 2, path, sizeof(path));
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    struct rlimit original;
    assert(getrlimit(RLIMIT_FSIZE, &original) == 0);
    struct rlimit limited = original;
    limited.rlim_cur = 0;
    struct sigaction ignored = {.sa_handler = SIG_IGN}, previous;
    sigemptyset(&ignored.sa_mask);
    assert(sigaction(SIGXFSZ, &ignored, &previous) == 0);
    fflush(NULL); // Do not strand test output behind the temporary limit.
    assert(setrlimit(RLIMIT_FSIZE, &limited) == 0);
    memset(ctx.mem_base + 0x10000, 0x77, 128);
    int32_t rc = sceSaveDataSetSaveDataMemory2(&ctx, &set);
    int restore_rc = setrlimit(RLIMIT_FSIZE, &original);
    int signal_rc = sigaction(SIGXFSZ, &previous, NULL);
    assert(restore_rc == 0 && signal_rc == 0);
    assert(rc == ORBIS_SAVE_DATA_ERROR_INTERNAL);
    FILE *f = fopen(path, "rb");
    assert(f);
    for (int i = 0; i < 128; i++) assert(fgetc(f) == 0x55);
    assert(fgetc(f) == EOF && !ferror(f));
    assert(fclose(f) == 0);
    assert(access(tmp, F_OK) == -1);
    // A failed flush must retain the dirty buffer; Terminate retries it.
    assert(sceSaveDataTerminate() == 0);
    f = fopen(path, "rb");
    assert(f);
    for (int i = 0; i < 128; i++) assert(fgetc(f) == 0x77);
    assert(fgetc(f) == EOF && !ferror(f));
    assert(fclose(f) == 0);
    free(ctx.mem_base);
    puts("[+] Failed buffered flush preserved the old save, removed the temp file and retained dirty data");
}

typedef struct WriteLimit {
    struct rlimit previous;
    struct sigaction signal;
} WriteLimit;

static WriteLimit deny_file_writes(void) {
    WriteLimit state;
    assert(getrlimit(RLIMIT_FSIZE, &state.previous) == 0);
    struct rlimit limit = state.previous;
    limit.rlim_cur = 0;
    struct sigaction ignore = {.sa_handler = SIG_IGN};
    sigemptyset(&ignore.sa_mask);
    assert(sigaction(SIGXFSZ, &ignore, &state.signal) == 0);
    fflush(NULL);
    assert(setrlimit(RLIMIT_FSIZE, &limit) == 0);
    return state;
}

static void restore_file_writes(WriteLimit state) {
    assert(setrlimit(RLIMIT_FSIZE, &state.previous) == 0);
    assert(sigaction(SIGXFSZ, &state.signal, NULL) == 0);
}

static void test_metadata_failure(const char *root, int icon_case) {
    GuestContext ctx = {.mem_size = 1024 * 1024};
    ctx.mem_base = calloc(1, ctx.mem_size);
    assert(ctx.mem_base);
    assert(sceSaveDataInitialize3(NULL) == 0);
    OrbisSaveDataMemorySetup2 setup = {.userId = 0x10000000, .slotId = 4, .memorySize = 128};
    assert(sceSaveDataSetupSaveDataMemory2(&ctx, &setup, NULL) == 0);
    struct TestIcon { uint64_t buf, bufSize, dataSize; uint8_t reserved[32]; };
    struct TestIcon *icon = (void *)(ctx.mem_base + 0x20000);
    *icon = (struct TestIcon){.buf = 0x30000, .bufSize = 32, .dataSize = 32};
    Ps4SaveDataParam *param = (void *)(ctx.mem_base + 0x10000);
    memset(param, 0, sizeof(*param));
    strcpy(param->title, "Original title");
    memset(ctx.mem_base + icon->buf, 0x55, 32);
    OrbisSaveDataMemorySet2 set = {.userId = setup.userId, .slotId = setup.slotId,
                                  .param = icon_case ? 0 : 0x10000, .icon = icon_case ? 0x20000 : 0};
    assert(sceSaveDataSetSaveDataMemory2(&ctx, &set) == 0);
    char memory[1024], path[1200], tmp[1210];
    memory_path(root, 4, memory, sizeof(memory));
    *strrchr(memory, '/') = '\0';
    snprintf(path, sizeof(path), "%s/sce_sys/%s", memory, icon_case ? "icon0.png" : "param.bin");
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    size_t size = icon_case ? 32 : sizeof(*param);
    uint8_t original[sizeof(Ps4SaveDataParam)];
    FILE *f = fopen(path, "rb");
    assert(f && fread(original, 1, size, f) == size && fclose(f) == 0);
    strcpy(param->title, "Replacement title");
    memset(ctx.mem_base + icon->buf, 0x77, 32);
    WriteLimit limit = deny_file_writes();
    int32_t rc = sceSaveDataSetSaveDataMemory2(&ctx, &set);
    restore_file_writes(limit);
    assert(rc == ORBIS_SAVE_DATA_ERROR_INTERNAL);
    uint8_t after[sizeof(Ps4SaveDataParam)];
    f = fopen(path, "rb");
    assert(f && fread(after, 1, size, f) == size);
    assert(fgetc(f) == EOF && !ferror(f) && fclose(f) == 0);
    assert(memcmp(original, after, size) == 0 && access(tmp, F_OK) == -1);
    assert(sceSaveDataSetSaveDataMemory2(&ctx, &set) == 0);
    f = fopen(path, "rb");
    assert(f && fread(after, 1, size, f) == size && fclose(f) == 0);
    assert(memcmp(original, after, size) != 0);
    assert(sceSaveDataTerminate() == 0);
    free(ctx.mem_base);
    puts(icon_case ? "[+] Failed icon-only update preserved previous icon and retry succeeded"
                   : "[+] Failed param-only update preserved previous metadata and retry succeeded");
}

static void test_cleanup_failure(const char *root, int terminate_case) {
    GuestContext ctx = {.mem_size = 1024 * 1024};
    ctx.mem_base = calloc(1, ctx.mem_size);
    assert(ctx.mem_base && sceSaveDataInitialize3(NULL) == 0);
    OrbisSaveDataMemorySetup2 setup = {.userId = 0x10000000, .slotId = 5, .memorySize = 128};
    assert(sceSaveDataSetupSaveDataMemory2(&ctx, &setup, NULL) == 0);
    OrbisSaveDataMemoryData *data = (void *)(ctx.mem_base + 0x20000);
    *data = (OrbisSaveDataMemoryData){.buf = 0x10000, .bufSize = 128};
    memset(ctx.mem_base + data->buf, 0x77, 128);
    OrbisSaveDataMemorySet2 set = {.userId = setup.userId, .slotId = setup.slotId, .data = 0x20000};
    WriteLimit limit = deny_file_writes();
    assert(sceSaveDataSetSaveDataMemory2(&ctx, &set) == ORBIS_SAVE_DATA_ERROR_INTERNAL);
    OrbisSaveDataMemorySetup2 other = setup;
    other.userId++;
    int32_t rc = terminate_case ? sceSaveDataTerminate() : sceSaveDataSetupSaveDataMemory2(&ctx, &other, NULL);
    restore_file_writes(limit);
    assert(rc == ORBIS_SAVE_DATA_ERROR_INTERNAL);
    memset(ctx.mem_base + data->buf, 0, 128);
    OrbisSaveDataMemoryGet2 get = {.userId = setup.userId, .slotId = setup.slotId, .data = 0x20000};
    assert(sceSaveDataGetSaveDataMemory2(&ctx, &get) == 0);
    for (int i = 0; i < 128; i++) assert(ctx.mem_base[data->buf + i] == 0x77);
    assert(sceSaveDataTerminate() == 0);
    char path[1024];
    memory_path(root, 5, path, sizeof(path));
    FILE *f = fopen(path, "rb");
    assert(f);
    for (int i = 0; i < 128; i++) assert(fgetc(f) == 0x77);
    assert(fgetc(f) == EOF && !ferror(f) && fclose(f) == 0);
    free(ctx.mem_base);
    puts(terminate_case ? "[+] Failed Terminate retained initialized cache for retry"
                        : "[+] Failed Setup replacement retained previous user's dirty cache");
}

int main(int argc, char **argv) {
    printf("[ps4-savedata-test] Running SaveData tests...\n");

    // Set isolated test directory
    char test_dir[] = "/tmp/ps4_recomp_savedata_test.XXXXXX";
    assert(mkdtemp(test_dir));
    char rm_cmd[256];
    snprintf(rm_cmd, sizeof(rm_cmd), "rm -rf %s", test_dir);
    setenv("PS4_SAVEDATA_DIR", test_dir, 1);

    if (argc == 2) {
        if (strcmp(argv[1], "metadata-param") == 0) test_metadata_failure(test_dir, 0);
        else if (strcmp(argv[1], "metadata-icon") == 0) test_metadata_failure(test_dir, 1);
        else if (strcmp(argv[1], "cleanup-setup") == 0) test_cleanup_failure(test_dir, 0);
        else { assert(strcmp(argv[1], "cleanup-terminate") == 0); test_cleanup_failure(test_dir, 1); }
        assert(system(rm_cmd) == 0);
        return 0;
    }

    test_process_persistence(test_dir);
    test_flush_failure(test_dir);
    test_metadata_failure(test_dir, 0);
    test_metadata_failure(test_dir, 1);
    test_cleanup_failure(test_dir, 0);
    test_cleanup_failure(test_dir, 1);

    // Keep the original explicit-Sync scenario in its own slot.
    // 1. Initialize
    int32_t ret = sceSaveDataInitialize3(NULL);
    assert(ret == 0);
    printf("[+] sceSaveDataInitialize3 succeeded\n");

    // Create a mock GuestContext with memory
    GuestContext ctx = {0};
    ctx.mem_size = 10 * 1024 * 1024;
    ctx.mem_base = (uint8_t *)calloc(1, ctx.mem_size);
    assert(ctx.mem_base != NULL);

    // 2. Setup a separate memory slot (first time, should be 0 existing size)
    OrbisSaveDataMemorySetup2 setupParam = {0};
    setupParam.userId = 0x10000000;
    setupParam.slotId = 3;
    setupParam.memorySize = 4096;

    OrbisSaveDataMemorySetupResult setupResult = {0};
    ret = sceSaveDataSetupSaveDataMemory2(&ctx, &setupParam, &setupResult);
    assert(ret == 0);
    assert(setupResult.existedMemorySize == 0);
    printf("[+] First setup: existedMemorySize = %zu (expected 0)\n", setupResult.existedMemorySize);

    // 3. Write data
    const char test_str[] = "PS4RECOMP_SAVE_SILKSONG_TEST_DATA_2026";
    size_t test_len = strlen(test_str) + 1;

    // Allocate buffer inside guest memory
    uint64_t guest_src_addr = 0x10000;
    memcpy(ctx.mem_base + guest_src_addr, test_str, test_len);

    uint64_t guest_memdata_addr = 0x20000;
    OrbisSaveDataMemoryData *g_data = (OrbisSaveDataMemoryData *)(ctx.mem_base + guest_memdata_addr);
    g_data->buf = guest_src_addr;
    g_data->bufSize = test_len;
    g_data->offset = 64;

    uint64_t guest_setparam_addr = 0x30000;
    OrbisSaveDataMemorySet2 *g_setParam = (OrbisSaveDataMemorySet2 *)(ctx.mem_base + guest_setparam_addr);
    g_setParam->userId = 0x10000000;
    g_setParam->slotId = 3;
    g_setParam->data = guest_memdata_addr;
    g_setParam->dataNum = 1;

    ret = sceSaveDataSetSaveDataMemory2(&ctx, g_setParam);
    assert(ret == 0);
    printf("[+] sceSaveDataSetSaveDataMemory2 succeeded\n");

    // 4. Sync to disk
    OrbisSaveDataMemorySync syncParam = {0};
    syncParam.userId = 0x10000000;
    syncParam.slotId = 3;
    ret = sceSaveDataSyncSaveDataMemory(&ctx, &syncParam);
    assert(ret == 0);
    printf("[+] sceSaveDataSyncSaveDataMemory succeeded\n");

    // 5. Terminate
    ret = sceSaveDataTerminate();
    assert(ret == 0);
    printf("[+] sceSaveDataTerminate succeeded\n");

    // 6. Re-initialize and verify persistence
    ret = sceSaveDataInitialize3(NULL);
    assert(ret == 0);

    memset(&setupResult, 0, sizeof(setupResult));
    ret = sceSaveDataSetupSaveDataMemory2(&ctx, &setupParam, &setupResult);
    assert(ret == 0);
    assert(setupResult.existedMemorySize >= 4096);
    printf("[+] Re-setup: existedMemorySize = %zu (persisted successfully)\n", setupResult.existedMemorySize);

    // 7. Read back data
    uint64_t guest_dst_addr = 0x40000;
    memset(ctx.mem_base + guest_dst_addr, 0, test_len);

    uint64_t guest_getdata_addr = 0x50000;
    OrbisSaveDataMemoryData *g_getdata = (OrbisSaveDataMemoryData *)(ctx.mem_base + guest_getdata_addr);
    g_getdata->buf = guest_dst_addr;
    g_getdata->bufSize = test_len;
    g_getdata->offset = 64;

    uint64_t guest_getparam_addr = 0x60000;
    OrbisSaveDataMemoryGet2 *g_getParam = (OrbisSaveDataMemoryGet2 *)(ctx.mem_base + guest_getparam_addr);
    g_getParam->userId = 0x10000000;
    g_getParam->slotId = 3;
    g_getParam->data = guest_getdata_addr;

    ret = sceSaveDataGetSaveDataMemory2(&ctx, g_getParam);
    assert(ret == 0);

    const char *read_str = (const char *)(ctx.mem_base + guest_dst_addr);
    assert(strcmp(read_str, test_str) == 0);
    printf("[+] Verified read data: '%s'\n", read_str);

    // 8. Verify Sonic Origins pattern: SetSaveDataMemory2 without SyncSaveDataMemory,
    // followed by repeated SetupSaveDataMemory2 in the same session and across restart.
    const char test_str2[] = "PS4RECOMP_SONIC_ORIGINS_SAVEDATA_PERSIST_TEST";
    size_t test_len2 = strlen(test_str2) + 1;
    memcpy(ctx.mem_base + guest_src_addr, test_str2, test_len2);
    g_data->buf = guest_src_addr;
    g_data->bufSize = test_len2;
    g_data->offset = 128;

    ret = sceSaveDataSetSaveDataMemory2(&ctx, g_setParam);
    assert(ret == 0);

    // Repeated SetupSaveDataMemory2 before GetSaveDataMemory2 in the same session
    memset(&setupResult, 0, sizeof(setupResult));
    ret = sceSaveDataSetupSaveDataMemory2(&ctx, &setupParam, &setupResult);
    assert(ret == 0);
    assert(setupResult.existedMemorySize >= 4096);

    memset(ctx.mem_base + guest_dst_addr, 0, test_len2);
    g_getdata->buf = guest_dst_addr;
    g_getdata->bufSize = test_len2;
    g_getdata->offset = 128;
    ret = sceSaveDataGetSaveDataMemory2(&ctx, g_getParam);
    assert(ret == 0);
    assert(strcmp((const char *)(ctx.mem_base + guest_dst_addr), test_str2) == 0);
    printf("[+] Verified in-session data preserved across repeated SetupSaveDataMemory2\n");

    // Restart session without calling sceSaveDataSyncSaveDataMemory
    ret = sceSaveDataTerminate();
    assert(ret == 0);
    ret = sceSaveDataInitialize3(NULL);
    assert(ret == 0);

    memset(&setupResult, 0, sizeof(setupResult));
    ret = sceSaveDataSetupSaveDataMemory2(&ctx, &setupParam, &setupResult);
    assert(ret == 0);
    assert(setupResult.existedMemorySize >= 4096);

    memset(ctx.mem_base + guest_dst_addr, 0, test_len2);
    ret = sceSaveDataGetSaveDataMemory2(&ctx, g_getParam);
    assert(ret == 0);
    assert(strcmp((const char *)(ctx.mem_base + guest_dst_addr), test_str2) == 0);
    printf("[+] Verified cross-restart persistence without SyncSaveDataMemory\n");

    ret = sceSaveDataTerminate();
    assert(ret == 0);

    free(ctx.mem_base);
    system(rm_cmd);
    printf("[ps4-savedata-test] ALL TESTS PASSED!\n");
    return 0;
}
