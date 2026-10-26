# Flutter UI Automation

Automate Flutter UI interactions, screenshots and recordings on **Windows and
Android**, without taking over the host's mouse, keyboard or foreground window.

This repository contains an agent skill, a resident Dart MCP, an independent
Windows capture helper and a Flutter reference fixture. Maintained by
[normalllll](https://github.com/normalllll), licensed under **GPL-3.0-or-later**.

The current runtime is `tools/automation/`: one resident service embeds the
official Dart/Flutter MCP and keeps Driver connections and app sessions alive.
Python is required only for developer repository checks and the retained legacy
regression tools. Other apps need their own Debug Driver/test hooks; the fixture
is not a universal protocol for arbitrary release applications.

| Platform | Control and content | System presentation | Boundary |
| --- | --- | --- | --- |
| Windows | Flutter Driver, app PNGs and recordings | Scoped HWND/PID WGC or PrintWindow | Interactive desktop; display-off reliability unresolved |
| Android | Flutter Driver, app PNGs and recordings | Explicit-device ADB screenshots and lossy screenrecord | Physical USB Fold and emulator evidence; native system UI automation is separate |
| iOS / other desktops | No bundled backend | No bundled backend | Unsupported |

Start with [installation](docs/installation.md), the
[MCP workflow](references/mcp.md) and [current validation](docs/validation-status.md).
Platform details: [Windows](references/windows.md), [Android](references/android.md).

## Capabilities

- Inspect widget trees and use observed selectors for navigation, clicks, scroll,
  Unicode text input and framework keyboard events.
- Verify dialogs, modal barriers, callback results and real animation pixels.
- Capture original app PNGs at view DPI, including Navigator overlays, alongside
  independent Windows window or Android display captures.
- Require an exact per-request visual token for native presentation acceptance;
  preserve rejected frames and per-channel failures for targeted retries.
- Retain original PNG frames and verified FFV1/BGRA masters for app and Windows
  recordings, with separate MP4 previews. Android screenrecord remains lossy.
- Hot reload/restart without replacing the native app process. Run bounded jobs,
  cancel individual recordings and recover owned sessions after a service crash.
- Preserve actual lifecycle/focus observations. Windows framework foreground
  simulation is explicit and reversible; Android uses real mobile lifecycle.

## Prepare the service

Use Flutter's Dart **3.13+**. FFmpeg/FFprobe are required for video. Windows builds
need the Visual C++/Windows SDK toolchain and Android needs its Flutter/ADB
prerequisites. The fixture and CI pin is **Flutter 3.47.6 / Dart 3.13.5**; local
resident-runtime evidence used **Flutter 3.47.8 / Dart 3.13.7**.

Clone or install the complete repository. From its root on Windows:

```powershell
./tools/automation/build.ps1 -FlutterRoot C:/path/to/flutter -Fixture windows
# For Android, select -Fixture android instead.
```

Register the compiled executable using
[the MCP configuration example](tools/automation/mcp.example.json) and the
[setup instructions](references/mcp.md#one-time-preparation). The service embeds
the official server, so register this single MCP for the workflow. It derives
both SDK paths from the selected Flutter installation; `DART_ROOT` and `DART_SDK`
are not required.

When using the persistent CLI instead of an MCP client, start the service once:

```powershell
./tools/automation/build/automation.exe --root . serve
```

Subsequent compiled `call` commands reuse that process. See
[CLI calls and ownership](references/mcp.md#sessions-recovery-and-cli).
Builds, launches and captures retain the user's existing authorization; installing
this package alone does not authorize them.

## Windows quick start

Call `automation_environment` to inspect prerequisites, then start the fixture
with `automation_session`:

```json
{"action":"start","platform":"windows","sessionId":"win"}
```

Long operations return jobs by default. Wait with `automation_jobs` and inspect
the completed job's actual result. Read the widget tree using `automation_drive`:

```json
{"sessionId":"win","action":"tree"}
```

Use observed keys or text for interactions. Capture both channels with
`automation_capture`:

```json
{"sessionId":"win","label":"overview","includeImages":true}
```

Inspect each item's `passed` field and the actual original images. For an offline
fixture walkthrough, use `automation_verify`; for an integrated network app, use
bounded task-relevant checks. Stop an owned session with `automation_session`:

```json
{"action":"stop","sessionId":"win"}
```

Windows launches use the nonactivating test runner. Users may bring the window
forward to inspect it. Foreground/focus and activation counts remain observations;
background-only checks are `not_assessed` when their conditions were interrupted.
The automation never raises the window or forces it back behind other windows.

## Android quick start

Use an explicitly authorized device ID from `automation_environment`:

```json
{"action":"start","platform":"android","deviceId":"ACTUAL_SERIAL","sessionId":"phone"}
```

Drive, capture and stop it using the same tools with `sessionId: "phone"`.
The service validates the device, package, process and fixture instance; it does
not silently choose another device or boot an emulator. See
[Android integration and lifecycle](references/android.md).

Enable Driver text emulation explicitly for Unicode injection, then restore it
before testing the real IME. Device screenshots include system UI; app screenshots
cover Flutter content. Screenrecord retains its original lossy source and actual
display projection rather than claiming a lossless display master.

## Evidence and integration

Original media, logs and session metadata live under ignored `artifacts/` and are
not published. Retry a failed capture channel without repeating successful ones.
Inspect original PNGs or unscaled lossless extracts for text and antialiasing;
MP4 previews and contact sheets are for browsing.

Read [capture fidelity and diagnostics](references/capture.md) for visual tokens,
blank/stale frame rejection, timing and display-state evidence, and
[foreground simulation](references/foreground.md) for the framework boundary.

Keep test hooks in a separate Debug entrypoint and preserve the app's production
entrypoint. The [MCP integration guide](references/mcp.md#integrating-an-app)
describes the required hooks, existing BooruFlow Windows harness and isolated
Android staging integration. Native runner/plugin changes still require rebuilds.
Native IME composition, OS dialogs and system hotkeys require separate checks.

## Agent installation

Install or link this **entire directory**, including tools and references:

- **Codex:** install as `flutter-ui-automation` and invoke
  `$flutter-ui-automation`. `agents/openai.yaml` supplies display/invocation metadata.
- **Claude Code:** use `~/.claude/skills/flutter-ui-automation/` or the equivalent
  project directory, then invoke `/flutter-ui-automation`. `CLAUDE.md` imports
  repository guidance; no execution permissions or MCP registration are added
  automatically. Claude discovery and runtime have not been exercised.

Windows native capture requires a native Windows host with the desktop and
required tools. The fixture remains under `examples/capture_lab/`.

## Development and validation

From `tools/automation/`:

```powershell
dart pub get
dart format --output=none --set-exit-if-changed bin lib test
dart analyze
dart test
dart compile exe bin/automation.dart -o build/automation.exe
dart run bin/check_startup.dart
```

Linux headless CI compiles to `build/automation`; the startup check selects the
platform's executable. CI runs Dart/Flutter analysis and headless tests on Linux
and Windows, Python contracts on Windows, compiled MCP startup and standalone
Windows helper compilation. It does not establish native capture/visual acceptance.

The retained Python tools support migration/regression checks and independent
capture usage. Their commands remain in [legacy Windows usage](references/usage.md)
and [Android usage](references/android.md); development checks are in
[CONTRIBUTING.md](CONTRIBUTING.md).

Current evidence, test counts and limitations are maintained in
[validation status](docs/validation-status.md), with runtime measurements and
reproduction commands in [MCP validation](docs/mcp-validation.md).

## Repository layout

```text
tools/automation/       Resident Dart MCP, persistent CLI and regression tests
tools/window_capture/   Independent C++20 PrintWindow/WGC helper
examples/capture_lab/  Flutter Windows/Android reference fixture
scripts/              Repository checks and retained Python regression tools
references/           Current workflow, platform and capture contracts
docs/                 Installation, validation summary and runtime measurements
SKILL.md              Shared agent instructions
AGENTS.md / CLAUDE.md  Repository guidance and Claude import
agents/openai.yaml    Codex display and invocation metadata
```

## License and reporting

Original project code is copyright (C) 2026 normalllll and available under
**GPL-3.0-or-later**. See [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT) and
[third-party notices](THIRD_PARTY_NOTICES.md). Flutter-derived scaffolding retains
its upstream notices. Report bugs through the repository's issue template; use
[SECURITY.md](SECURITY.md) for sensitive findings. Release changes are recorded in
[CHANGELOG.md](CHANGELOG.md).
