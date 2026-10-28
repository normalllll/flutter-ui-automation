# Resident Dart MCP

Use this route for new automation. The executable embeds the official
`dart_mcp_server` **1.2.1** through its public `DartMCPServer.run(channel:)` API.
It merges the official tool list with `automation_*` tools. It does not start a
second Dart MCP server, import the dependency's private implementation, or patch
the Flutter SDK. Python is not required on this path.

## One-time preparation

From the complete repository on Windows, with an installed Flutter SDK:

```powershell
./tools/automation/build.ps1 -FlutterRoot C:/path/to/flutter -Fixture windows
# For Android, use -Fixture android, or automation_build below.
```

Linux/macOS/iOS Simulator use `bash tools/automation/build.sh linux|macos|ios`
on the target host. Platform preparation and capture boundaries are in
[Linux](linux.md) and [Apple](apple.md); [remote execution](remote.md) uses the same
compiled service over SSH stdio.

Minimum supported toolchains are Flutter 3.44.0 and Dart 3.12.0. SDK constraints
declare lower bounds; no exact SDK version is pinned or parsed to block startup. Native media capture needs
FFmpeg/FFprobe; Android needs ADB and an explicitly authorized device. Windows
needs its C++/Windows SDK toolchain. Building the Windows fixture also builds the
capture helper. Paths resolve from PATH, `FLUTTER_ROOT`, `ADB`, `FFMPEG`,
`FFPROBE`, `WINDOW_CAPTURE`, `ANDROID_SDK_ROOT`, and `ANDROID_HOME`.
The additional native helpers can be selected with `LINUX_CAPTURE` and
`MACOS_CAPTURE`. `automation_environment` reports host platform, Linux display
environment, macOS Screen Recording preflight and available iOS Simulators.

Configure the built executable as the single MCP server. Adapt the absolute
paths in [mcp.example.json](../tools/automation/mcp.example.json) to the client.
The embedded server receives both SDK paths from the selected Flutter SDK;
`DART_ROOT` and `DART_SDK` are not required for the compiled executable.
The example uses the common `mcpServers` structure; clients with another config
format use the same executable and arguments. Do not also register a second
official Dart MCP for this workflow. No user or agent configuration is changed
automatically.

After source/dependency upgrades, stop the service and rerun `build.ps1`. Ordinary
test actions and app source edits do not compile or restart the MCP executable.
Fixture `automation_session/start` expects resolved Flutter dependencies;
`automation_build` performs the normal Flutter build/resolution first.

## MCP workflow

Call `automation_environment` to inspect prerequisites and explicit device IDs.
The tool list describes the exact JSON schemas. A Windows fixture start is:

```json
{"action":"start","platform":"windows","sessionId":"win"}
```

For USB Android:

```json
{"action":"start","platform":"android","deviceId":"ACTUAL_SERIAL","sessionId":"fold"}
```

Start/build/record/verify return a job by default. Use `automation_jobs` with
`action: wait`, `jobId`, and `waitSeconds` up to 50. A completed job contains the
actual tool result. `state: completed` means the operation finished: inspect the
returned per-item `passed` values and verifier `passed` as well. A job's
`state: failed` contains a structured error. `action: cancel` stops only that job.
Set `job: false` only when a client's call timeout accommodates the whole action.

Read `automation_drive` with `action: tree`, then select actual keys, text,
types, semantics, or ancestor/descendant finders. For example:

```json
{"sessionId":"win","action":"tap","selector":{"kind":"key","value":"nav-gallery"}}
```

Drive actions cover tap, waits, absence/tappability, get text, Unicode text entry,
scroll/reveal, center, scoped coordinates, framework keys, and app hooks. Explicit
`driver`/`request` actions expose existing test extensions without introducing
business-state shortcuts. Continuous animations use `settle: false`.
Semantics finders require semantics to be enabled through the SDK Driver
`set_semantics` command first, while framework frames are active. Restore that
explicit test mode after using it; native accessibility owns its own semantics
handle independently.

On Windows, `foreground` enables only reversible **framework** simulation. It
never raises the native window. On Android, keep native lifecycle and focus.
For Unicode Driver input, turn `textEmulation` on, tap the field, enter text, then
unfocus and turn emulation off before testing the real IME. `back`, `background`,
`resume`, and orientation act only on the explicitly selected device/app. Native
OS dialogs and Windows IME composition are not implemented by these tools.
Raw `request`/`driver` actions reject hooks that change these reversible modes
(`pretendForeground`, `orientation`, `set_text_entry_emulation`) with
`tracked_mode`; use the dedicated actions so `stop` and `recover` restore them.

## Edit, reload, continue

Keep the session running. Edit the app's normal source, then call
`automation_session` with `action: hotReload` and its `sessionId`. Inspect state
and capture the affected screen. Use `hotRestart` for changes requiring a Dart
restart; the service waits for the new main isolate, Driver registration, and
native identity. The native app PID stays the same. Native runner/plugin changes
still require a rebuild and a new app session.

The forwarded official `hot_reload`, `hot_restart`, runtime diagnostics, widget
inspection and analysis tools are available through the same MCP connection.
Automation rebinds after a directly invoked official restart too. Internal
`request_data` dispatch uses the public `vm_service/callMethod` tool because the
curated official `flutter_driver_command` tool does not expose it.

`automation_record` keeps a recording job live while `automation_drive` and
`automation_capture` continue on that session. Stop/restart are blocked until
that recording is finished or cancelled. Successful PNGs and other jobs are not
repeated when one recording is cancelled.

## Captures, evidence and retries

`automation_capture` defaults to `channels: ["app", "native"]`. Every call writes
a fresh attempt directory. It retains each successful original and reports each
failed channel separately. With both channels available, a third comparison item
checks native pixels against app content, excluding system insets/IME. Do not
repeat a successful channel when another failed: call again with, for example,
`channels: ["native"]`. `includeImages: true` adds original PNG MCP image content.

Native screenshots require the exact presentation marker from `prepareCapture`.
Windows checks HWND/PID ownership. Android validates package, PID, process start,
an app-instance token read through `run-as`, the resumed Activity and logical
display 0's **current physical panel**. A panel switch fails that capture, not
unrelated images. Failed images and rejected original video are diagnostics.

The user may look at the device, activate the test window, or change its focus.
Foreground/focus, activation counts and recording samples are observations;
they do not invalidate pixels or identify who activated the window. A check
requiring uninterrupted background conditions is `not_assessed` if those
conditions were not established. Automation still never takes host focus/input.

App recording retains original PNGs, FFV1/BGRA masters, source BGRA hashes and MP4
previews. Windows native recording retains FFV1/BGRA and verifies decoded hashes.
Android retains the original **lossy** screenrecord MP4 and display projection.
No trimming disguises an inaccurate capture duration. Reports separate
acquisition, encoding/verification wall time, video duration and timing checks.
Default app sampling is 5 fps on desktop and 2 fps on mobile. Native sampling
defaults to 12 fps on Windows, 2 fps on Linux/macOS and 1 fps on iOS Simulator,
whose display snapshots and instance checks are comparatively expensive.
These are sampling rates, not claims of display-frame capture. An explicit rate
that exceeds acquisition capacity produces a failed timing result and retains
its original media; a valid file alone does not mark that channel as passed.
Windows `nativeFps` accepts integers from 1 to 60; the helper and encoder use
the same rate. App `fps` remains a separate sampling setting.

`automation_inspect_video` decodes retained video and optionally checks a content
region. The fixture verifier measures animation pixels inside the actual stage,
excluding clocks, heartbeats and markers. `automation_verify` accepts optional
`checks` to rerun only relevant groups. It refuses network apps. Partial reports
remain `completed: false` and `passed: false` until the requested verification
finishes; interruption never promotes partial successes into acceptance.
`automation_verify_cold` explicitly performs 1..5 cold fixture launches, defaults
to one, checks presentation fences and stops its own sessions. It requires other
sessions to be finished first.

## Sessions, recovery and CLI

`automation_session/list` reuses live instances; `state` validates their identity.
`attach` requires the correct project, platform, `vmUri`, hook protocol and (on
Android) explicit device/package/instance identity. It never owns the attached
app. `stop` restores temporary modes and stops only owned sessions. MCP EOF or
`automation_service/stop` cancels jobs and cleans up the service's own resources.
Reusing a session ID rejects conflicting explicit VM URI, hook profile,
entrypoint, executable or ownership (`start` versus `attach`) instead of silently
keeping a different target. Two sessions cannot attach to the same VM endpoint. Equivalent HTTP/WS
VM service endpoints still refer to the same target.

After a service crash, `automation_session/recover` uses retained metadata and
process creation/birth times to reject a still-live supervisor and recycled
PIDs. A recycled app PID counts as an exited app, so cleanup never touches the
replacement. For an owned app still alive it first reports `requiresStopOwned: true`;
`stopOwned: true` closes that verified instance. Attached apps remain running.
Recovery releases only the matching lease. It covers Windows, Android, Linux,
macOS and iOS Simulator sessions; see [unix-validation](../docs/unix-validation.md)
for the Unix evidence.
If its owner is missing or has changed, recovery returns `lease_not_owned`
before touching the app; retained metadata cannot authorize releasing a new
session's lease.

The same executable can host a persistent CLI service when there is no MCP
client. Run **once** in a terminal:

```powershell
./tools/automation/build/automation.exe --root . serve
```

From another terminal, each thin compiled client connects to that live process:

```powershell
./tools/automation/build/automation.exe --root . call automation_environment '{}'
./tools/automation/build/automation.exe --root . call automation_session '{"action":"start","platform":"windows","sessionId":"win"}'
./tools/automation/build/automation.exe --root . call automation_service '{"action":"stop"}'
```

For shell quoting, `call TOOL @arguments.json` reads the exact UTF-8 JSON file.
`--artifacts ABSOLUTE_DIRECTORY` selects a service descriptor/lease root; the
client must use the same root as its service. The descriptor is loopback-only,
authenticated with a per-process random token, and ignored by Git. A second live
service cannot overwrite the first service's descriptor. Do not publish it.

A second MCP client configured with the same `--artifacts` root (for example two
agent sessions) does not start another service. It completes the MCP handshake,
forwards `automation_*` tools to the resident owner and keeps its own embedded
official Flutter tools. Cancelling a forwarded call abandons only the request;
use `automation_jobs` to cancel long operations. Use a separate `--artifacts`
root for a fully independent service.

There is one resident **MCP server**, not one OS process for everything. Flutter
keeps its compiler/app processes per session. WGC/PrintWindow helpers, ADB, builds
and FFmpeg still run when the requested operation needs them. No Python or new
Driver controller process is started per interaction or app frame.

## Integrating an app

Keep test hooks in a dedicated Debug entrypoint, never its production entrypoint.
The fixture is a tested example, not a universal release-app automation API.
Required hooks are `state`, `refresh`/`settle`, `appScreenshot`, and
`prepareCapture`. State exposes actual native identity and capabilities. Android
also needs its real native Flutter-view bounds and instance-token file. Preserve
real Android lifecycle/focus; make text emulation explicit and reversible.

`automation_session/start` launches only the verified fixture. Other projects
build and launch their own Debug test entrypoint, then `attach` with its `vmUri`
(and, on Android, the explicit `deviceId` and `package`). Attach never owns or
stops that app. Missing hooks are reported rather than replaced by desktop or
device-wide input.

The default Android entrypoint is `tool/automation/android_mcp.dart`. The service
checks its marker and isolated application ID before launch, then validates the
actual device/package/token/PID. The native bridge defaults to the real IME;
text emulation is explicitly enabled only for Driver text injection. Orientation
restores the Activity's original request rather than global device settings.

The staging `lib/` is a Windows junction to the real application's `lib/`.
Editing the original app source therefore hot reloads directly into the same
device process. The builder avoids traversing this junction on subsequent
copies and refuses production source directories as staging destinations. Build
output, release-signing changes and launcher changes stay in the isolated copy.
Runner/plugin changes still require rebuilding that copy.
