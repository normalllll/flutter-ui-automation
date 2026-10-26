# Android device automation

Use [the resident Dart MCP](mcp.md) for Android sessions, Driver interaction,
app/native capture, hot reload/restart and verification. There is no Python
Android runtime. Minimum supported toolchains are Flutter 3.44.0 and Dart 3.12.0;
newer releases are permitted, with no custom version-number startup gate.

## Device and application identity

Use an installed Flutter Android toolchain, Android SDK/JDK, ADB and FFmpeg/FFprobe
for video. An explicitly authorized device ID is mandatory. The service never
silently selects another device or boots an emulator.

Call `automation_environment` to inspect available IDs, then `automation_session`:

```json
{"action":"start","platform":"android","deviceId":"ACTUAL_SERIAL","sessionId":"phone"}
```

The offline fixture is `examples/capture_lab/`, package
`dev.flutter.flutter_capture_lab`, entrypoint `lib/android_driver_main.dart`.
Normal `lib/main.dart` has no Driver extension. Build through `automation_build`
or `tools/automation/build.ps1 -Fixture android` before a new fixture launch.
Start/build/record/verify return jobs by default; use `automation_jobs` to wait
and inspect the actual nested result and per-item `passed` values.

Session identity checks package, PID, process start time and an app-instance token
read through `run-as`. A VM from another device or a replaced process is rejected.
Device/package leases prevent competing session names from owning the same target.
Attached apps remain running when their session stops. Recovery and cleanup must
not release another supervisor's lease or stop a replacement instance.

## Drive and capture

Inspect `automation_drive` with `action: tree`, then use observed selectors:

```json
{"sessionId":"phone","action":"tap","selector":{"kind":"key","value":"nav-interaction"}}
```

For Unicode injection, explicitly enable `textEmulation`, tap the field and call
`enterText`. Unfocus and disable emulation before testing the real IME. `back`,
`background`, `resume` and `orientation` use only the selected device/app; real
mobile lifecycle and focus remain observable. Windows foreground simulation is
not an Android capability. Orientation `restore` restores the Activity's original
request instead of changing global device settings.

`automation_capture` keeps app PNGs and native device PNGs as separate channels.
App images cover Flutter's Navigator and overlays; device images include system
bars, keyboard and other system presentation. The fixture compares content using
actual native view bounds, DPR and system insets. Original screenshots remain at
physical resolution.

Logical display 0 is resolved to its current physical panel with `dumpsys display`.
Both `screencap -d` and `screenrecord --display-id` use that panel, avoiding Fold
multi-display warnings in the PNG stream. Metadata retains the panel ID. A panel
switch fails that acquisition and retains the diagnostic; unrelated successful
captures remain valid. Unresolved display geometry is a prerequisite failure.

## Recordings and acceptance

App recording defaults to 2 fps and retains original PNGs, source hashes and a
verified FFV1/BGRA master. Native screenrecord retains its original **lossy** MP4;
codec fallback may lower resolution. Reports retain the actual display projection,
encoded duration and acquisition/finalization timing. A conversion cannot recover
a lossless original display master.

The fixture verifier checks navigation, callbacks, gallery scroll, Unicode,
native keyboard visibility/Back dismissal, modal confirm/dismiss, animation pixels,
rotation and lifecycle retention. `checks` supports targeted reruns; the keyboard
group establishes its own input-page state. Interrupted runs retain partial
reports with `completed: false` and `passed: false` even if all recorded items
passed before cancellation. A native failure retains app evidence and does not
prevent later functional checks.

Inspect original screenshots and decoded video before claiming visual acceptance.
Executable assertions do not replace visual review. Permission dialogs, native
WebView interaction and IME composition/candidate selection require a separate
native automation integration. Current device evidence and historical emulator
limits are in [validation status](../docs/validation-status.md) and
[MCP validation](../docs/mcp-validation.md).
