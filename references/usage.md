# Windows usage and integration

For Android sessions and commands, read [android.md](android.md). The common
CLI defaults to Windows for compatibility. Platform selection is explicit.

## Requirements

Windows 10 1903+ (WGC requires Graphics Capture support); Flutter Windows toolchain,
Visual C++ with CMake and Windows SDK, Python 3.11+, FFmpeg and FFprobe on PATH.
The example was created with Flutter 3.47.6 / Dart 3.13.5. Python scripts use only
the standard library. The example's Flutter Driver/Test dependencies come from
the SDK. The C++ helper uses the system Windows SDK and does not download libraries.

See [installation](../docs/installation.md) for cloning and dependency preparation.
Run `flutter pub get` in `examples/capture_lab/` before the first fixture launch.

Run commands from this skill directory, replacing `python` with the available
Python executable when necessary. In Codex, use `load_workspace_dependencies`
when available to find the bundled interpreter if Python is not on PATH. In other
agents, locate an existing native Windows Python executable and use its absolute
path. Do not install another runtime just because the command alias is absent.

```powershell
python scripts/lab.py build
python scripts/lab.py start
python scripts/lab.py state
python scripts/lab.py drive tap nav-gallery
python scripts/lab.py drive scroll gallery-scroll -450
python scripts/lab.py drive tap nav-interaction
python scripts/lab.py drive tap input-field
python scripts/lab.py drive text "Agent input / 测试输入"
python scripts/lab.py drive app-shot artifacts/app.png
python scripts/lab.py window-shot artifacts/window.png
python scripts/lab.py app-record artifacts/app.mp4 8
python scripts/lab.py record artifacts/window.mp4 8
python scripts/lab.py drive foreground on
python scripts/lab.py drive tap nav-scenarios
python scripts/lab.py drive tap open-dialog
python scripts/lab.py drive wait confirmation-dialog
python scripts/lab.py drive app-shot artifacts/dialog-original.png
python scripts/lab.py window-shot artifacts/dialog-window-original.png
python scripts/lab.py drive tap dialog-confirm
python scripts/lab.py drive wait-absent confirmation-dialog
python scripts/lab.py drive tap animation-play
python scripts/lab.py drive tap animation-pause
python scripts/lab.py drive tap animation-reset
python scripts/lab.py drive foreground off
python scripts/lab.py verify
python scripts/lab.py verify-cold 3
python scripts/lab.py stop
```

`start` runs `flutter run --machine` in a background process without a console
window and stores the reported **wsUri** in `artifacts/session.json`. The event's
`baseUri` is a filesystem URI and must not be used as the VM endpoint. Session
state is atomically replaced. `stop` uses Flutter's machine protocol to stop only
that app instance. `verify` restores foreground simulation but leaves the example
running so it can be inspected; stop it when finished.

`verify` requires a background, visible window. It writes a timestamped directory
with assertions and state snapshots in `report.json`, app/window PNG pairs, a
8-second app-content and 12-second native-window videos, lossless masters and contact sheets.
It checks 144 native-video frames at 12 fps, meaningful decoded page changes
and zero foreground samples during capture.
The window content area is also checked for non-blank pixels and the native
backend must supply multiple fresh frames. Both recordings must match their
timeline in wall-clock time (see [capture details](capture.md#timing-and-freshness)).
Each check carries `group`: `functional` (internal interaction, app capture,
foreground simulation) or `native`. A functional failure stops the run. A native
failure, including a presentation timeout or a recording that cannot start
(for example while the display is off), is recorded with its diagnostics and the
functional checks continue. The report separates `functionalPassed` and
`nativeCapturePassed`; `passed` requires both, and an interrupted run passes
neither. `verify` exits with code 1 when either group fails. Directories from
failed attempts are retained.

Driver interactions (`tap`, `text`, `scroll`, `tap-at`, `wait`, `wait-absent`)
and `app-shot` wait up to 3 s for transient animations (route transitions,
ripples, scroll ballistics) to finish, pumping forced frames so they also
complete while ordinary frames are disabled. Their output reports `settled`,
`settleMs` and `pendingTransientCallbacks`; `settled: false` means the
screenshot may show motion. Add `--no-settle` while recording motion or
starting a continuous animation, for example
`python scripts/lab.py drive tap animation-play --no-settle`.

Text entry emulation (needed by `drive text`) replaces the platform text input
channel, so a person cannot type into this test build while it is on. Use
`drive text-emulation off` before manual inspection and `drive text-emulation on`
before focusing a field Driver will type into.

`start` and `stop` recover a session whose supervisor has exited (crash,
reboot, killed process): they verify the recorded fixture process by image path
and creation time, close only that instance, and clear the session. The
supervisor survives transient session-file sharing violations.

It also verifies dialog open/confirm/cancel and the modal barrier, real animation
play/pause/reset, and matching animation-region pixels in both recording paths.
`verify-cold 3` closes only the fixture session, starts three fresh instances,
captures all four pages and tests rejection of deliberately stale presented frames.
It stops its last session on completion. Run the two verifiers sequentially.
The three cold launches cover `auto`, `primary`, and `secondary` placement.

Original PNGs use physical resolution. Each MP4 has an accompanying
`.lossless.mkv` FFV1/BGRA master and source-frame hashes; all decoded master frames
must match their original BGRA pixels. App recording also keeps its source PNGs.
Use masters/original PNGs for antialiasing inspection. MP4s and contact sheets are
viewing copies. See [capture details](capture.md).

## Independent window capture

The screenshot/recording helper does not require Flutter or the example's Driver.
Supply the HWND and PID of the specifically authorized application. The Python
wrapper checks that the handle belongs to that PID before starting capture.

```powershell
python scripts/window_capture.py screenshot --hwnd 123456 --pid 1234 --output artifacts/window.png
python scripts/window_capture.py record --hwnd 123456 --pid 1234 --output artifacts/window.mp4 --seconds 8 --fps 12
```

Values above are syntax examples, not existing handles. Get actual values from
the connected application's native status or scoped process/window discovery.
Never resolve a similarly named unrelated window and capture it speculatively.

The default executable is built next to the example's Debug runner. To build
independently in a Visual C++ environment:

```powershell
cmake -S tools/window_capture -B tools/window_capture/build
cmake --build tools/window_capture/build --config Release
python scripts/window_capture.py screenshot --hwnd 123456 --pid 1234 --output artifacts/window.png --helper tools/window_capture/build/Release/window_capture.exe
```

The fixture uses WGC and a visual presentation fence. The generic independent CLI
keeps PrintWindow as its compatibility default; choose `--backend wgc` for WGC.
Generic apps do not automatically have the fixture's probe. Add an equivalent
test-only hook that paints the marker (same 32-cell encoding and colors as the
fixture's `prepareCapture`) and pass it to the CLI, either as physical client
pixels or as the hook's JSON response:

```powershell
python scripts/window_capture.py screenshot --hwnd 123456 --pid 1234 --backend wgc --output artifacts/window.png --probe 42 1700 1000 192 12
python scripts/window_capture.py screenshot --hwnd 123456 --pid 1234 --backend wgc --output artifacts/window.png --probe-json artifacts/probe.json
```

`--probe-json` takes `{token, rect: {x, y, width, height}, pixelRatio}` with a
logical rect; `-` reads it from stdin. Without a probe the CLI prints a warning
and reports `presentationVerified: false`: the image may be blank or a stale
earlier page, so inspect it before accepting it. An API success result alone is
insufficient. Measured results are in `docs/validation.md`.

The C++ tool outputs a PNG or BGRA rawvideo stream. The Python wrapper pipes the
stream to FFmpeg using inherited pipes, with no screen recorder UI or system
input. Video is silent and constant frame rate; static frames may be repeated.
Lossless masters retain source dimensions. Only H.264 viewing copies are padded
to even dimensions. Keep capture dimensions
stable for a recording. Windows may display its standard capture border.

## Integrating a different Flutter app

Reuse an existing Dart/Flutter MCP/Driver harness before adding code. If the app
has no extension, a dedicated entrypoint can call
`enableFlutterDriverExtension()` before the app's normal initialization/runApp.
Use observed widgets or stable Keys and preserve the actual widget callbacks.
Driver's text emulation verifies the text-handling path, not native IME input.

The included example's `state`, `refresh`, `settle`, `prepareCapture`, `appScreenshot`, `tapAt`, `pretendForeground` and `key`
request-data commands are custom hooks implemented in `CaptureLabState`.
They are not built-in Flutter Driver commands. `lab.py` deliberately manages the
example only; do not point it at another project and assume those hooks exist.
For another app, connect its actual VM service through MCP or a separate Driver
client; reuse the independent window capture CLI unchanged.

For lifecycle simulation, adapt the test binding and native no-activation setup
after inspecting that app's lifecycle, platform plugins and initialization.
Test restoration and actual OS foreground status. Normal `lib/main.dart` must
not enable Driver or simulation. Do not promise background equivalence for
OS-dependent code.

## Making this the default

This directory itself is the skill package (`SKILL.md`, `agents/`, scripts,
references, tools and example). Install/link the entire folder through the
environment's skill mechanism; copying only `SKILL.md` omits executable tools.
Automatic invocation is allowed. For consistent project defaults, add a brief
AGENTS.md or CLAUDE.md rule selecting this workflow for Flutter UI verification and preventing
automatic Computer Use fallback. Instructions do not constitute tool isolation;
omit global input tools from a restricted execution environment when a hard
technical prohibition is required.

For Claude Code, install the complete package under
`~/.claude/skills/flutter-ui-automation/` or
`<project>/.claude/skills/flutter-ui-automation/`, then invoke
`/flutter-ui-automation`. The root CLAUDE.md imports this repository's AGENTS.md.
For the static compatibility scope, see
[Claude Code compatibility](../docs/claude-compatibility.md).

## Initial window placement

Default `auto` selects the largest secondary monitor work area when present,
otherwise the primary monitor. The runner centers a window up to 1280×720 logical
pixels within that work area, accounting for DPI and taskbars. Signed physical
desktop origins support monitors left of or above the primary.

The first show uses `SetWindowPos(HWND_BOTTOM, SWP_NOACTIVATE | SWP_SHOWWINDOW)`
with no move/resize. This establishes the initial Z-order below other app windows
without activating. `SW_SHOWNOACTIVATE` alone had left an inactive window above
the already-active window; clicking that already-active window did not reliably
raise it. No topmost flag is used. Later deliberate user activation remains normal.

```powershell
python scripts/lab.py stop
python scripts/lab.py start auto       # prefer secondary, otherwise primary
python scripts/lab.py stop
python scripts/lab.py start primary    # primary monitor, still initially behind
python scripts/lab.py stop
python scripts/lab.py start secondary  # secondary if present, otherwise primary
```

Placement and renderer can be combined, e.g. `start default secondary`. Restart
an existing session to apply a new placement. Native status reports window bounds,
monitor work area, primary/secondary status, topmost state, and whether the
current foreground HWND is above the fixture in actual Z-order. Capture never
raises the target to obtain pixels, even if other windows obscure it.

## Renderer comparison

`start` defaults to the normal Flutter renderer. For an explicit diagnostic:

```powershell
python scripts/lab.py stop
python scripts/lab.py start software
# or: python scripts/lab.py start skia
# or: python scripts/lab.py start default
```

Software mode passes `--enable-software-rendering --no-enable-impeller`; Skia
passes `--no-enable-impeller`. This is recorded in the session/report, never an
undisclosed substitute for the target's normal renderer. Existing sessions are
reused; stop them before selecting a different renderer.
