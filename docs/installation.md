# Installation and prerequisites

The current runtime is the [resident Dart MCP](../references/mcp.md). Build it
once with `tools/automation/build.ps1`, using Dart already supplied by Flutter.
Python is needed only for repository checks and standalone Windows capture;
the resident workflow does not require it. Linux/macOS/iOS Simulator builds use
`bash tools/automation/build.sh linux|macos|ios` on the target host.

## Get the source

```powershell
git clone https://github.com/normalllll/flutter-ui-automation.git
cd flutter-ui-automation
```

Install or link the **entire directory** through your agent's skill mechanism.
For Claude Code, use
`~/.claude/skills/flutter-ui-automation/` or the equivalent project directory.
For Codex, install the complete directory as `flutter-ui-automation`, then invoke
`$flutter-ui-automation`. Do not copy only `SKILL.md`.

The root is a skill/tool repository; the Flutter project is
`examples/capture_lab/`. The resident MCP manages fixture sessions. Integrate
another app using its existing Driver harness or the
[MCP integration guide](../references/mcp.md#integrating-an-app),
[Windows integration guide](../references/usage.md) and
[Android guide](../references/android.md).

## Toolchain

| Component | Minimum requirements |
| --- | --- |
| Resident service | Dart 3.12+ from Flutter; `dart_mcp_server` 1.2.1 embedded in process |
| Python (repository/standalone capture only) | 3.11+; standard library only; CI covers 3.11 and 3.13 on Windows |
| Flutter / Dart | Minimum Flutter 3.44.0 / Dart 3.12.0; CI tracks the current stable channel |
| FFmpeg / FFprobe | Both on PATH, with PNG, rawvideo, FFV1 and libx264 support; CI prints installed versions |
| Windows capture | Windows 10 1903+ with WGC support and an accessible interactive desktop |
| Windows build | Visual Studio Desktop development with C++, CMake 3.14+ and Windows SDK; C++20 helper |
| Android | Flutter Android toolchain, Android SDK, compatible JDK 17+, and an explicitly selected trusted device |
| Linux X11 | Flutter Linux toolchain, GTK 3, X11/libpng development libraries; Xvfb and software GL for isolated headless runs |
| macOS | Xcode and Flutter macOS tooling; ScreenCaptureKit screenshot helper requires macOS 14+ and user-granted Screen Recording permission |
| iOS Simulator | Mac with Xcode and an available, explicitly booted Simulator runtime; physical-device control/capture is not bundled |

SDK constraints declare the minimum supported versions, not an exact installed
version. Newer SDKs are permitted, and the service does not reject a host based
on a parsed version number. Actual missing APIs/hooks/backends produce capability
errors. Historical measurements keep the versions used for those runs. Python
3.11+ is required only for the remaining developer/standalone tool scripts.

Check prerequisites without launching an application:

```powershell
flutter --version
ffmpeg -version
ffprobe -version
```

Check `python --version` only when using the repository checks or standalone capture.
If Python is not on PATH, use an existing Python 3.11+ executable's absolute path.

## Prepare the fixture

```powershell
cd examples/capture_lab
flutter pub get
cd ../..
```

Dependency resolution can access the network. Flutter regenerates local project
configuration and Android Gradle wrapper files as needed; do not copy another
machine's `local.properties`, `.dart_tool/` or build directories. Generated lock
files remain local under repository policy; CI follows the stable Flutter branch,
and dependency or SDK updates rerun the
affected analysis, build and behavioral checks.

After obtaining authorization for the relevant build and runtime operations, use
the [Windows quick start](../README.md#windows-quick-start) or
[Android quick start](../README.md#android-quick-start). Tool installation does
not grant permission to launch or capture an app.
Linux and Apple preparation, execution limits and remote setup are described in
[Linux](../references/linux.md), [Apple](../references/apple.md) and
[remote execution](../references/remote.md).

## Repository checks

Run these checks directly from the repository root:

```powershell
python -B scripts/check_repository.py
python -B -m unittest discover -s scripts -p "test_*.py" -v
```

The Python suite tests only the independent Windows capture wrapper; it uses
mocked helper/encoder processes and needs no codec executables. Standalone
recording requires FFmpeg. Flutter/media regressions run with `dart test` in
`tools/automation/` and require FFmpeg/FFprobe. These
commands do not launch the fixture or connect to a device. Use Git to obtain
the source. The resident MCP is compiled separately as described above.
