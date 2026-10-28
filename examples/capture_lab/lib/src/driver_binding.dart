import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test-only Driver integration. Leaves focus and lifecycle events untouched.
class DriverBinding extends WidgetsFlutterBinding
    with TestDefaultBinaryMessengerBinding {
  DriverBinding(this.handler);

  final DataHandler handler;
  final ValueNotifier<int> changes = ValueNotifier(0);
  bool get pretendForeground => false;
  AppLifecycleState? get rawLifecycle => lifecycleState;
  Map<int, ui.ViewFocusEvent> get rawViewFocus => const {};

  void initializePlatformState({
    required bool visible,
    required bool isForeground,
  }) {}

  void setPretendForeground(bool enabled) {
    throw UnsupportedError(
      'Foreground simulation is a Windows-only test capability',
    );
  }

  @override
  void initServiceExtensions() {
    super.initServiceExtensions();
    // Same test-only extension API as the SDK's standard Driver binding.
    // Text entry emulation starts disabled so the real platform text input is
    // the baseline; the controller enables it explicitly and restores it.
    // ignore: invalid_use_of_visible_for_testing_member
    final extension = FlutterDriverExtension(handler, false, false);
    // ignore: invalid_use_of_visible_for_testing_member
    registerServiceExtension(name: 'driver', callback: extension.call);
  }
}
