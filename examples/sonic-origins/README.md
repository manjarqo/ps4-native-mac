# Sonic Origins startup chooser

An optional native macOS launcher for an existing Sonic Origins Plus build. It offers Sonic 1, Sonic CD, Sonic 2 and Sonic 3 & Knuckles and selects the corresponding in-game carousel item using screenshots and genuine controller input. It does not bypass game code or start a level directly.

Build the game normally, with ps4_app and guest_image.bin under your project's build directory, then run:

```sh
SONIC_PROJECT_DIR="/path/to/sonic-project" ./examples/sonic-origins/launch.command
```

The helper compiles with installed Apple clang and AppKit. It creates only a local .launcher cache under that project. No game files are included here. Keep the original build resources alongside ps4_app.

Confirm startup notices manually. Once the six carousel dots are visible, the helper navigates to the chosen part and stops; select a mode and character in the game. Left/Right/Back manual clicks disable automatic selection. Failure to recognize the menu or verify a changed dot falls back to manual controls after a bounded retry period. Cancel does not launch a game. Normal startup and --no-menu bypass the chooser. Existing automated runs with pad/capture/headless variables also bypass it. Metal 3 is the default; Metal 4 flickers in this title.

Sonic 2 selection was checked live; the other chooser values and the screenshot classifier were checked separately. Sonic 2/3 gameplay is not established by this launcher test. Recognition assumes the current 1920x1080 Origins menu layout.
