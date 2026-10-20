import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'driver_binding.dart';

/// Test-only binding. Redirects framework notifications, never Windows focus.
class AutomationBinding extends DriverBinding {
  AutomationBinding(super.handler) {
    FocusManager.instance.rootScope.canRequestFocus = false;
  }
  @override
  bool pretendForeground = false;
  @override
  AppLifecycleState? rawLifecycle;
  @override
  final Map<int, ui.ViewFocusEvent> rawViewFocus = {};

  @override
  void initializePlatformState({
    required bool visible,
    required bool isForeground,
  }) {
    // A window that has never been activated can have no initial lifecycle
    // message. Seed that missing state from the runner's actual OS observation.
    if (rawLifecycle == null && visible) {
      // Do not introduce an artificial hidden lifecycle during the first show.
      handleAppLifecycleStateChanged(
        isForeground ? AppLifecycleState.resumed : AppLifecycleState.inactive,
      );
    }
  }

  @override
  bool debugCheckZone(String entryPoint) => true;

  @override
  void handleAppLifecycleStateChanged(AppLifecycleState state) {
    rawLifecycle = state;
    super.handleAppLifecycleStateChanged(
      pretendForeground ? AppLifecycleState.resumed : state,
    );
    changes.value++;
  }

  @override
  void handleViewFocusChanged(ui.ViewFocusEvent event) {
    rawViewFocus[event.viewId] = event;
    if (!pretendForeground && event.state == ui.ViewFocusState.unfocused) {
      FocusManager.instance.rootScope.canRequestFocus = false;
    }
    super.handleViewFocusChanged(
      pretendForeground ? _focused(event.viewId) : event,
    );
    if (!pretendForeground && event.state == ui.ViewFocusState.focused) {
      FocusManager.instance.rootScope.canRequestFocus = true;
    }
    changes.value++;
  }

  @override
  void setPretendForeground(bool enabled) {
    if (pretendForeground == enabled) return;
    pretendForeground = enabled;
    if (!enabled) FocusManager.instance.rootScope.canRequestFocus = false;
    // Replay actual platform state on disable. Do not request real view focus.
    final effective = enabled
        ? AppLifecycleState.resumed
        : (rawLifecycle ?? AppLifecycleState.inactive);
    super.handleAppLifecycleStateChanged(effective);
    SystemChrome.handleAppLifecycleStateChanged(effective);
    for (final view in platformDispatcher.views) {
      super.handleViewFocusChanged(
        enabled
            ? _focused(view.viewId)
            : (rawViewFocus[view.viewId] ??
                  ui.ViewFocusEvent(
                    viewId: view.viewId,
                    state: ui.ViewFocusState.unfocused,
                    direction: ui.ViewFocusDirection.undefined,
                  )),
      );
    }
    // Notify View's focus observer before enabling focus traversal. Otherwise
    // gaining framework focus would ask Windows to activate the real view.
    FocusManager.instance.rootScope.canRequestFocus =
        enabled ||
        rawViewFocus.values.any(
          (event) => event.state == ui.ViewFocusState.focused,
        );
    changes.value++;
  }

  ui.ViewFocusEvent _focused(int id) => ui.ViewFocusEvent(
    viewId: id,
    state: ui.ViewFocusState.focused,
    direction: ui.ViewFocusDirection.undefined,
  );
}
