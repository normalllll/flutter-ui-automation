import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

class BootingApp extends FlutterConnection {
  BootingApp()
    : super(OfficialBridge((_) {}), 'ws://unused', HookProtocol.fixture);
  int observations = 0;
  @override
  Future<void> rebind() async {}
  @override
  Future<Json> state() async {
    observations++;
    if (observations == 1) {
      throw const AutomationError('driver_failed', 'Application is not ready');
    }
    if (observations == 2) return {'ready': false};
    return {
      'ready': true,
      'native': <String, Object?>{'pid': 123},
    };
  }
}

void main() {
  test(
    'restart readiness retries read-only bootstrap state, not UI actions',
    () async {
      final app = BootingApp();
      await app.waitReady();
      expect(app.observations, 3);
    },
  );
}
