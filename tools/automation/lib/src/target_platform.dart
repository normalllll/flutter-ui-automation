import 'dart:io';

import 'protocol.dart';

enum TargetPlatform {
  windows,
  android,
  linux,
  macos,
  ios;

  bool get isMobile => this == android || this == ios;
  bool get isUnixTarget => this == linux || this == macos || this == ios;
  String get device => name;
  String get buildTarget => this == android ? 'apk' : name;
  String get entrypoint => switch (this) {
    windows => 'lib/driver_main.dart',
    android => 'lib/android_driver_main.dart',
    _ => 'lib/platform_driver_main.dart',
  };

  void requireHost() {
    final supported = switch (this) {
      windows => Platform.isWindows,
      linux => Platform.isLinux,
      macos || ios => Platform.isMacOS,
      android => true,
    };
    if (!supported) {
      throw AutomationError(
        'unsupported_host',
        '$name requires its native host',
      );
    }
  }
}
