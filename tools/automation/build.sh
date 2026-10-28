#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
platform="${1:-}"
case "$platform" in linux|macos|ios) ;; *) echo 'Usage: build.sh linux|macos|ios' >&2; exit 2 ;; esac
# Use the same SDK the MCP is later given with --flutter-root, like build.ps1.
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  export PATH="$FLUTTER_ROOT/bin:$PATH"
fi
cd "$root/tools/automation"
dart pub get
mkdir -p build
dart compile exe bin/automation.dart -o build/automation
if [[ "$platform" == linux ]]; then
  cmake -S "$root/tools/linux_capture" -B "$root/tools/linux_capture/build"
  cmake --build "$root/tools/linux_capture/build"
elif [[ "$platform" == macos ]]; then
  bundle="$root/tools/macos_capture/build/FlutterUICapture.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$root/tools/macos_capture/Info.plist" "$bundle/Contents/Info.plist"
  xcrun swiftc -parse-as-library "$root/tools/macos_capture/main.swift" -o "$bundle/Contents/MacOS/capture"
  codesign --force --sign - --identifier io.github.normalllll.flutter-ui-automation.capture "$bundle"
fi
cd "$root/examples/capture_lab"
flutter pub get
if [[ "$platform" == ios ]]; then
  flutter build ios --simulator --debug -t lib/platform_driver_main.dart
else
  flutter build "$platform" --debug -t lib/platform_driver_main.dart
fi
