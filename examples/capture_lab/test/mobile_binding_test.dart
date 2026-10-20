import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_capture_lab/src/driver_binding.dart';

void main() {
  final binding = DriverBinding((_) async => '{}');

  test('mobile Driver preserves actual lifecycle and permits input focus', () {
    expect(FocusManager.instance.rootScope.canRequestFocus, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(binding.rawLifecycle, AppLifecycleState.resumed);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(binding.lifecycleState, AppLifecycleState.paused);
    expect(binding.rawLifecycle, AppLifecycleState.paused);
    expect(binding.pretendForeground, isFalse);
    expect(() => binding.setPretendForeground(true), throwsUnsupportedError);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(binding.lifecycleState, AppLifecycleState.resumed);
  });
}
