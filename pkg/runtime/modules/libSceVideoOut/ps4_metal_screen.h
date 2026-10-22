#ifndef PS4_METAL_SCREEN_H
#define PS4_METAL_SCREEN_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int ps4_metal_screen_init(int width, int height, const char *title);
int ps4_metal_screen_present_frame(const void *pixels, size_t pitch, int width, int height);
// Present a BGRA8Unorm MTLTexture (id<MTLTexture> bridged to void*) whose GPU work has completed.
int ps4_metal_screen_present_texture(void *texture);
// GPU presentation goes through the presenter thread (see docs/present-pacing.md):
// 1. ps4_metal_screen_try_acquire_frame returns a present slot texture (id<MTLTexture>, BGRA8Unorm,
//    render target) of the given size to render the frame into, or NULL without waiting while
//    every slot is queued or being shown (back-pressure from the display).
// 2. ps4_metal_screen_encode_present queues `texture` for the presenter behind the work already
//    in `command_buffer` (id<MTLCommandBuffer>, not yet committed): the presenter's copy to the
//    window waits on the GPU for that work. No CPU wait. A texture that is not an acquired slot
//    is copied into a free slot in `command_buffer`, or dropped when none is free.
// 3. Held frames, when no slot is free: ps4_metal_screen_hold_texture returns a texture of the
//    given size (NULL if none is available), the renderer renders the frame into it and calls
//    ps4_metal_screen_queue_held with the (uncommitted) command buffer. The frame is handed to the
//    presenter, which presents it straight from that texture where it would take a slot;
//    `done(arg, shown)` then runs (on a Metal or dispatch thread) once its image is in the drawable
//    (shown = 1), or when it was dropped (shown = 0): at once after a 1 s timeout, else once the
//    renderer has written it (more frames held than ps4_metal_screen_set_hold_depth allows). While
//    any frame is held (ps4_metal_screen_frames_held), later frames must be held too (or dropped
//    with ps4_metal_screen_note_held_drop), to keep their order.
//    ps4_metal_screen_release_held: the renderer's GPU work was given up (watchdog); every held
//    frame's flip completes without waiting for it.
void *ps4_metal_screen_try_acquire_frame(int width, int height);
int ps4_metal_screen_encode_present(void *command_buffer, void *texture);
typedef void (*ps4_metal_screen_held_done_fn)(void *arg, int shown);
bool ps4_metal_screen_frames_held(void);
void *ps4_metal_screen_hold_texture(int width, int height);
int ps4_metal_screen_queue_held(void *command_buffer, void *texture, ps4_metal_screen_held_done_fn done, void *arg);
void ps4_metal_screen_release_held(void);
// Hold depth from the buffer count of the flipped buffer's set (one sceVideoOutRegisterBuffers
// call; set by sceVideoOutSubmitFlip): min(3, buffers - 1), at least 1, so the guest cannot run
// further ahead of the display than the buffers it flips between allow.
void ps4_metal_screen_set_hold_depth(int display_buffers);
// A frame that had to be dropped because it could not be held behind held frames.
void ps4_metal_screen_note_held_drop(void);
// Statistics: the time a frame waited for a slot (0 when it got one at once); frames put on a
// drawable so far (by the presenter or the CPU present paths), and held frames dropped.
void ps4_metal_screen_note_backpressure(double wait_ms);
uint64_t ps4_metal_screen_presented_count(void);
// No frame is queued for the presenter or being presented (slot or held): every command buffer
// the presenter encoded has completed and given its drawable back.
bool ps4_metal_screen_presenter_idle(void);
// A frame flipped now would get a present slot at once (FIFO: the presenter holds a drawable it
// has not given to a frame yet, and a slot is free); false while the display is behind, i.e. the
// frame would be held. Only reads the state.
bool ps4_metal_screen_slot_ready(void);
uint64_t ps4_metal_screen_held_drop_count(void);
uint64_t ps4_metal_screen_held_count(void);
// Guest flip parameters for the vsync pacing mode: sceVideoOutSetFlipRate (0 = 60 Hz, 1 = 30 Hz,
// 2 = 20 Hz) and the flip mode of the last sceVideoOutSubmitFlip.
void ps4_metal_screen_set_guest_flip_rate(int flip_rate);
void ps4_metal_screen_set_guest_flip_mode(int flip_mode);
void ps4_metal_screen_pump_events(void);
// Output gamma from sceVideoOutAdjustColor (1.0 = plain sRGB).
void ps4_metal_screen_set_gamma(float gamma);
void *ps4_metal_screen_get_device(void);
void *ps4_metal_screen_get_command_queue(void);
void *ps4_metal_screen_get_layer(void);
void *ps4_metal_screen_get_texture(void);
void ps4_metal_screen_destroy(void);
// Debug hooks for exit tests: same paths as the window close button and Cmd+Q.
void ps4_metal_screen_request_close(void);
void ps4_metal_screen_request_terminate(void);

#ifdef __cplusplus
}
#endif

#endif // PS4_METAL_SCREEN_H
