# Windows workflow

Read this for Windows-only window placement, native capture and background
foreground simulation. Use the [resident MCP](mcp.md) for new runs;
the Python CLI remains a legacy regression interface.

## Defaults

- Prefer an existing Dart/Flutter MCP connection exposing widget inspection and
  Flutter Driver commands. Otherwise use a local Driver client over the app's VM
  service. Never default to Computer Use, global input, or foreground activation.
- A missing Driver extension or capture backend is a missing prerequisite. Explain
  it and prepare the appropriate test integration when authorized. Do not silently
  fall back to desktop input or pretend static inspection is a runtime test.
- Preserve the user's execution permissions for dependency installation, builds,
  launches and capture. Authorization to verify one app does not cover others.
- Keep automation extensions and lifecycle simulation in a test entrypoint.
  Preserve the app's normal entrypoint. Do not inject code into unrelated processes.
- For a new test window, establish its initial background Z-order as well as
  non-activation. Prefer an available secondary work area when appropriate;
  account for DPI, negative monitor coordinates and taskbars. Do not raise the
  target to capture it. Reuse the fixture's placement modes when testing it.
- Users may bring the window forward to inspect it during a run. Never force it
  back to the background. Foreground/focus samples and activation counts remain
  observations, not capture-validity gates; they cannot identify the initiator.
  Only run background-specific assertions when their conditions were observed.

## Workflow

1. Identify the target project, platform, app instance and requested checks.
   Inspect existing test harnesses and reuse them. Unit/static checks need no GUI.
2. For interactive verification, obtain the actual widget tree and use stable
   keys, observed text or semantic labels. Do not guess selectors. Click, scroll
   and enter text through Flutter's event handling path rather than directly
   changing business state.
3. Wait for the requested screen and content. Continuous animations can make
   global idle waits hang; use bounded, target-specific waits or disable Driver
   frame synchronization for the operation. Do not treat a fixed delay alone as
   proof that the target page loaded. Before a screenshot, wait (bounded) for
   transient animations to finish; an unsynchronized tap returns after one
   frame, so a route transition or ripple can otherwise be captured midway.
   The fixture capture hook does this and reports `settled`; treat
   `settled: false` as possibly showing motion.
4. Choose the image source by purpose:
   - **App screenshot:** Flutter content/layers, excluding native title bars and
     separate OS windows. Use an existing app capture hook or supported Driver
     screenshot. Place the capture boundary outside the Navigator so dialogs,
     menus and overlays are included. The example uses the actual view's device
     pixel ratio and requests one forced frame when ordinary frames are disabled.
   - **Windows window screenshot:** use the independent native capture helper with the
     exact HWND and PID of the authorized app. Confirm ownership before capture.
     No focus change, desktop-wide capture or window-picker interaction is needed.
     Pass the app's presentation marker with `--probe` or `--probe-json`; without
     one the result is `presentationVerified: false` and the image may be blank
     or stale, so it needs explicit content inspection before acceptance.
   - **Window recording:** stream the selected native backend to FFmpeg. Bound duration and rate,
     finalize the encoder and check that the resulting video decodes and changes.
     Frame count fixes the container duration; check the reported wall-clock
     `elapsedMs` and `lateFrames` instead.
   Prefer the backend verified to produce fresh content for this app. The fixture
   uses WGC with a per-request visual presentation probe. Framework `endOfFrame`
   and native API success alone do not establish that Windows has presented the
   requested page. Wait for the exact probe in the captured HWND pixels, with a
   timeout. Never accept a title bar or a cached previous page as success. See
   [references/capture.md](capture.md) for the fence and image fidelity.
   If the probe times out, retain the original diagnostic frame and environment
   report. A dark display or inaccessible input desktop is relevant evidence,
   not proof of an app defect. Do not wake displays, change power policy or
   activate the window as an automatic recovery; continue app-level checks and
   report native verification as pending when it cannot present fresh content.
5. Inspect captured images. Check the relevant screen, text, clipping, overlays,
   rendering errors and state. Report behavioral assertions separately from
   visual observations. Video-file existence is not evidence of a working video.
   Preserve original PNGs at physical resolution and lossless video masters.
   Use original pixels or unscaled lossless extracts to inspect antialiasing;
   contact sheets and lossy MP4 previews do not establish pixel-level quality.
   For dialogs, wait for the route, click its actual controls, verify callbacks
   and dismissal, and include the overlay in both screenshot channels. For
   animation, verify play/pause/reset and compare its dedicated region over time,
   excluding unrelated clocks or changing text.
6. Restore temporary test modes and close only sessions started for the task,
   unless the user requested that they remain available. Retain artifacts and
   state evidence; distinguish failed attempts from the final passing run.

## Background foreground simulation

Read [references/foreground.md](foreground.md) when the app behaves
differently without focus. First verify its natural background behavior. Enable
simulation only for the relevant test, then disable it and verify restoration.

The example can force Flutter lifecycle `resumed` and framework view focus
`focused`, while preserving the last actual platform events. It also suppresses
startup focus traversal in its test binding and enables it only after the
simulated view-focus notification has been delivered. This does not
make Windows consider the app foreground. Do not claim coverage of native IME,
OS shortcuts, activation-dependent plugins or `GetForegroundWindow()` behavior.

## Included working example and tools

Read [the MCP workflow](mcp.md) for current commands and
[legacy usage](usage.md) for Python regression and independent capture commands.
The runnable fixture is `examples/capture_lab/`.

- `tools/automation/`: current resident MCP, shared Driver sessions and compiled
  persistent CLI for interaction, app/native media and verification.
- `scripts/lab.py`: legacy start/stop, internal interaction, app/window
  screenshots, app/window recordings and the end-to-end verification report.
- `scripts/window_capture.py`: independent HWND + PID screenshot/recording CLI.
- `scripts/media.py`: full-resolution FFV1/BGRA masters, source-frame hashes and
  explicitly labelled MP4 viewing copies.
- `tools/window_capture/`: standalone C++20 PrintWindow / Windows Graphics Capture executable;
  builds with the example or separately with CMake and Visual C++.
- `examples/capture_lab/tool/driver.dart`: Driver CLI using the example's
  additional state/capture hooks. It is not a universal protocol for release apps.

Use absolute paths based on this skill's location; do not assume the current
working directory is the example. Refer to the measured results in
[MCP validation](../docs/mcp-validation.md), without treating those as verification
of a different application.
