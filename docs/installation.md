# Installation and prerequisites

## Get the source

```powershell
git clone https://github.com/normalllll/flutter-ui-automation.git
cd flutter-ui-automation
python -B scripts/check_repository.py
```

The clone URL becomes usable once the source is pushed. Install or link the
**entire directory** through your agent's skill mechanism. For Claude Code, use
`~/.claude/skills/flutter-ui-automation/` or the equivalent project directory.
For Codex, install the complete directory as `flutter-ui-automation`, then invoke
`$flutter-ui-automation`. Do not copy only `SKILL.md`.

The root is a skill/tool repository; the Flutter project is
`examples/capture_lab/`. The bundled lifecycle CLI manages this fixture. Integrate
another app using its existing Driver harness or the
[Windows integration guide](../references/usage.md) and
[Android guide](../references/android.md).

## Toolchain

| Component | Requirement / reference baseline |
| --- | --- |
| Python | 3.11+; standard library only; CI covers 3.11 and 3.13 on Windows |
| Flutter / Dart | Reference and CI pin: Flutter 3.47.6 / Dart 3.13.5; fixture SDK constraint is `^3.13.5` |
| FFmpeg / FFprobe | Both on PATH, with PNG, rawvideo, FFV1 and libx264 support; CI prints installed versions |
| Windows capture | Windows 10 1903+ with WGC support and an accessible interactive desktop |
| Windows build | Visual Studio Desktop development with C++, CMake 3.14+ and Windows SDK; C++20 helper |
| Android | Flutter Android toolchain, Android SDK, compatible JDK 17+, and an explicitly selected trusted device |

Other Flutter versions may work but are not covered by the reference results.
Python versions below 3.11 are outside the supported baseline. The full Python
suite includes native Windows contract checks; Android command routing is
separate from Windows host support.

Check prerequisites without launching an application:

```powershell
python --version
flutter --version
ffmpeg -version
ffprobe -version
```

If Python is not on PATH, use its absolute executable path. Do not install another Python
merely because the `python` alias is absent.

## Prepare the fixture

```powershell
cd examples/capture_lab
flutter pub get
cd ../..
```

Dependency resolution can access the network. Flutter regenerates local project
configuration and Android Gradle wrapper files as needed; do not copy another
machine's `local.properties`, `.dart_tool/` or build directories. Generated lock
files remain local under repository policy; the reference Flutter SDK is pinned
in CI and dependency updates must rerun the affected checks.

After obtaining authorization for the relevant build and runtime operations, use
the [Windows quick start](../README.md#windows-quick-start) or
[Android quick start](../README.md#android-quick-start). Tool installation does
not grant permission to launch or capture an app.

## Repository checks

Run these checks directly from the repository root:

```powershell
python -B scripts/check_repository.py
python -B -m unittest discover -s scripts -p "test_*.py" -v
```

The complete Python suite runs on Windows and requires FFmpeg/FFprobe. These
commands do not launch the fixture or connect to a device. Use Git to obtain
the source. No MCP server is included.
