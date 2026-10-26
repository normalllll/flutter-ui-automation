import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_capture_lab/src/automation_binding.dart';

void main() {
  final binding = AutomationBinding((_) async => '{}');

  test(
    'foreground simulation preserves real events and restores latest state',
    () {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.setPretendForeground(true);
      expect(binding.lifecycleState, AppLifecycleState.resumed);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(binding.rawLifecycle, AppLifecycleState.hidden);
      expect(binding.lifecycleState, AppLifecycleState.resumed);
      final viewId = binding.platformDispatcher.views.first.viewId;
      binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: viewId,
          state: ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      expect(binding.rawViewFocus[viewId]!.state, ui.ViewFocusState.unfocused);
      binding.setPretendForeground(false);
      expect(binding.lifecycleState, AppLifecycleState.hidden);
      expect(binding.rawLifecycle, AppLifecycleState.hidden);
    },
  );

  test('focus guard follows the explicit simulation mode', () {
    binding.setPretendForeground(false);
    expect(FocusManager.instance.rootScope.canRequestFocus, isFalse);
    binding.setPretendForeground(true);
    expect(FocusManager.instance.rootScope.canRequestFocus, isTrue);
    binding.setPretendForeground(false);
    expect(FocusManager.instance.rootScope.canRequestFocus, isFalse);
  });

  test('real view focus remains usable when simulation is off', () {
    final id = binding.platformDispatcher.views.first.viewId;
    binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: id,
        state: ui.ViewFocusState.focused,
        direction: ui.ViewFocusDirection.undefined,
      ),
    );
    expect(FocusManager.instance.rootScope.canRequestFocus, isTrue);
    binding.setPretendForeground(true);
    binding.setPretendForeground(false);
    expect(FocusManager.instance.rootScope.canRequestFocus, isTrue);
    binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: id,
        state: ui.ViewFocusState.unfocused,
        direction: ui.ViewFocusDirection.undefined,
      ),
    );
    expect(FocusManager.instance.rootScope.canRequestFocus, isFalse);
  });

  test(
    'disabling simulation preserves user activation received while enabled',
    () {
      final id = binding.platformDispatcher.views.first.viewId;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.setPretendForeground(true);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: id,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      binding.setPretendForeground(false);
      expect(binding.pretendForeground, isFalse);
      expect(binding.lifecycleState, AppLifecycleState.resumed);
      expect(binding.rawLifecycle, AppLifecycleState.resumed);
      expect(binding.rawViewFocus[id]!.state, ui.ViewFocusState.focused);
      expect(FocusManager.instance.rootScope.canRequestFocus, isTrue);
    },
  );
}
