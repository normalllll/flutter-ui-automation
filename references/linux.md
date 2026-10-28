# Linux X11 and isolated displays

The Linux backend runs the same resident Dart MCP, Driver connection, app PNG
capture and verified FFV1/BGRA recording pipeline as the other platforms. Native
capture is currently X11-only. A Wayland application may expose app content through
Driver, but the X11 helper must not be reported as Wayland presentation evidence.

## Build on Linux

Install Flutter's Linux desktop dependencies, CMake, X11/libpng development
libraries and FFmpeg/FFprobe. Ubuntu package names include `clang`, `cmake`,
`ninja-build`, `pkg-config`, `libgtk-3-dev`, `libx11-dev` and `libpng-dev`.

From the complete repository:

```bash
bash tools/automation/build.sh linux
```

This compiles the resident MCP, `tools/linux_capture/build/capture` and the
fixture's dedicated `lib/platform_driver_main.dart` Debug entrypoint. Set
`LINUX_CAPTURE` only when using a separately installed helper.

## Dedicated runtime verification

After authorization, use a dedicated X server so the fixture does not share the
person's input or focus. A typical Linux host with Xvfb can run:

```bash
cd tools/automation
xvfb-run -a -s '-screen 0 1600x1000x24' env GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 dart run bin/check_platform.dart linux
```

The opt-in check launches the fixture, verifies interactions/captures/media,
changes and restores fixture source to prove hot reload, cancels a recording,
stops the app and checks cold-start presentation fences. It writes evidence into
ignored `artifacts/`. It is not part of the ordinary no-app unit test suite.

WSL needs a Linux Flutter installation and Linux project cache; do not reuse the
Windows SDK or `.dart_tool/` directory through a mounted drive. WSLg can own a
read-only `/tmp/.X11-unix` directory. Preserve those sockets. The recorded WSL
validation used a private mount namespace and private `/tmp` for its Xvfb process
tree, leaving WSLg untouched. Report missing display prerequisites if isolation
cannot be established.

## Capture and identity

Use `platform: "linux"` with the ordinary `automation_session` tools. `DISPLAY`
selects the execution display. The fixture reports the actual X11 window ID,
view bounds, focus and PID. The helper checks `_NET_WM_PID`, visibility and bounds
before reading the window's pixels. The service also checks kernel process birth
time and executable identity before capture, cleanup and recovery.

Original native PNG frames, source hashes and lossless masters remain separate
from MP4 previews. Xvfb acceptance establishes virtual-display rendering; physical
GPU, desktop compositor, IME, occlusion and minimization behavior need their own
retained runtime evidence. No global input automation is used.
