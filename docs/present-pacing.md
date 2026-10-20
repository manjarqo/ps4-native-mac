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
    an even 16.7 ms, at most 60 fps. No CPU sleeps are used. Measured with a visible window: an even 16.7 ms cadence at 60 fps, against 30 % of frames off the 8.3 ms cadence when uncapped.
  - `mailbox`: the renderer never waits for the display. A queued frame that has not got a drawable yet
    is replaced by the newer one and counted as superseded.
- **Back-pressure and latency.** In `uncapped` and `vsync` the presenter first gets a drawable, then
  grants the renderer one credit and takes the next queued slot. The renderer gets a slot only against
  that credit. When the display is behind, it therefore waits in `acquire_frame` at the same point where
  it used to wait in `nextDrawable`, and it is never a frame further ahead than with the old inline path:
  the queue adds no latency (asserted by `present_queue_test`).
  - In `vsync`, the only extra latency is the hold itself.
  - `mailbox` never waits, and its renderer may be up to 2 frames ahead of the drawable.
  - Slots are freed when the presenter's command buffer completes. Acquire times out after 1 s; the
    frame is then dropped and the game keeps running.
  - The wait is counted as `backpressure` and in the encoder's "ms screen".
- **Guest-memory display buffers** (U4 today) are shown when the buffer is not a GPU target. By default
  the encoder commits, waits for the GPU (`WaitAll`), detiles and presents synchronously, as before.
- `PS4_GNM_ASYNC_CPU_PRESENT=1` (opt-in) runs that work on a serial "gnm.cpu-present" queue instead:
  - The read is a fence action (`AfterGpu`), so it runs after the previous frames' flips and this
    frame's EOP and label fences.
  - While such a frame is pending, all flips complete on that queue, in order, and so does the fallback
    path. `present_frame` therefore runs on one thread.
  - The encoder stays at most one frame ahead. Before it queues the next guest-memory frame it waits for
    the previous one, with the GPU watchdog: a timeout runs `WaitAll`, which sets `S.hung` once. So the
    read of buffer N finishes before frame N+1's successors are encoded.
  - `sceGnmInsertWaitFlipDone` is still not a real GPU wait (it needs guest-visible per-buffer labels
    that the CP polls). The one-frame bound is what keeps a later frame from overwriting the buffer being
    read.
  - A GPU-presented frame after a guest-memory frame waits for it, so images are shown in order.
  - CP-thread writes (DMA_DATA, WRITE_DATA) are not ordered against the read. That is one reason the
    path stays opt-in.
- `present_frame` and `present_texture` first drain the presenter queue: up to 1 s, and not at all after
  a timeout, until the presenter is idle again.

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
