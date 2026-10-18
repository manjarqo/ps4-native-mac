#ifndef PS4_METAL_SCREEN_H
#define PS4_METAL_SCREEN_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int ps4_metal_screen_init(int width, int height, const char *title);
int ps4_metal_screen_present_frame(const void *pixels, size_t pitch, int width, int height);
// Present a BGRA8Unorm MTLTexture (id<MTLTexture> bridged to void*) whose GPU work has completed.
int ps4_metal_screen_present_texture(void *texture);
// Encode presenting `texture` (BGRA8Unorm) into `command_buffer` (id<MTLCommandBuffer>, not yet
// committed) after the work already in it; no CPU wait.
int ps4_metal_screen_encode_present(void *command_buffer, void *texture);
void ps4_metal_screen_pump_events(void);
// Output gamma from sceVideoOutAdjustColor (1.0 = plain sRGB).
void ps4_metal_screen_set_gamma(float gamma);
void *ps4_metal_screen_get_device(void);
void *ps4_metal_screen_get_command_queue(void);
void *ps4_metal_screen_get_layer(void);
void *ps4_metal_screen_get_texture(void);
void ps4_metal_screen_destroy(void);

#ifdef __cplusplus
}
#endif

#endif // PS4_METAL_SCREEN_H
