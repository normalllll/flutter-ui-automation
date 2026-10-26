import 'dart:async';

import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

void main() {
  test(
    'late internal reply is not forwarded as an external client response',
    () async {
      final sent = Completer<Json>();
      final bridge = OfficialBridge(sent.complete);
      bridge.ready.complete();
      final request = bridge.request(
        'tools/list',
        {},
        timeout: const Duration(milliseconds: 2),
      );
      final frame = await sent.future;
      await expectLater(request, throwsA(isA<TimeoutException>()));
      expect(
        bridge.receive({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': <String, Object?>{},
        }),
        true,
      );
      expect(
        bridge.receive({
          'jsonrpc': '2.0',
          'id': 'external-request',
          'result': <String, Object?>{},
        }),
        false,
      );
    },
  );
}
