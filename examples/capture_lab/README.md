# Capture Lab fixture

Windows and Android reference application for the Flutter UI Automation skill.
Use the [resident MCP workflow](../../references/mcp.md) for builds, persistent
sessions, interactions, capture and verification.

- Normal entrypoint: `lib/main.dart`; no Driver or foreground simulation.
- Windows test entrypoint: `lib/driver_main.dart`; internal Driver controls and
  explicit framework lifecycle/view-focus simulation.
- Android test entrypoint: `lib/android_driver_main.dart`; real mobile lifecycle,
  native identity/geometry and explicit Driver text emulation for Unicode input.
- `test/`: binding restoration, focus guard, adaptive layout and widget checks.

From the repository root on Windows:

```powershell
./tools/automation/build.ps1 -FlutterRoot C:/path/to/flutter -Fixture windows
# Use -Fixture android for an Android build.
```

Prepare dependencies with `flutter pub get` here before building through another
entrypoint. Minimum supported toolchains are Flutter 3.44.0 / Dart 3.12.0. CI follows stable
without an exact tag/commit pin; recorded runtime measurements used Flutter
3.47.8 / Dart 3.13.7. See
[installation](../../docs/installation.md) and
[current validation](../../docs/validation-status.md).

Android uses package `dev.flutter.flutter_capture_lab` and an explicit device ID.
Narrow/short viewports use bottom navigation; native keyboards resize content and
hide navigation. Read [Android integration](../../references/android.md) before
runtime checks. Builds, launches and capture retain the user's authorization.

Original project additions are [GPL-3.0-or-later](../../COPYRIGHT);
Flutter-derived scaffolding retains its
[upstream notice](../../THIRD_PARTY_NOTICES.md).
