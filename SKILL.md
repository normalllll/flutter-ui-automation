---
name: flutter-ui-automation
description: Test and visually inspect Flutter UI on Windows and Android using application-internal controls plus independent window or device screenshots and recordings, without taking over host desktop input. Use for page walkthroughs, component interaction, and Flutter UI verification.
---

# Flutter UI Automation

Control Flutter through its test/Driver connection. Capture Flutter content and
system-presented pixels as separate channels. Inspect actual images before
claiming visual acceptance.

Use the resident Dart MCP for new runs. Read [references/mcp.md](references/mcp.md)
for one-time compilation, MCP registration, the persistent CLI and session
ownership. It embeds the official Flutter/Dart MCP in the same process and
requires no Python. Keep the app session alive while editing source; use hot
reload/restart and continue with affected checks. Native/SDK changes still need
rebuilds. Do not launch a new controller or app for each screenshot.

## Select the platform

- **Windows:** read [references/windows.md](references/windows.md), then
  [references/usage.md](references/usage.md) for independent capture commands, native tool
  setup and integrations. WGC/PrintWindow, HWND/PID checks, non-activation,
  placement, and background foreground simulation belong to Windows only.
- **Android:** read [references/android.md](references/android.md) for mandatory
  device selection, owned/attached sessions, ADB capture and mobile acceptance.
  The Android binding preserves real lifecycle and focus. No iOS backend exists.

Resolve paths from this skill directory. The working fixture stays under
`examples/capture_lab/`; it is not a universal protocol for arbitrary release apps.

## Shared workflow

1. Identify project, target platform, device/app instance and requested checks.
   Reuse existing Dart/Flutter MCP or Driver integration. A missing test extension
   or capture backend is a prerequisite failure. Never substitute global desktop
   input or silently switch devices. Preserve the user's build/launch/capture
   permissions; installing a skill does not authorize a GUI run.
2. Inspect the actual widget/render tree. Use observed keys, text or semantic
   labels, and invoke Flutter's pointer/text-handling path rather than changing
   business state. Keep extensions and simulation in dedicated test entrypoints;
   preserve normal `lib/main.dart`.
3. Wait for the requested target and content. Continuous animations can prevent
   global idle; use bounded target waits or unsynchronized Driver operations.
   The fixture reports `settled`, `settleMs` and pending transient callbacks.
   `settled: false` is not proof of a stable screenshot.
4. Choose the image source deliberately:
   - App screenshots cover Flutter's Navigator, dialogs and overlays, excluding
     native keyboards, system windows and separately composited platform views.
   - Windows window or Android device capture observes system presentation. Match
     an exact per-request visual token in captured pixels when a hook exists;
     `endOfFrame` and API success alone do not establish fresh native presentation.
     Without a token, report `presentationVerified: false` and inspect content.
   - Record bounded intervals, finalize the encoder, decode the resulting video,
     check duration/pacing and changes in the relevant region. Exclude unrelated
     clocks and status markers when testing animation.
5. Inspect original PNGs and videos for the requested screen, text, clipping,
   overlays and rendering errors. Report behavior, app pixels, system pixels and
   real lifecycle evidence separately. Preserve physical-resolution source PNGs
   and any true lossless masters. Android's original screenrecord video is lossy;
   converting it to a lossless codec does not recover original display pixels.
   On Windows, the user may bring the target forward to inspect it. Keep real
   foreground/focus observations, activation counts and recording samples, but
   never reject captures solely because they are nonzero. Those observations
   do not identify who activated the window. Automation must still avoid raising
   or focusing it. Mark background-only checks not assessed when their required
   uninterrupted background interval was not established; restore the latest
   actual platform state, including a focused window.
6. Restore test modes and stop only sessions started for this work, unless the
   user asked to keep them. Retain diagnostic artifacts and failed attempts.
   Required missing capabilities fail acceptance; optional unsupported native UI
   actions remain explicit rather than being counted as tested.

## Implementation boundaries

Retry only the actually failed capture/channel. Retain successful images and
failed-attempt diagnostics; user inspection or one stale frame does not fail an
unrelated batch. Inspect per-item results as well as job completion. Run the
offline fixture verifier only on that fixture. For real networked apps, use
bounded task-relevant navigation and avoid repeated refresh or network stress
unless specifically requested.

- `tools/automation/`: resident Dart MCP, embedded official server, shared Driver
  connection, scoped capture/media, jobs and CLI broker. Current execution path;
  `build.ps1` compiles once and subsequent calls reuse the service.
- `references/mcp.md`: current API, editing loop, retries and ownership rules.

Python remains only for developer repository checks and the independent Windows
window-capture tool. The resident workflow never needs Python:

- `scripts/check_repository.py`: candidate source, metadata and Markdown links.
- `scripts/window_capture.py`, `scripts/media.py`, `tools/window_capture/`:
  standalone HWND/PID capture and verified native lossless media.
- `scripts/test_window_capture.py`: standalone wrapper regressions.
- `tools/automation/test/`: session/device identity, capture failure isolation,
  foreground policy, interruption and real FFmpeg media regressions for MCP.

Current Windows/Android measurements are in
[docs/mcp-validation.md](docs/mcp-validation.md), with scope and historical
boundaries in [docs/validation-status.md](docs/validation-status.md).
Do not treat fixture evidence as verification of another application.
