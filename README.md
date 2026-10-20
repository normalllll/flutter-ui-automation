# Flutter UI Automation

Automate Flutter UI interactions, screenshots and recordings on **Windows and
Android**, without taking over the host's mouse, keyboard or foreground window.

An agent skill, Python tools, an independent Windows capture helper and a Flutter
reference fixture maintained by [normalllll](https://github.com/normalllll).
Early source release; licensed under **GPL-3.0-or-later**.

The bundled `lab.py` manages the fixture in `examples/capture_lab/`. Integrating
another app requires its own Driver/test hooks; this is not plug-and-play
automation for arbitrary release applications. No MCP server is included.

| Platform | Control and content | System presentation | Current boundary |
| --- | --- | --- | --- |
| Windows | Flutter Driver, app PNGs and recordings | Scoped HWND/PID WGC or PrintWindow | Interactive desktop; display-off reliability unresolved |
| Android | Flutter Driver, app PNGs and recordings | Explicit-device ADB screenshots and lossy screenrecord | Emulator reference evidence; latest capture error-handling changes await device rerun |
| iOS / other desktops | No bundled backend | No bundled backend | Unsupported |

Start with [installation](docs/installation.md),
[current validation status](docs/validation-status.md) and the platform guides:
[Windows](references/usage.md), [Android](references/android.md).

## Capabilities

- Interact with widgets through Flutter Driver: navigate pages, click controls,
  scroll, enter text, and send framework keyboard events.
- Verify Flutter dialogs, modal barriers, callback results, and dismissal.
- Exercise real animations and check play, pause, reset, and rendered pixel changes.
- Save app-content PNGs at the actual view DPI, including Navigator overlays.
- Capture a selected Windows HWND independently, with native window decorations.
- Record full-resolution FFV1/BGRA lossless masters and separate MP4 viewing copies.
  Decode every master and verify its frame hashes against the original BGRA input.
- Wait for a per-request visual presentation marker before accepting a fixture
  window capture, rejecting blank or stale frames instead of trusting API success.
- Start the fixture behind existing windows, prefer a secondary monitor when
  available, and account for DPI, taskbars, and negative monitor coordinates.
- Optionally simulate Flutter lifecycle and view focus while reporting actual
  Windows foreground and native focus separately.
- Select Android devices explicitly, verify fixture identity and preserve actual
  mobile lifecycle, focus and session ownership. Android display video remains
  an original lossy source; it is not a lossless display master.

## Requirements and installation

Use Python **3.11+**, FFmpeg and FFprobe. Python tools use only the standard
library. The reference Flutter SDK is **3.47.6 / Dart 3.13.5**, also pinned in CI.
Windows requires its desktop C++ toolchain, Windows SDK and an accessible desktop.
Android requires its Flutter Android toolchain and an explicitly selected trusted
device; the CLI does not boot emulators. See the
[complete prerequisites and install steps](docs/installation.md).

Clone the complete repository and run `flutter pub get` inside
`examples/capture_lab/` before using the fixture. Installing the skill alone does
not authorize builds, launches or capture.

## Windows quick start

Run from this repository's root in PowerShell:

```powershell
python scripts/lab.py build
python scripts/lab.py verify
python scripts/lab.py verify-cold 3
python scripts/lab.py stop
```

`build` prepares the fixture and native helper. `verify` opens a non-activating
Windows test window, drives its actual widgets, and checks screenshots, dialogs,
animations, app recording, and native recording. `verify-cold 3` performs three
fresh launches covering automatic, primary-monitor, and secondary-monitor
placement. It also tests stale-frame rejection and missing-frame timeouts.

These commands require authorization to build, launch, interact with, and capture
the test app. They use application-internal input rather than global desktop input.
`verify` restores temporary foreground simulation and leaves its session available
for inspection; `verify-cold` closes its final session. `stop` closes only the
fixture session managed by these tools.

For an interactive walkthrough:

```powershell
python scripts/lab.py start auto
python scripts/lab.py drive foreground on
python scripts/lab.py drive tap nav-scenarios
python scripts/lab.py drive tap open-dialog
python scripts/lab.py drive wait confirmation-dialog
python scripts/lab.py drive app-shot artifacts/dialog-app.png
python scripts/lab.py window-shot artifacts/dialog-window.png
python scripts/lab.py drive tap dialog-confirm
python scripts/lab.py drive wait-absent confirmation-dialog
python scripts/lab.py drive tap animation-play
python scripts/lab.py record artifacts/animation.mp4 8
python scripts/lab.py drive tap animation-pause
python scripts/lab.py drive foreground off
python scripts/lab.py stop
```

Use `start primary` or `start secondary` to select a monitor explicitly. Stop an
existing session before changing its placement or renderer. All placement modes
show the fixture behind existing windows without activating it.

## Android quick start

Replace `ACTUAL_SERIAL` with the authorized target listed by `devices`. Run from
the repository root after preparing fixture dependencies:

```powershell
python scripts/lab.py --platform android devices
python scripts/lab.py --platform android --device ACTUAL_SERIAL build
python scripts/lab.py --platform android --device ACTUAL_SERIAL start
python scripts/lab.py --platform android --device ACTUAL_SERIAL verify
python scripts/lab.py --platform android --device ACTUAL_SERIAL stop
```

Build, device interaction and capture require the applicable authorization.
`verify` stops only a session it started; `stop` detaches attached sessions without
terminating their apps. Read [Android usage](references/android.md) for attachment,
ownership, native keyboard behavior, rotation and evidence requirements.

## Original images and recordings

PNG screenshots retain source pixels at physical resolution. Each Windows native
or Flutter app recording produces a `.lossless.mkv` FFV1/BGRA master, a
`.source.framemd5` file, and a lossy
`.mp4` viewing copy. App recording also retains every original PNG frame.

Use original PNGs or unscaled lossless extracts to inspect text and antialiasing.
Contact sheets and MP4 previews are for browsing. Lossless masters have no scaling,
chroma subsampling, or odd-dimension padding. The fixture defaults to app capture
at 5 fps on Windows and 2 fps on Android, with Windows native capture at 12 fps;
this does not establish 60 fps performance. Android display recording retains
the original lossy H.264 source and may use lower encoder resolution. It does
not produce a lossless display master.

```powershell
ffmpeg -ss 1 -i artifacts/animation.lossless.mkv -frames:v 1 artifacts/frame-original.png
```

Generated media, logs, session details, and reports live under the ignored
`artifacts/` directory. Historical measurements remain in the validation notes.

If the presentation marker times out, the operation fails and preserves a
separate original `*.failed-native.png` when a rejected frame exists. Structured
diagnostics include display state, desktop/session access, window state, and
sampled pixel bounds. A failure image is diagnostic evidence, not visual
acceptance. Read [capture diagnostics](references/capture.md) before attributing
a white native window to the application or GPU. The tools do not wake displays
or change power policy as a fallback.

## Use as an agent skill

Install or link this entire directory through the target agent's skill mechanism.
Copying only `SKILL.md` omits the executable helpers and supporting references.
The repository checkout itself is not automatically a registered skill.

### Claude Code

Place the package at either:

- `~/.claude/skills/flutter-ui-automation/` for personal use.
- `<your-project>/.claude/skills/flutter-ui-automation/` for project use.

After installation, invoke `/flutter-ui-automation` or ask for a matching Flutter
UI task. The shared `SKILL.md` uses standard `name` and `description` frontmatter
and needs no Claude-specific execution hook. `CLAUDE.md` imports `AGENTS.md` for
repository work. `agents/openai.yaml` is Codex metadata, not a Claude dependency.

Use a native Windows environment with access to Windows Python and the Flutter
Windows toolchain. The native HWND workflow is not a Linux/WSL or cloud-only UI
workflow. An existing Dart/Flutter MCP connection is optional; the bundled Driver
CLI is the fallback.

Claude Code compatibility was checked statically against its official skill and
instruction-file documentation. Claude was not launched, and discovery or runtime
behavior inside a Claude session has not been verified. See the
[compatibility notes](docs/claude-compatibility.md) for the exact scope and sources.

### Codex

Install the complete package using the environment's skill mechanism and invoke
`$flutter-ui-automation`. The metadata in `agents/openai.yaml` allows automatic
selection. Existing execution permissions still apply.

## Integrating another Flutter app

Reuse its existing MCP or Driver harness first. Otherwise, add an authorized test
entrypoint and stable widget keys. Keep Driver extensions, capture hooks, and
lifecycle simulation separate from the app's production entrypoint.

The bundled `lab.py` manages this fixture, not arbitrary Flutter projects. Its
state, settle, screenshot, and presentation-probe commands are custom hooks. The
independent HWND/PID capture CLI can be reused separately and accepts the
app's marker through `--probe`/`--probe-json`; without one its captures report
`presentationVerified: false`. Read the [integration guide](references/usage.md)
before adapting the fixture.

Framework foreground simulation does not make Windows consider the app active.
Native IME composition, system hotkeys, OS dialogs, and native plugin branches
that query Windows focus require their own platform-specific checks.

## Repository layout

```text
SKILL.md                    Shared skill instructions
AGENTS.md                   Repository guidance
CLAUDE.md                   Claude Code import of repository guidance
agents/openai.yaml          Codex display and invocation metadata
scripts/lab.py              Fixture lifecycle, interaction, and verification
scripts/window_capture.py   Independent HWND/PID capture and recording CLI
scripts/media.py            Lossless masters and source-frame verification
scripts/verify_scenarios.py Dialog, animation, cold-start, and frame-fence checks
tools/window_capture/       Standalone C++20 PrintWindow/WGC helper
examples/capture_lab/       Flutter Windows and Android verification fixture
references/                 Usage, capture fidelity, and foreground behavior
docs/                       Historical validation and compatibility notes
artifacts/                  Generated output; ignored and recreated on demand
```

## Development and validation

```powershell
python -B scripts/check_repository.py
python -B -m unittest discover -s scripts -p "test_*.py" -v
```

The full Python suite runs on Windows and includes small real FFmpeg encodes,
without launching the fixture or controlling a device. If `python` is unavailable,
use the absolute path to an existing Python 3.11+ executable.
See [contributing](CONTRIBUTING.md) for Flutter checks and change expectations.

GitHub Actions checks source/metadata/documentation, Python 3.11 and 3.13 on
Windows, Flutter analysis/headless tests, and standalone Windows helper
compilation. It does not execute native capture or device acceptance.

The latest documented Windows regression passed 77 checks. Android's historical
emulator run passed 28 assertions plus sampled visual review; its subsequent
capture error-handling changes await a device rerun. Current public evidence and
remaining limitations are in the [validation summary](docs/validation-status.md).
Raw artifacts remain local and ignored. Display-off Windows reliability is
unresolved; historical results are specific to the fixture and recorded host.

Detailed behavior is documented in [usage](references/usage.md),
[capture fidelity](references/capture.md), and
[foreground simulation](references/foreground.md). Historical results are in
[validation](docs/validation.md).

## License and reporting

Original project code is copyright (C) 2026 normalllll and available under
**GNU GPL version 3 or (at your option) any later version**
(`GPL-3.0-or-later`). See [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT) and
[third-party notices](THIRD_PARTY_NOTICES.md). Flutter-derived scaffolding retains
its upstream license.

Report bugs using the repository's issue template. Follow [SECURITY.md](SECURITY.md)
for sensitive findings. Initial release preparation is recorded in
[CHANGELOG.md](CHANGELOG.md).
