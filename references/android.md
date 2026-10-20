# Android device automation

Read this for Android sessions, capture and acceptance. The working fixture is
`examples/capture_lab/`, package `dev.flutter.flutter_capture_lab`. Its Android
test entrypoint is `lib/android_driver_main.dart`; normal `lib/main.dart` does not
enable Driver. Mobile uses `DriverBinding`, which preserves actual lifecycle and
focus. `AutomationBinding` and foreground simulation remain Windows-specific.

## Prerequisites and execution

Use an installed Flutter Android toolchain, Android SDK/JDK, Python 3.11+, FFmpeg and
FFprobe. Resolve ADB from `ADB` (absolute executable), PATH, `ANDROID_SDK_ROOT`, or
`ANDROID_HOME`. Device debugging/trust must already be configured. Do not install
SDKs, boot emulators, build or launch without the user's applicable authorization.
Prefer an existing dedicated device, or a separately authorized headless emulator
(`emulator -avd NAME -no-window`). The CLI does not boot or wipe devices.

From the skill root, replacing `python` and the device ID with actual values:

```powershell
python scripts/lab.py --platform android devices
python scripts/lab.py --platform android --device emulator-5554 build
python scripts/lab.py --platform android --device emulator-5554 start
python scripts/lab.py --platform android --device emulator-5554 state
python scripts/lab.py --platform android --device emulator-5554 drive tap nav-gallery
python scripts/lab.py --platform android --device emulator-5554 drive scroll gallery-scroll -350
python scripts/lab.py --platform android --device emulator-5554 drive tap nav-interaction
python scripts/lab.py --platform android --device emulator-5554 drive text-emulation on
python scripts/lab.py --platform android --device emulator-5554 drive tap input-field
python scripts/lab.py --platform android --device emulator-5554 drive text "Android / 测试输入"
python scripts/lab.py --platform android --device emulator-5554 app-shot artifacts/android-app.png
python scripts/lab.py --platform android --device emulator-5554 device-shot artifacts/android-device.png
python scripts/lab.py --platform android --device emulator-5554 app-record artifacts/android-app.mp4 5
python scripts/lab.py --platform android --device emulator-5554 device-record artifacts/android-device.mp4 8
python scripts/lab.py --platform android --device emulator-5554 rotate landscape
python scripts/lab.py --platform android --device emulator-5554 rotate restore
python scripts/lab.py --platform android --device emulator-5554 background
python scripts/lab.py --platform android --device emulator-5554 resume
python scripts/lab.py --platform android --device emulator-5554 verify
python scripts/lab.py --platform android --device emulator-5554 stop
```

Device IDs are mandatory, including when exactly one device is connected. All ADB
calls include `-s`. `background` and `back` send device key events; they affect the
selected device's visible UI, never the host desktop. They require the fixture to
be resumed. `resume` launches only its resolved launcher component. Rotation uses
the fixture Activity's orientation request and restores its previous value; it
does not modify the device's global auto-rotate settings. Large-screen Android
policies can refuse orientation requests; the verifier reports a metrics timeout.

`drive reveal KEY` scrolls a known control into view before interacting with it.
Observe selectors via the tree/state; preserve the application's actual callbacks.

## Sessions and ownership

Sessions live under `artifacts/sessions/android-DEVICE_HASH-NAME/`. Use
`--session NAME` on every command for a non-default name. Different devices have
independent sessions; named sessions for one device share a lease because the
fixture package has a single running instance. Windows keeps its legacy default
session and command syntax.

`start` runs Flutter's machine protocol in an owned supervisor. It consumes the
reported host-reachable **wsUri**, retaining Flutter's port-forwarding lifetime.
The event's `baseUri` is not a VM endpoint. Session writes are atomic. Logs and
stop requests are session-specific; a lost/offline device is an error, not an
invitation to select another device.

For an already-running debug fixture with its Driver extension enabled:

```powershell
python scripts/lab.py --platform android --device emulator-5554 --vm-uri ws://127.0.0.1:PORT/TOKEN/ws attach
```

Use an actual reachable URL; retain any forwarding process that provided it.
Attachment validates a per-process instance token through the VM and that
device's `run-as` fixture file. An attached session is not owned: `stop` detaches
without terminating its app or forwarding. Owned shutdown uses Flutter `app.stop`.
Stale recovery force-stops the fixture only when PID and `/proc/PID/stat` start
ticks still match the recorded process. When identity cannot be proven, the
session and lease remain for explicit cleanup; no unrelated/restarted app is
stopped. Run `stop` for the same session before starting again after a failed
launch. Do not remove its lease while its supervisor is alive.

## Two capture channels

- **App:** Flutter `RepaintBoundary` outside Navigator; excludes native keyboard,
  system bars and native/platform views. PNG source frames and FFV1/BGRA masters
  preserve the app-content pixels. The report checks decoded hashes and timing.
  Android defaults to 2 PNG samples/second to retain full device resolution with
  bounded VM transfer overhead. Set `--fps 1..15` on Android `app-record` or
  `verify` when a different rate is required; the selected rate and late frames
  remain explicit. Windows retains its existing 5 fps default. This sampling rate
  does not change the native screenrecord encoder's frame rate.
- **Device:** ADB binary `exec-out screencap -p`, or time-limited `screenrecord`.
  Capture verifies the specified package is resumed before/after acquisition.
  This is the selected device display, including its keyboard/system bars,
  rather than an app-only capture. Do not use a personal device outside the
  authorized scope.

Fixture device captures require a newly painted 32-cell presentation token.
Logical marker coordinates are mapped through actual view origin and DPR to
display pixels. Screenshots are decoded and checked; recording validates the
token in decoded early video frames. Without an instrumented probe, the
independent CLI explicitly reports `presentationVerified: false`.

An encoder may fall back to a smaller video with centered letterboxing. The
recorder retains a source-display PNG and maps marker/animation coordinates into
the actual encoded content rectangle. The projection follows Android's
[screenrecord implementation](https://android.googlesource.com/platform/frameworks/av/+/master/cmds/screenrecord/screenrecord.cpp).
Reports retain the source size, encoded size and display projection; reduced
video resolution is explicit. PNG comparisons crop to the Flutter content area,
excluding system insets and the native keyboard.

```powershell
python scripts/android_device.py screenshot --device emulator-5554 --package dev.flutter.flutter_capture_lab --output artifacts/device.png
python scripts/android_device.py record --device emulator-5554 --package dev.flutter.flutter_capture_lab --output artifacts/device.mp4 --seconds 8
```

The screenshot CLI accepts `--probe-json FILE` with the fixture's complete
`prepareCapture` response, including `native.viewBounds`. Raw PNG bytes never pass
through text-mode PowerShell redirection. Presentation timeouts retain the original
diagnostic PNG. Failed recording decoding/presentation retains the original video
when it was retrieved. Logs retain the unique remote recording path; a device
disconnect can leave that one temporary file on the device. Each capture first
removes its output path and any earlier `*.failed-device.*` or presentation frame,
so a failed run never leaves an older image or video that looks current.

Android `screenrecord` output is an original **lossy encoded source**, not an FFV1
pixel master. No transcoding can recover pre-encoding pixels. Keep orientation
fixed throughout a recording. Both screenshot/record durations are bounded;
recording start waits for its own output, and stop waits for encoder finalization.

## Mobile acceptance

`verify` runs against the fixture. It reuses an existing selected session or
starts one; it stops only a session it started. It restores Activity orientation
and native text input. Reports and failed attempts stay in the session directory.

Required groups are `functional`, `appCapture`, `deviceCapture`, and `lifecycle`.
Missing hooks/recorders and interrupted runs do not pass. A device-capture failure
(no presented marker, screencap or screenrecord error) is recorded in the
`deviceCapture` group and the run continues, so the other groups' results remain
available; `passed` still requires all four. Checks cover navigation,
scrolling, Unicode text handling, actual keyboard/inset visibility and Back
dismissal, modal confirm/system Back, animation play/pause/reset, overlapping app
and device recordings, decoded animation-region changes, portrait/landscape
metrics, and actual background/resume with process/state retention. App/device
PNG pairs compare the Flutter content area separately from system bars.

Driver text emulation verifies Flutter's text-handling path. The keyboard check
turns it off and observes the actual Android IME; it does not establish native
IME composition/candidate selection. System permission dialogs, notification
interaction and native WebViews remain unsupported without a separate native
automation backend (for example a deliberately integrated Patrol harness).

Inspect original screenshots and decoded video before claiming visual acceptance.
`report.passed` covers the executable assertions; `visualInspection` remains
pending until the images have actually been reviewed. Existing Windows evidence
does not validate Android; see `docs/android-validation.md` for current evidence.
