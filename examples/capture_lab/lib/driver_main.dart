import 'package:flutter/material.dart';

import 'src/automation_binding.dart';
import 'src/lab_app.dart';

void main() {
  final labKey = GlobalKey<CaptureLabState>();
  AutomationBinding((message) async {
    final state = labKey.currentState;
    if (state == null) throw StateError('Application is not ready');
    return state.handleRequest(message);
  });
  runApp(CaptureLab(key: labKey));
}
