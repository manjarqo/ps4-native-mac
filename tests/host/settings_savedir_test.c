// Host test for the per-game files of the host: the key that names the settings file and the
// shader cache dir (core/ps4_game_key.h), the save directory lookup, and the settings file
// itself (core/ps4_settings_file.h).
#include "ps4_game_key.h"
#include "ps4_settings_file.h"
#include "ps4_vfs.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static int fails;

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            fprintf(stderr, "settings_savedir_test:%d: %s\n", __LINE__, #cond);       \
            fails++;                                                                  \
        }                                                                             \
    } while (0)

static void key_case(const char *id, const char *fallback, const char *want) {
    char out[64];
    bool ok = ps4_settings_key(id, fallback, out, sizeof(out));
    if (!ok || strcmp(out, want) != 0) {
        fprintf(stderr, "settings_savedir_test: key(%s,%s) = %s, want %s\n", id, fallback, ok ? out : "(false)", want);
        fails++;
    }
}

static void make_dir(const char *base, const char *name, time_t mtime) {
    char p[1024];
    snprintf(p, sizeof(p), "%s/%s", base, name);
    if (mkdir(p, 0755) != 0) { perror("mkdir"); exit(1); }
    struct timeval tv[2] = {{mtime, 0}, {mtime, 0}};
    if (utimes(p, tv) != 0) { perror("utimes"); exit(1); }
}

static void root_case(const char *id, const char *root, const char *want) {
    char out[64];
    bool ok = ps4_game_key_for_root(id, root, out, sizeof(out));
    if (!ok || strcmp(out, want) != 0) {
        fprintf(stderr, "settings_savedir_test: root key(%s,%s) = %s, want %s\n", id, root ? root : "(null)",
                ok ? out : "(false)", want);
        fails++;
    }
}

static void put_le(uint8_t *p, uint32_t v, int n) {
    for (int i = 0; i < n; i++) p[i] = (uint8_t)(v >> (8 * i));
}

// Writes <dir>/sce_sys/param.sfo with one string entry TITLE_ID.
static void write_sfo(const char *dir, const char *title_id) {
    uint8_t b[64] = {0x00, 'P', 'S', 'F'};
    const uint32_t keys = 20 + 16, data = keys + 12; // header, one entry, "TITLE_ID\0" padded
    const uint32_t len = (uint32_t)strlen(title_id) + 1;
    put_le(b + 4, 0x101, 4);
    put_le(b + 8, keys, 4);
    put_le(b + 12, data, 4);
    put_le(b + 16, 1, 4);
    put_le(b + 20, 0, 2);      // key offset
    put_le(b + 22, 0x0204, 2); // string
    put_le(b + 24, len, 4);
    put_le(b + 28, 16, 4);
    put_le(b + 32, 0, 4); // data offset
    memcpy(b + keys, "TITLE_ID", 9);
    memcpy(b + data, title_id, len);
    char p[1024];
    snprintf(p, sizeof(p), "%s/sce_sys", dir);
    if (mkdir(p, 0755) != 0) { perror("mkdir"); exit(1); }
    snprintf(p, sizeof(p), "%s/sce_sys/param.sfo", dir);
    FILE *f = fopen(p, "wb");
    if (!f || fwrite(b, 1, data + 16, f) != data + 16) { perror("param.sfo"); exit(1); }
    fclose(f);
}

// The running game's key from the VFS app root (PS4_APP_DIR) and its param.sfo.
static void current_case(const char *root, const char *want) {
    setenv("PS4_APP_DIR", root, 1);
    ps4_vfs_init(root);
    char out[64];
    bool ok = ps4_current_game_key(out, sizeof(out));
    if (!ok || strcmp(out, want) != 0) {
        fprintf(stderr, "settings_savedir_test: current key at %s = %s, want %s\n", root, ok ? out : "(false)", want);
        fails++;
    }
    ps4_vfs_destroy();
}

static void write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f || fputs(text, f) < 0) { perror(path); exit(1); }
    fclose(f);
}

static bool file_is(const char *path, const char *want) {
    char buf[1024] = {0};
    FILE *f = fopen(path, "r");
    if (!f) return false;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    if (strcmp(buf, want) == 0) return true;
    fprintf(stderr, "settings_savedir_test: %s is\n%s---\nwant\n%s---\n", path, buf, want);
    return false;
}

static void settings_file_cases(const char *dir) {
    char p[1024];
    snprintf(p, sizeof(p), "%s/CUSA00557.cfg", dir);
    Ps4SettingsFile s = {-1, 1, 0, 1, 0};
    CHECK(!ps4_settings_file_read(p, &s)); // no file
    CHECK(s.lang == -1 && s.pro == 1 && s.metal == 0);

    // The manager app's file: its renderer, a line of another writer, a comment.
    write_text(p, "lang=8\npro=0\nupscale=1\nhud=1\nmetal=4\nfuture=7\n# note\n");
    CHECK(ps4_settings_file_read(p, &s));
    CHECK(s.lang == 8 && s.pro == 0 && s.upscale == 1 && s.hud == 1 && s.metal == 4);
    // The dialog's save: its four keys change in place, every other line stays where it was.
    s.lang = 1;
    s.pro = 1;
    s.hud = 0;
    CHECK(ps4_settings_file_write(p, &s));
    CHECK(file_is(p, "lang=1\npro=1\nupscale=1\nhud=0\nmetal=4\nfuture=7\n# note\n"));

    // Owned keys the file lacks are appended; a duplicate is dropped; a last line without a newline is kept.
    write_text(p, "metal=3\nhud=1\nx=y\nhud=1");
    Ps4SettingsFile t = {-1, 1, 0, 1, 0};
    CHECK(ps4_settings_file_read(p, &t));
    CHECK(t.metal == 3);
    t.lang = 2;
    t.hud = 0;
    CHECK(ps4_settings_file_write(p, &t));
    CHECK(file_is(p, "metal=3\nhud=0\nx=y\nlang=2\npro=1\nupscale=0\n"));

    // A metal value other than 3 or 4 is automatic.
    write_text(p, "metal=5\n");
    CHECK(ps4_settings_file_read(p, &t));
    CHECK(t.metal == 0);

    // A new file holds the four keys.
    snprintf(p, sizeof(p), "%s/NEW.cfg", dir);
    CHECK(ps4_settings_file_write(p, &s));
    CHECK(file_is(p, "lang=1\npro=1\nupscale=1\nhud=0\n"));
    // No temp file is left behind.
    snprintf(p, sizeof(p), "%s/NEW.cfg.%d.tmp", dir, (int)getpid());
    CHECK(access(p, F_OK) != 0);
}

int main(void) {
    key_case("CUSA00557", "content", "CUSA00557");
    key_case("", "CUSA04529", "CUSA04529");
    key_case("../x", "content", "content");
    key_case("a b", "content", "content");
    key_case("A234567890123456789012345678901", "fb", "A234567890123456789012345678901");   // 31 chars
    key_case("A2345678901234567890123456789012", "fb", "fb");                               // 32 chars
    char out[64];
    CHECK(!ps4_settings_key("", "", out, sizeof(out)));
    CHECK(!ps4_settings_key(NULL, NULL, out, sizeof(out)));
    CHECK(!ps4_settings_key("CUSA00557", "x", out, 5)); // does not fit

    // The shader cache and settings key of an app root.
    root_case("CUSA00557", "/g/content", "CUSA00557");
    root_case("", "/g/CUSA00557", "CUSA00557");    // a dump dir named after its TITLE_ID keeps its name
    root_case(NULL, "/g/My Game/", "My Game");      // trailing slashes ignored
    root_case("", "relative", "relative");
    root_case("", "/", "default");
    root_case("", NULL, "default");
    root_case("bad id", "/g/content", "content");

    char tmpl[] = "/tmp/settings_savedir_test.XXXXXX";
    char *dir = mkdtemp(tmpl);
    if (!dir) { perror("mkdtemp"); return 1; }
    {
        // A copied or PKG import: games/<ID>/content with param.sfo; a dump without one.
        char game[1024], dump[1024];
        snprintf(game, sizeof(game), "%s/content", dir);
        snprintf(dump, sizeof(dump), "%s/CUSA04529", dir);
        if (mkdir(game, 0755) != 0 || mkdir(dump, 0755) != 0) { perror("mkdir"); return 1; }
        write_sfo(game, "CUSA07408");
        current_case(game, "CUSA07408");
        current_case(dump, "CUSA04529");
        unsetenv("PS4_APP_DIR");
    }
    settings_file_cases(dir);
    make_dir(dir, "A [CUSA00557]", 1000000);
    make_dir(dir, "B [CUSA00557]", 2000000);
    make_dir(dir, "C [CUSA04529]", 3000000);
    char filep[1024];
    snprintf(filep, sizeof(filep), "%s/D [CUSA00557]", dir);
    FILE *f = fopen(filep, "w");
    if (!f) { perror("fopen"); return 1; }
    fclose(f);
    struct timeval tv[2] = {{4000000, 0}, {4000000, 0}}; // the file is the newest, and must be ignored
    utimes(filep, tv);

    char want[1024];
    char big[1024];
    CHECK(ps4_find_save_dir_by_title_id(dir, "CUSA00557", big, sizeof(big)));
    snprintf(want, sizeof(want), "%s/B [CUSA00557]", dir);
    CHECK(strcmp(big, want) == 0);
    CHECK(ps4_find_save_dir_by_title_id(dir, "CUSA04529", big, sizeof(big)));
    snprintf(want, sizeof(want), "%s/C [CUSA04529]", dir);
    CHECK(strcmp(big, want) == 0);
    CHECK(!ps4_find_save_dir_by_title_id(dir, "CUSA99999", big, sizeof(big)));
    CHECK(!ps4_find_save_dir_by_title_id(dir, "", big, sizeof(big)));
    CHECK(!ps4_find_save_dir_by_title_id("/nonexistent/settings_savedir_test", "CUSA00557", big, sizeof(big)));
    CHECK(!ps4_find_save_dir_by_title_id(dir, "CUSA00557", big, 8)); // does not fit

    char cmd[1100];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
    if (strncmp(dir, "/tmp/settings_savedir_test.", 27) == 0) (void)system(cmd);
    if (fails) return 1;
    printf("settings_savedir_test: PASS\n");
    return 0;
}
