---
name: flutter-ui-automation
description: Test and visually inspect Flutter UI on Windows and Android using application-internal controls plus independent window or device screenshots and recordings, without taking over host desktop input. Use for page walkthroughs, component interaction, and Flutter UI verification.
---

# Flutter UI Automation

Control Flutter through its test/Driver connection. Capture Flutter content and
system-presented pixels as separate channels. Inspect actual images before
claiming visual acceptance.

## Select the platform

- **Windows:** read [references/windows.md](references/windows.md), then
  [references/usage.md](references/usage.md) for existing commands, native tool
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
6. Restore test modes and stop only sessions started for this work, unless the
   user asked to keep them. Retain diagnostic artifacts and failed attempts.
   Required missing capabilities fail acceptance; optional unsupported native UI
   actions remain explicit rather than being counted as tested.

## Implementation boundaries

- `scripts/lab.py` / `lab_cli.py`: public CLI and platform routing. Default remains
  Windows; Android requires `--platform android --device ACTUAL_SERIAL`.
- `scripts/flutter_client.py`: common Driver interaction, app screenshots and
  PNG-source app recordings. Custom fixture hooks are advertised in `state`.
- `scripts/sessions.py` / `host_process.py`: device session paths, launch leases
  and host supervisor identity. Windows retains legacy session compatibility.
- `scripts/windows_platform.py`, `window_capture.py`, `tools/window_capture/`:
  Windows lifecycle and independent native capture.
- `scripts/android_platform.py` / `android_device.py`: Android fixture sessions
  and scoped ADB display capture. Native system UI automation is separate.
- `scripts/verify_windows.py`, `verify_scenarios.py`, `verify_android.py`: platform
  acceptance and reports; static checks do not establish runtime/visual coverage.

Measured Windows results are in [docs/validation.md](docs/validation.md), and
Android evidence in [docs/android-validation.md](docs/android-validation.md).
Do not treat fixture evidence as verification of another application.
