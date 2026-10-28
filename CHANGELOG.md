# Changelog

## 0.2.0 — unreleased

- Remove an app-specific Debug harness and the executable launch path; other
  apps attach to their own Debug test entrypoint.
- Replace the 32-cell presentation strip with an 8×4 pink/aqua dot matrix.
  Decoders sample a 3×3 neighbourhood per cell and calibrate both colours from
  the header, tolerating uniform shifts while rejecting other palettes.
- Release the presentation probe when a capture or recording ends (`hold` /
  `releaseCapture`) instead of holding it for a fixed interval; it now sits in
  the fixture's top-right header area.
- Discard one warm-up app screenshot before timed app recordings, so one-off
  first-frame preparation no longer fails acquisition timing.
- Restyle the fixture as a dark instrument panel with flat large surfaces
  (cheap on-device PNG encoding) and keep every automation key and text.

- A second MCP client on the same artifacts root forwards automation tools to the
  resident service instead of exiting before the MCP handshake.
- Report real capture errors from the cold-start fence and never-presented checks
  instead of treating any early failure as a fence result.
- Reject raw `request`/`driver` calls that change tracked reversible modes; the
  fixture now starts with Driver text emulation off, matching restore behavior.
- Treat a recycled native PID as an exited app so stop releases its lease without
  touching the replacement; force-terminate only a verified owned Windows app
  that ignores close. Guard failed-start rollback so the lease is always released.
- Close start/stop races: recordings block stop from enqueue, cancelled starts
  publish no session, and two sessions cannot share one VM endpoint.
- Honor cancellation in Android screenrecord and accept static-screen recordings
  with an explicit `timingBasis`; drain Windows executable output before closing.
- Report missing `FFMPEG`/`FFPROBE`/`ADB` overrides, coded process timeouts,
  structured Windows `stale_presentation`, and clear stale Unix diagnostics.

- Add Linux X11, macOS and iOS Simulator adapters with kernel process-instance
  checks, owned cleanup/recovery and shared real-lifecycle fixture entrypoints.
- Add scoped X11 and ScreenCaptureKit helpers, explicit iOS Simulator selection,
  mobile keyboard/orientation/lifecycle checks and original-frame PNG recordings.
- Preserve raw simulator frame orientation while applying declared coordinate
  transforms for exact presentation markers, image comparisons and video analysis.
- Add native-host runtime acceptance, source hot reload, cancellation/cold-start
  checks, SSH stdio setup and Linux/macOS CI build coverage. macOS independent
  capture still requires user-granted permission and retained runtime acceptance.

- Retire the Python Flutter runtime and per-command Dart Driver entrypoints;
  migrate session/device/capture/media/acceptance regressions to the resident
  Dart implementation. Retain repository checks and independent HWND capture.
- Declare minimum Flutter 3.44.0 / Dart 3.12.0, follow stable SDKs in CI, and enable
  Windows Git long paths before the SDK checkout. Include SDK release tags for
  version detection and bound noninteractive FFmpeg package preparation.
- Resident Dart MCP embedding the official Dart/Flutter server, with persistent
  Driver sessions, an authenticated CLI broker, jobs and cancellation.
- Shared Windows/Android interaction, capture, recording and verification tools;
  source hot reload/restart, explicit target identity and owned-session recovery.
- Per-channel capture evidence, integer Windows native frame rates, independent
  Android keyboard checks, and strict lease/attach ownership validation.
- Logical-display panel selection for foldable Android capture.
- Foreground/focus observations remain separate from capture acceptance;
  background-only checks require an established background interval.
- Linux/Windows headless CI, compiled MCP startup without SDK environment hints,
  and consolidated current workflow/validation documentation.

## 0.1.0 — unreleased

- Windows Flutter Driver interactions, app PNG capture and independent scoped
  WGC/PrintWindow capture with optional presentation verification.
- Original frame retention, FFV1/BGRA master verification and MP4 viewing copies.
- Android fixture sessions with explicit device selection, identity validation,
  ADB display capture and real lifecycle checks.
- Shared agent skill, platform integration references and historical validation
  notes, including the limitations of device encoding and display-off capture.
- Public repository metadata, GPL-3.0-or-later licensing, contributor/security
  guidance, repository checks and GitHub Actions CI.

This initial source snapshot used the Python CLI. The resident MCP is introduced
in 0.2.0; no hosted service is included.
