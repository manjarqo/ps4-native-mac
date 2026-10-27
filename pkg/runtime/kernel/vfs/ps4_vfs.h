#ifndef PS4_VFS_H
#define PS4_VFS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize VFS with host directory path corresponding to /app0
void ps4_vfs_init(const char *app_root);

// Returns the current app root path
const char *ps4_vfs_get_app_root(void);

// Register a custom mount point: guest_prefix (e.g. "/temp0" or "/addcont0") -> host_path
int ps4_vfs_mount(const char *guest_prefix, const char *host_path);

// Unregister a mount point
int ps4_vfs_unmount(const char *guest_prefix);

// Resolves a guest path (e.g. /app0/assets/images/logo.png) to host filesystem path
// Returns 0 on success, or negative errno on error.
int ps4_vfs_resolve(const char *guest_path, char *host_path, size_t host_path_sz);

// Returns 1 when guest_path lies on a read-only file system, 0 otherwise. /app0 is the
// application package, a read-only PFS mount on the console: writes, creates, truncation,
// removal, renames and attribute changes there fail with EROFS. Mounts registered with
// ps4_vfs_mount (save data, /temp0, /download0, ...) are writable.
int ps4_vfs_is_read_only(const char *guest_path);

// Cleanup VFS state
void ps4_vfs_destroy(void);

#ifdef __cplusplus
}
#endif

#endif // PS4_VFS_H
