import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/runtime.dart';
import 'package:flutter_ui_automation/src/sessions.dart';

class KeyboardConnection extends FlutterConnection {
  KeyboardConnection(this.page)
    : super(OfficialBridge((_) {}), 'ws://unused', HookProtocol.fixture);
  String page;
  bool keyboardVisible = false, emulated = true;
  final taps = <String>[];

  Json snapshot() => {
    'page': page,
    'native': <String, Object?>{},
    'view': {'keyboardInset': keyboardVisible ? 300 : 0},
  };

  @override
  Future<Json> driver(Json arguments) async {
    switch (arguments.text('command')) {
      case 'request_data':
        final request = decodeObject(arguments.text('message'));
        switch (request.text('command')) {
          case 'unfocus':
            keyboardVisible = false;
          case 'state':
          case 'settle':
            break;
          default:
            throw StateError('Unexpected hook: $request');
        }
        return {'message': jsonEncode(snapshot())};
      case 'set_text_entry_emulation':
        emulated = arguments['enabled'] == 'true';
        return {};
      case 'tap':
        final key = arguments.text('keyValueString');
        taps.add(key);
        if (key == 'nav-interaction') {
          page = 'interaction';
        } else if (key == 'input-field' && page == 'interaction') {
          if (emulated) {
            throw StateError('Native keyboard requires the real IME');
          }
          keyboardVisible = true;
        } else {
          throw StateError('Widget $key is absent on $page');
        }
        return {};
      default:
        throw StateError('Unexpected Driver command: $arguments');
    }
  }
}

class KeyboardDevice extends AndroidDevice {
  KeyboardDevice(Host host, Toolchain tools, this.connection)
    : super(host, tools, 'selected-device', 'test.fixture');
  final KeyboardConnection connection;
  int backCount = 0;
  @override
  Future<void> back(Cancellation cancellation) async {
    backCount++;
    connection.keyboardVisible = false;
  }
}

class KeyboardSession extends Session {
  KeyboardSession(
    Toolchain tools,
    Directory directory,
    KeyboardConnection connection,
    KeyboardDevice device,
  ) : super(
        id: 'keyboard',
        platform: TargetPlatform.android,
        project: tools.fixture,
        entrypoint: 'lib/android_driver_main.dart',
        directory: directory,
        lease: Directory(p.join(directory.path, 'lease')),
        owned: false,
        connection: connection,
        android: device,
      );
  @override
  Future<Json> state() => connection.state();
  @override
  Future<void> save() async {}
}

class KeyboardRuntime extends AutomationRuntime {
  KeyboardRuntime(super.host, super.tools, super.official);
  int captures = 0;
  @override
  Future<Json> capture(
    Session session,
    Json args,
    Cancellation cancellation,
  ) async {
    final state = await session.state();
    expect(state['page'], 'interaction');
    expect(state.child('view')['keyboardInset'], greaterThan(0));
    captures++;
    return toolResult({
      'items': [
        for (final channel in ['app', 'native'])
          {'channel': channel, 'passed': true, 'result': <String, Object?>{}},
      ],
    });
  }
}

void main() {
  for (final page in ['overview', 'gallery', 'scenarios']) {
    test('native keyboard check reruns independently from $page', () async {
      final directory = await Directory.systemTemp.createTemp(
        'automation-keyboard-',
      );
      final host = Host();
      final tools = Toolchain(directory.path, flutterRoot: directory.path);
      final connection = KeyboardConnection(page);
      final device = KeyboardDevice(host, tools, connection);
      final runtime = KeyboardRuntime(host, tools, OfficialBridge((_) {}));
      final session = KeyboardSession(tools, directory, connection, device);
      try {
        final result = await runtime.verify(session, {
          'checks': ['native-keyboard'],
        }, Cancellation());
        expect(result['passed'], true, reason: jsonEncode(result));
        expect(connection.taps, ['nav-interaction', 'input-field']);
        expect(connection.emulated, false);
        expect(connection.keyboardVisible, false);
        expect(device.backCount, 1);
        expect(runtime.captures, 1);
        expect(
          result.items('items').map(object).map((item) => item['channel']),
          ['native-keyboard/app', 'native-keyboard/native', 'native-keyboard'],
        );
      } finally {
        await runtime.close();
        final resolved = await directory.resolveSymbolicLinks();
        if (!p.isWithin(
          await Directory.systemTemp.resolveSymbolicLinks(),
          resolved,
        )) {
          throw StateError('Unexpected test cleanup path');
        }
        await Directory(resolved).delete(recursive: true);
      }
    });
  }
}
