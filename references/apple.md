# macOS and iOS Simulator

Apple execution requires a Mac with Flutter and Xcode. The same resident MCP
handles sessions, jobs, cancellation, Driver interactions, app screenshots,
hot reload/restart and media checks. The fixture's real-lifecycle binding is
`lib/platform_driver_main.dart`; Windows foreground simulation stays Windows-only.

## macOS

```bash
bash tools/automation/build.sh macos
```

The build creates a Debug fixture and the ad-hoc-signed helper bundle
`tools/macos_capture/build/FlutterUICapture.app`. The helper uses ScreenCaptureKit
and requires macOS 14+ for its screenshot API. Its default executable is inside
`Contents/MacOS/capture`; `MACOS_CAPTURE` can override that path.

Preflight does not display a permission dialog:

```bash
tools/macos_capture/build/FlutterUICapture.app/Contents/MacOS/capture --preflight
```

After the person permits the system prompt, `--authorize` requests Screen
Recording permission. The person may need to approve Flutter UI Capture in
System Settings. An SSH login or logged-in desktop does not grant this permission.
The MCP starts the helper executable directly, so macOS can attribute the
request to the responsible parent (the terminal, `sshd` or agent host app)
instead of Flutter UI Capture; run `--preflight` from that same launch path to
see which grant applies. The bundle is ad-hoc signed, so its code identity
changes on every `build.sh macos` and an earlier grant may need renewal.
Do not edit TCC databases or enable screen sharing automatically. A headless Mac
can still have a usable display session; inspect actual capabilities and pixels.

Use `platform: "macos"` with `automation_session`. The fixture launch builds the
Debug bundle, directly starts its executable as a nonactivating panel and then
uses Flutter attach. Flutter's ordinary macOS `run` path calls `open` to activate
the app, so it is deliberately not used here. Real foreground PID and focus are
observations in native status. Other projects require an explicit existing test
session and attach.

After authorized setup:

```bash
cd tools/automation
dart run bin/check_platform.dart macos
# If native capture permission is unavailable, explicitly limit the check:
dart run bin/check_platform.dart macos --app-only
```

An app-only pass never establishes independent window capture or native visual
acceptance. The current remote Mac has app-workflow evidence; independent
ScreenCaptureKit runtime acceptance remains pending user-granted permission.

## iOS Simulator

```bash
bash tools/automation/build.sh ios
```

Select a dedicated simulator explicitly, boot it using `simctl`, and wait for
`simctl bootstatus <UDID> -b`. Booting through `simctl` does not require opening
Simulator/Device Hub. Do not silently choose another device or reuse somebody's
existing simulator session. Then use:

```json
{"action":"start","platform":"ios","deviceId":"EXPLICIT_SIMULATOR_UDID","sessionId":"ios"}
```

The service checks simulator availability, bundle ID, native PID and kernel birth
time, and binds that PID to the selected simulator's launchd job. VM PID validation
runs before Driver configuration. A fresh start rejects an already running bundle; attach explicitly instead
of replacing it. It rejects physical-device IDs; a physical iOS backend is not implemented.
Native PNGs come from the selected simulator's display. Native recordings sample
and retain those original PNGs, encode FFV1/BGRA and verify decoded frame hashes;
they do not claim a fixed-rate continuous `simctl recordVideo` stream.
The default is one native sample per second; `nativeFps` can request a different
rate, but exceeding actual acquisition capacity fails timing acceptance.
When the simulator's raw framebuffer remains portrait during a landscape scene,
the service preserves the original PNG/video bytes and reports
`rotationToAppDegrees`. Exact-token checks and image comparison apply that rotation
only in memory. `automation_inspect_video` accepts `rotationDegrees` for region
analysis in app coordinates; original frame hashes still cover the unrotated source.

Orientation uses scene geometry requests on iOS 16+; reported lifecycle and focus
remain real. Restore returns to the interface orientation and allowed mask saved
before the first override, and waits for observed restoration before releasing
its cleanup responsibility. Native background/resume checks launch the simulator's Settings app
and resume the fixture, preserving its PID and content. There is no Android back
key on iOS. Text emulation must be disabled when checking the real soft keyboard.

```bash
cd tools/automation
dart run bin/check_platform.dart ios EXPLICIT_SIMULATOR_UDID
```

The caller owns simulator boot/shutdown. Session cleanup stops only the owned
fixture and leaves the simulator available for other explicitly authorized work.
