# Contributing

Please open an issue before proposing a new platform or changing the automation
contract. Include the target platform, tool versions, expected behavior and a
minimal reproduction. Remove VM Service URLs, device identifiers, private screen
content and personal paths from public reports.

## Development setup

Clone the complete repository. Use Python 3.11+ and FFmpeg/FFprobe on PATH. Python
tools have no third-party Python dependencies. Flutter work uses Flutter 3.47.6
(Dart 3.13.5); run `flutter pub get` in `examples/capture_lab/` first. Windows
native compilation also requires Visual Studio's Desktop development with C++,
CMake and the Windows SDK. See [installation](docs/installation.md).

Run from the repository root:

```powershell
python -B scripts/check_repository.py
python -B -m unittest discover -s scripts -p "test_*.py" -v
```

The complete Python suite runs on Windows: it uses real process identity and
invalid-HWND checks as well as mocked device calls and tiny FFmpeg encodes. It
does not launch a fixture, connect to a device or control desktop input. If
`python` is unavailable, use the absolute path to an existing Python 3.11+
executable.

For Flutter changes, run from `examples/capture_lab/`:

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

These tests use the headless test runner. Native capture and mobile runtime
acceptance are separate, authorized checks described in the platform references.
Do not start apps, boot emulators or capture screens merely to satisfy a static
or unit-test change. CI never establishes visual acceptance.

## Changes and evidence

- Keep the fixture in `examples/capture_lab/` and normal app entrypoints free of
  Driver extensions. Preserve Windows simulation and actual Android lifecycle.
- Follow the affected callers and preserve session ownership, bounded waits,
  strict presentation tokens and original failed capture evidence.
- Run affected checks. Explain behavior changes, validation and material gaps in
  the pull request; update usage documentation when commands or contracts change.
- Never commit builds, local SDK configuration, lock files, raw recordings,
  device session files or transient VM connection URLs. For public evidence,
  retain only reviewed, sanitized summaries under `docs/`.
- Contributions to original project code are provided under GPL-3.0-or-later.
  Preserve third-party notices and identify any new third-party material.

See [security reporting](SECURITY.md) for sensitive issues and
[validation status](docs/validation-status.md) for the current evidence boundary.
