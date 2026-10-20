# Android implementation and validation evidence

Android support adds an explicit device session adapter, a shared Flutter client,
independent ADB display capture, the Android fixture host, and a mobile verifier.
Windows CLI defaults, capture backends and foreground simulation remain available.

## Verified without a device

- Python protocol/session/capture tests: 30 passing on Windows, including the 16
  existing Windows session/capture checks and 14 Android checks. The Android
  checks cover device lease isolation, attached-session ownership, stale process
  rejection, VM/device token mismatch, binary PNG handling, marker decoding with
  view origin and DPR, stale-token rejection, explicit CLI device selection,
  letterboxed encoded-video probes, source/encoded frame-rate consistency, and
  rejection of interrupted acceptance even when every group has partial evidence.
- Flutter headless tests: 9 passing, including existing Windows binding behavior,
  a mobile binding that preserves actual lifecycle/focus, desktop controls and
  phone layouts at 360×800, 800×360 and 320×568 with keyboard insets and dialogs.

Flutter analysis also passes with no issues; the skill package validator passes.
The extracted Windows acceptance function retains the original syntax tree after
accounting for its new module qualification.

These checks validate contracts and widget behavior, not Android native runtime
or display presentation. See `references/android.md` for the executable commands.

## Android runtime acceptance — 2026-10-19

The final run passed **28 runtime assertions**, all four required groups, and a
separate sampled visual review. See the committed
[public validation summary](validation-status.md) for the publishable record.
The original report, visual review and acceptance summary are retained locally
under `artifacts/android-runtime/` and are not distributed with this repository.
These historical records do not establish current device acceptance after the
subsequent changes listed below.

Configuration: existing Pixel_10_Pro_XL AVD, a task-owned read-only headless
instance on `emulator-5592`, Android 17 / API 37, SwiftShader emulator GPU, and
default Flutter Impeller OpenGLES rendering. No renderer fallback was selected.
The Android debug APK, including Kotlin/Gradle integration, compiled successfully.

Verified behavior includes navigation, gallery clicks/scrolling, Unicode text
handling, actual Android IME visibility and Back dismissal, Flutter modal confirm
and system Back, animation play/pause/reset, overlapping dual-channel recordings,
portrait/landscape screenshots, actual paused/resumed lifecycle and retained
process/business state. Required capture groups include fresh per-request visual
markers. PNG content comparisons exclude system bars and keyboard insets.

Final recording measurements:

| Channel | Measurements | Fidelity evidence |
| --- | --- | --- |
| Flutter content | 1344×2992, 2 fps, 10 frames, encoded duration 5.000 s; capture wall time 5.011 s, zero late frames | Original PNGs and FFV1/BGRA master; all 10 decoded frame hashes match source pixels |
| Android display | Original H.264 source, 720×1280, duration 11.919 s | Presented token verified in decoded video; animation-region changes verified; explicitly lossy |

The native encoder rejected 1344×2992 and used 720×1280 with a centered
574×1280 content rectangle at x=73. The report preserves this projection and the
original 1344×2992 source-display PNG. Full screenshot resolution was retained.

Sampled visual inspection checked keyboard layout, dialog overlay inclusion,
landscape layout and distinct animation poses from both recording channels.
This is not a per-frame or antialiasing audit. The verifier initially leaves
visual review pending; the saved report now links the completed review record,
with the untouched automated result retained beside it.

The fixture stopped normally, its VM connection closed and device lease was
released. The task-owned emulator was then shut down after confirming its process
identity. No Windows GUI regression was run: authorization covered Android only.

## Corrections established by runtime evidence

- Map video probes and animation crops through actual encoder scaling and
  letterboxing instead of using screenshot coordinates directly.
- Make Android PNG sampling configurable (default 2 fps), retaining Windows' 5 fps
  default and strict timing checks. A 5 fps run recorded 6 late frames out of 25.
- Pass the configured rate to both capture and encoding. Visual review caught an
  earlier 5-second capture encoded as a 2-second video; the regression test and
  verifier now assert the actual exported duration. That earlier automated pass
  is superseded, not counted as final acceptance.
- Keep partial evidence on failure and require a completed run before acceptance,
  including when an interruption occurs after all groups have partial evidence.

## Review corrections — 2026-10-20 (not yet re-run on a device)

- Device screenshots and recordings remove their output path and any earlier
  `*.failed-device.*`/presentation frame before capture, so a timeout or failed
  encode no longer leaves an older image or video that looks current.
- A device-capture failure is recorded in `deviceCapture` and the verifier
  continues, so functional, app-capture and lifecycle results stay available;
  acceptance still requires all four groups.
- Covered by unit tests (33 Python tests now pass). The Android runtime acceptance
  above predates these changes and has not been repeated; the Windows regression
  (`verify`, 77 checks) was re-run after them.

Earlier attempts remain under the task workspace's `artifacts/sessions/`, and
reports/diagnostics are copied under `artifacts/android-runtime/attempts/` in the
source package. One shared-emulator attempt recorded a SIGSEGV in libflutter's
raster thread and the shared emulator subsequently disappeared. Causality was
not established; its crash log was preserved. The final isolated instance passed
with the default renderer.

Coverage is established for this fixture and emulator configuration. Physical
phones were not exercised. Permission dialogs, native WebView interaction and
IME composition/candidate selection require separate native automation coverage.
