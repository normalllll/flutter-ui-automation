import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/runtime.dart';
import 'package:flutter_ui_automation/src/sessions.dart';

class ContentConnection extends FlutterConnection {
  ContentConnection()
    : super(OfficialBridge((_) {}), 'ws://unused', HookProtocol.fixture);
  int screenshots = 0;
  final png = image.encodePng(image.Image(width: 2, height: 2));
  @override
  Future<Json> hook(String command, [Json arguments = const {}]) async {
    if (command == 'appScreenshot') {
      screenshots++;
      return {'png': base64Encode(png), 'width': 2, 'height': 2};
    }
    return {};
  }
}

class Device extends AndroidDevice {
  Device(Host host, Toolchain tools, this.connection)
    : super(host, tools, 'selected-device', 'test.fixture');
  final ContentConnection connection;
  @override
  Future<Json> screenshot(
    String output, {
    Json? probe,
    required Cancellation cancellation,
  }) async {
    await File(output).writeAsBytes(connection.png);
    return {'path': output, 'presentationVerified': false};
  }
}

class InterruptedSession extends Session {
  InterruptedSession(
    Directory directory,
    ContentConnection connection,
    Device device,
  ) : super(
        id: 'isolated',
        platform: TargetPlatform.android,
        project: directory.path,
        entrypoint: 'test.dart',
        directory: directory,
        lease: Directory('${directory.path}/lease'),
        owned: false,
        connection: connection,
        android: device,
      );
  var observations = 0;
  bool restored = false;
  @override
  Future<Json> state() async {
    if (++observations > 1 && !restored) {
      throw const AutomationError(
        'target_unavailable',
        'Target disappeared after app PNG',
      );
    }
    return {'native': <String, Object?>{}};
  }
}

void main() {
  test(
    'lost native target and final observation preserve app evidence; retry only native',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'automation-isolation-',
      );
      final host = Host(),
          tools = Toolchain(
            directory.path,
            flutterRoot: directory.path,
            artifacts: directory.path,
          );
      final connection = ContentConnection(),
          runtime = AutomationRuntime(host, tools, OfficialBridge((_) {}));
      final session = InterruptedSession(
        directory,
        connection,
        Device(host, tools, connection),
      );
      runtime.sessions.active[session.id] = session;
      try {
        final first = (await runtime.call('automation_capture', {
          'sessionId': session.id,
        }, Cancellation())).child('structuredContent');
        final items = first.items('items').map(object).toList();
        expect(items.first['passed'], true);
        expect(items[1]['passed'], false);
        expect(first.child('stateError')['code'], 'target_unavailable');
        final app = File(items.first.child('result').text('path'));
        expect(await app.exists(), true);
        final original = await app.readAsBytes();
        session.restored = true;
        final retry = (await runtime.call('automation_capture', {
          'sessionId': session.id,
          'channels': ['native'],
          'presentation': false,
        }, Cancellation())).child('structuredContent');
        expect(retry.items('items').map(object).single['channel'], 'native');
        expect(
          retry.items('items').map(object).single['passed'],
          true,
          reason: jsonEncode(retry),
        );
        expect(connection.screenshots, 1);
        expect(await app.readAsBytes(), original);
      } finally {
        session.restored = true;
        await runtime.close();
        // Files are enumerated and removed in Dart under the unique test folder.
        final resolved = await directory.resolveSymbolicLinks();
        if (!p.isWithin(
          await Directory.systemTemp.resolveSymbolicLinks(),
          resolved,
        )) {
          throw StateError('Unexpected test cleanup path');
        }
        await Directory(resolved).delete(recursive: true);
      }
    },
  );
}
