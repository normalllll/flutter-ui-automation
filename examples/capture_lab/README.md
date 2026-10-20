# Capture Lab fixture

Windows and Android test application for the Flutter UI Automation skill.

- Normal entrypoint: `lib/main.dart`; no Driver or foreground simulation.
- Test entrypoint: `lib/driver_main.dart`; internal Driver controls and explicit
  framework lifecycle/view-focus simulation.
- `tool/driver.dart`: fixture interaction and screenshot CLI.
- `tool/record_app.dart`: persistent Driver connection for app-content recording.
- `test/`: state-restoration, focus-guard and component-interaction checks.

Use `scripts/lab.py` from the repository root for the managed example lifecycle,
scoped capture and full verification. See `../../references/usage.md` and
`../../docs/validation.md` for commands and measured limitations.

Run `flutter pub get` here before the first build or launch. The reference SDK is
Flutter 3.47.6 / Dart 3.13.5; see [installation](../../docs/installation.md) and
the [public validation summary](../../docs/validation-status.md). Original project
additions are [GPL-3.0-or-later](../../COPYRIGHT); Flutter-derived scaffolding
retains its [upstream notice](../../THIRD_PARTY_NOTICES.md).

## Android

Use `lib/android_driver_main.dart` for Android automation; `lib/main.dart` stays
normal. The Android project uses package `dev.flutter.flutter_capture_lab`.
See [Android commands](../../references/android.md) and
[validation evidence](../../docs/android-validation.md). Narrow/short viewports
use bottom navigation; native keyboards resize the content and hide navigation.
