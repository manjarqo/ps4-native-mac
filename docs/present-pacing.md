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
  that credit. When the display is behind, no thread waits for it (see "No waiting on the display"
  below). The frame is held and its flip completes when the display takes it. The renderer is therefore
  never a frame further ahead than with the old inline path: the queue adds no latency (asserted by
  `present_queue_test`).
  - In `vsync`, the only extra latency is the hold itself.
  - `mailbox` never holds a frame, and its renderer may be up to 2 frames ahead of the drawable.
  - Slots are freed when the presenter's command buffer completes. A held frame that the display has
    not taken within 1 s is dropped (`[metal-screen] held frame dropped`) and its flip completes at once,
    without waiting for its conversion on the GPU. That only happens when the display stops taking
    frames (the presenter thread or the GPU no longer frees drawables); the game keeps running.
  - When the GPU watchdog gives the renderer up (`PS4_GNM_GPU_TIMEOUT`), the held frames' conversions
    never finish. `ps4_metal_screen_release_held` then signals their event on the CPU, so a held frame
    the presenter already waits for is shown (with whatever its texture holds) and the queued ones are
    dropped. All their flips complete, in order, and so do the flips behind them. It signals the slot
    frames' event the same way, so the presenter's command buffers for hung slot frames complete and
    give their drawables back, and later frames (presented on the CPU) still reach the screen.
  - The time a frame was held is counted as `backpressure`. Frames held are counted as `held`, and the
    held frames that had to be dropped as `held-dropped`, separately from mailbox `superseded` frames.
- **No waiting on the display.** On the PS4, `sceGnmSubmitAndFlipCommandBuffers` and `sceVideoOutSubmitFlip`
  only enqueue the flip. The display engine takes the buffer at a later vblank and the flip completes then
  (flip status, flip event); games pace themselves on those.
  - The renderer used to wait in `acquire_frame` for a slot instead. With `PS4_GNM_SYNC_ENCODE` that wait
    ran on the guest's submitting thread after the frame was on the GPU. The frame's EOP labels and
    interrupts then fired while the guest was still inside SubmitAndFlip. Uncharted 4 recycled memory that
    its submit thread reads right after the call returns, and crashed (`u4_research/crash_0x1ceb9d0.md`).
  - Now `PresentImpl` asks for a slot with `ps4_metal_screen_try_acquire_frame`, which never waits. If none
    is free, or frames before this one are still held, it converts the frame into a held texture from
    the Metal screen (`ps4_metal_screen_hold_texture`). It then queues the frame with
    `ps4_metal_screen_queue_held`; its command buffer signals a shared event once the frame is written.
  - The presenter shows a held frame straight from its texture, with no copy and no extra hop: when it
    has a drawable and no slot frame is ahead (a slot that is being rendered or is queued was acquired
    before any frame was held, so it is older), it takes the oldest held frame instead of a slot. Its
    command buffer waits on the GPU for the frame's event and presents it like a slot. So a held frame
    reaches the screen at the same drawable, and the same refresh, as a slot frame would; nothing runs
    on the renderer's command stream or under the CP lock for it.
  - The flip of a held frame completes when the presenter's command buffer for it completes, so it is
    not delayed behind later frames' GPU work.
  - Flips complete in the order of their `Present` calls (`CompleteFlip`, a per-frame sequence). A
    later frame that is shown directly waits there for the held ones before it.
  - While frames are held, a frame that cannot get a held texture (none free) is dropped and its flip
    completes in order. It is never presented directly, which would put it on screen ahead of the
    frames held before it.
  - Relative to the display, the flip completes at the same point as before, so `uncapped`, `vsync` and
    the guest flip rate pace as before. The difference is that the guest waits in its own flip wait, not
    inside the submit call, and the encoder thread never waits for the display either.
  - **Flip labels.** One of the flip waits is on the GPU: `sceGnmInsertWaitFlipDone` puts a `WAIT_REG_MEM`
    in the command buffer that waits for the VideoOut flip label of a display buffer to be 0
    (`sceVideoOutGetBufferLabelAddress`: one 64-bit label per buffer index, in guest memory). The GPU
    flips (`sceGnmSubmitAndFlipCommandBuffers`, `sceGnmRequestFlipAndSubmitDone`) set their buffer's
    label to 1 when the command processor reaches the flip, and each completed flip clears the label of
    the buffer flipped before it: a buffer's label is cleared when the next flip completes, as in
    shadPS4's driver (`VideoOutDriver::Flip` clears `prev_index`'s label). The
    graphics queue stays suspended at such a wait until the flip completes; it gives the wait up only
    after 2 s (other waits: 50 ms), which no flip reaches (a held frame is dropped after 1 s); a
    give-up is logged (`flip-label wait given up`, handle, buffer, last flipped buffer). A completed
    flip that clears a label wakes the command processor's wait thread at once (a condition variable
    with a 1 ms timeout, without the command-processor lock). The `[gnm-draw] perf:` line counts
    flip-label waits per 300 presents (given up, woken) and in total. A game
    that paces itself this way (inFAMOUS Second Son: the wait, and `sceVideoOutIsFlipPending` on the
    CPU) therefore runs at the display's rate. Before, the packet waited on register 0 and passed at
    once, and such a game flipped as fast as it could submit, its held frames dropped one after another.
  - **Hold depth.** At most `min(3, display buffers - 1)` frames are held, counting the buffers of the
    flipped buffer's set (the buffers one `sceVideoOutRegisterBuffers` call registered; the call returns
    the set index, at most 4 sets, and the system library's `SCE_VIDEO_OUT_ERROR_*` codes on bad
    arguments, as listed in `ps4_videoout.h`). A game cannot run further ahead of the display than the buffers it flips between
    allow: with double buffering only 1 frame is held. A game that flips faster than the
    display and never waits for its flips has its oldest held frame dropped once that many are held, and
    a free texture takes the new frame at once. Before, the submit call (sync encode) or the encoder
    thread (async) waited instead.
  - Tested by `tests/host/gnm_submit_flip_nonblocking_test.mm` (both encode modes), which runs the whole
    runtime with the display held behind: call time, encoder drain, held frames shown within 500 ms of
    the display catching up and not before, the 1 s drop, the hold depth with 2 and with 4 display
    buffers and flip order, a CPU-written display buffer, and held and slot frames whose conversions hang
    on the GPU (dropped by the timeout, or released when the watchdog gives the renderer up, with the
    presenter idle again and later frames presented). The frames after a hung held frame are flipped
    only once the presenter has a drawable for them (`ps4_metal_screen_slot_ready`): how many drawables
    the system keeps for the display depends on the window (an occluded window's are returned on the
    system's own schedule), so 1 or 2 slot frames hang there, and the test reports how many. The GPU stall it uses
    (`ps4_gnm_metal_debug_stall_gpu`) only works in a process started with `PS4_TEST_HOOKS=1`; the
    `nohooks` mode checks that it refuses otherwise. The test ends the stall at its end
    (`ps4_gnm_metal_debug_release_gpu`), so the hung command buffers complete and the exit does not wait for
    the system's GPU timeout.
- **Display buffers that are not GPU targets** are copied from guest memory on the GPU, in the renderer's
  stream behind the frame's work (`GuestDisplayTexture`: an image resource over the buffer with the
  VideoOut format, a compute detile for tiled buffers, then a blit). They are then presented like a render
  target, held or not. Nothing waits for the GPU.
  - Such buffers are written by the CPU, or by compute shaders through guest memory, and the copy runs
    after both: CPU writes come before the submit, and GPU writes come earlier in the stream.
  - Only if the copy cannot be encoded does the CPU read the buffer after `WaitAll` (logged as
    `present-guest`), as did the renderer-less fallback.
  - The opt-in `PS4_GNM_ASYNC_CPU_PRESENT` queue is gone.
- `present_frame` and `present_texture` (the paths without the renderer) first drain the presenter queue:
  up to 1 s, and not at all after a timeout, until the presenter is idle again.

## Screenshots and capture

`screenshot_due()` still runs once per flip, now when the frame is queued, so frame numbering does not
change. A frame that carries a screenshot is marked keep, and mailbox never replaces it. The presenter
copies the same image as before into the capture texture: post-MetalFX, before gamma and the HUD. The
PNG is encoded and written on a background queue ("ps4.screenshot"). Before, this happened in the
frame's completion handler, ahead of the handler that frees its present slot, so every saved frame held
the display (and with it the renderer) for 30-70 ms. At most 4 images wait for the writer. A frame due
while it is that far behind is not saved and is logged, so a slow disk cannot grow memory without limit.
The CPU present paths copy the screen texture's bytes first (it is reused), then queue the encode.

## Statistics

The presenter prints one `[metal-screen] present:` line every 600 frames with these fields:

- intervals between real `presentedTime` values (p50, p95, p99, max; counts over 33, 50 and 100 ms;
  counts under 6 ms);
- a histogram of those intervals (`hist`: counts up to 10, 14, 20, 27, 33.4, 50 and 100 ms, and over
  100 ms; on a 120 Hz panel 1, 2, 3 and 4 refreshes fall into separate buckets);
- dropped, superseded, held and held-dropped frames;
- `nextDrawable` wait (average, max, number over 4 ms and over 16 ms);
- renderer back-pressure;
- submission bursts.
