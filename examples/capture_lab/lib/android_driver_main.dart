import 'package:flutter/material.dart';

import 'src/driver_binding.dart';
import 'src/lab_app.dart';

void main() {
  final labKey = GlobalKey<CaptureLabState>();
  DriverBinding((message) async {
    final state = labKey.currentState;
    if (state == null) throw StateError('Application is not ready');
    return state.handleRequest(message);
  });
  runApp(CaptureLab(key: labKey));
}
