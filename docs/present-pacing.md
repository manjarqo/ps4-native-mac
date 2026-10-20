# Present path and frame pacing (Metal screen)

Code: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` (presenter), `ps4_present_queue.[ch]`
(slot queue and pacing policy), `ps4_present_stats.[ch]` (statistics). Host tests:
`tests/host/present_queue_test.c`, `tests/host/present_stats_test.c`.

## What we measured first (TLOU courtyard walk, U4 menu; M1 Pro, 120 Hz ProMotion panel)

- In gameplay, `nextDrawable` on the GNM encoder thread waits 0.04 ms on average and at most 0.1 ms.
  The encoder (about 10 ms per frame) and the GPU are the limits; the display is not.
- In menus and loading screens the game is display-bound at 120 fps. There the encoder spent 5 to 7 ms
  of every frame inside `nextDrawable`.
- Shown frames alternate between 8.3 and 16.7 ms (p50 8.3, p95 16.7). That is the cadence of about
  90 fps on a 120 Hz panel without VRR.
- There were no submission bursts (presents less than 2 ms apart) and no WindowServer growth.
- With `PS4_BACKGROUND_WINDOW` the window is occluded. The compositor then drops almost every drawable
  (`presentedTime` 0), so display-side intervals exist only while the window is visible.

## Design

- **Present thread.** The thread is called "Metal Present", runs at QoS user-interactive and is the only
  GPU-path caller of `nextDrawable`. Before the frame's conversion pass, the renderer (`PresentImpl`)
  acquires one of 3 present slots, a private BGRA8 texture, and renders the display buffer into it.
  `ps4_metal_screen_encode_present` then signals a shared event in the frame's command buffer and queues
  the slot. The presenter waits for that event on the GPU, in a command buffer on its own queue.
  It then copies the slot into the drawable (with MetalFX upscale, gamma and the HUD) and presents it.
  The CPU never waits for the GPU. The flip still completes when the frame's GPU work completes, so the
  flip/EOP order of VideoOut is unchanged. A failed renderer command buffer signals the event from its
  completion handler, so the presenter cannot wait forever.
- **Drawable count.** 3 drawables (one on screen, one waiting for its refresh, one being filled), with
  `displaySyncEnabled` on (no tearing). The thread already removes the wait from the renderer, so 2
  drawables would only add stalls. 4 is not allowed.
- **Pacing (`PS4_PRESENT_MODE`).**
  - `uncapped` (default): every frame is shown at the next refresh. It is chosen by the data: gameplay
    fps is unchanged, and capping lowers it.
  - `vsync`: like the PS4 display engine. Each frame is held on screen for the guest flip interval
    (`sceVideoOutSetFlipRate`: 60, 30 or 20 Hz) with `presentDrawable:afterMinimumDuration:`. The hold is
    half a refresh shorter than the interval, so a slightly late frame does not slip one refresh.
    Immediate (hsync) flips are not held. On a 120 Hz panel this turns the 8.3/16.7 ms alternation into
    an even 16.7 ms, at most 60 fps. No CPU sleeps are used, so no latency is added beyond the hold.
  - `mailbox`: the renderer never waits for the display. A queued frame that has not got a drawable yet
    is replaced by the newer one and counted as superseded.
- **Back-pressure.** In `uncapped` and `vsync` the renderer waits in `acquire_frame` when all 3 slots are
  queued or on screen. That happens only when the display or the GPU falls behind for more than about two
  frames, so latency is bounded at about 3 frames. A slot is freed when the presenter's command buffer
  completes. The wait has a 1 s timeout; after it the frame is dropped and the game keeps running. The
  wait is counted as `backpressure` and in the encoder's "ms screen".
- **CPU present paths** (`present_frame` and `present_texture`, used for guest-memory display buffers)
  first drain the presenter queue (up to 1 s), then present synchronously as before, so frames stay in
  order.

## Screenshots and capture

`screenshot_due()` still runs once per flip, now when the frame is queued, so frame numbering does not
change. A frame that carries a screenshot is marked keep, and mailbox never replaces it. The presenter
copies the same image as before into the capture texture: post-MetalFX, before gamma and the HUD. The
PNG is saved from the completion handler. `save_screenshot` is unchanged.

## Statistics

The presenter prints one `[metal-screen] present:` line every 600 frames with these fields:

- intervals between real `presentedTime` values (p50, p95, p99, max; counts over 33, 50 and 100 ms;
  counts under 6 ms);
- dropped and superseded frames;
- `nextDrawable` wait (average, max, number over 4 ms and over 16 ms);
- renderer back-pressure;
- submission bursts.
