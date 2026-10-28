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

enum TestMode {
  textEmulation('textEmulation'),
  foreground('simulated'),
  orientation('orientationChanged');

  const TestMode(this.field);
  final String field;
  Json arguments(bool enabled) => {
    'action': name,
    'settle': false,
    if (this == orientation)
      'value': enabled ? 'landscape' : 'restore'
    else
      'enabled': enabled,
  };
}

class ModeConnection extends FlutterConnection {
  ModeConnection()
    : super(OfficialBridge((_) {}), 'ws://unused', HookProtocol.fixture);
  bool enabled = false, failEnableReply = false, failDisable = false;
  int disableAttempts = 0;
  Future<void> Function()? beforeEnable;

  Json snapshot() => {
    'native': <String, Object?>{'pid': 42},
    'view': {'width': enabled ? 800 : 400, 'height': enabled ? 400 : 800},
  };
  Future<Json> change(bool value) async {
    if (value) {
      await beforeEnable?.call();
      enabled = true;
      if (failEnableReply) {
        throw const AutomationError(
          'reply_failed',
          'Enable applied but reply lost',
        );
      }
    } else {
      disableAttempts++;
      if (failDisable) {
        failDisable = false;
        throw const AutomationError(
          'restore_failed',
          'Disable did not complete',
        );
      }
      enabled = false;
    }
    return snapshot();
  }

  @override
  Future<Json> driver(Json arguments) {
    expect(arguments['command'], 'set_text_entry_emulation');
    return change(arguments['enabled'] == 'true');
  }

  @override
  Future<Json> hook(String command, [Json arguments = const {}]) =>
      switch (command) {
        'pretendForeground' => change(arguments.flag('enabled')),
        'orientation' => change(arguments['value'] != 'restore'),
        _ => throw StateError('Unexpected hook: $command'),
      };
  @override
  Future<void> disconnect() async {}
}

class ModeDevice extends AndroidDevice {
  ModeDevice(Host host, Toolchain tools)
    : super(host, tools, 'selected-device', 'test.fixture');
  @override
  Future<Json?> identity() async => {'pid': 42, 'startTicks': '1'};
}

class ModeSession extends Session {
  ModeSession(
    TestMode mode,
    Directory directory,
    ModeConnection connection,
    Host host,
    Toolchain tools,
  ) : super(
        id: 'mode',
        platform: mode == TestMode.foreground
            ? TargetPlatform.windows
            : TargetPlatform.android,
        project: directory.path,
        entrypoint: 'test.dart',
        directory: directory,
        lease: Directory(p.join(directory.path, 'lease')),
        owned: false,
        connection: connection,
        android: ModeDevice(host, tools),
      ) {
    androidIdentity = {'pid': 42, 'startTicks': '1'};
    lastState = connection.snapshot();
  }
  @override
  Future<Json> state() async =>
      lastState = (connection as ModeConnection).snapshot();
}

void main() {
  for (final mode in TestMode.values) {
    group(mode.name, () {
      late Directory directory;
      late ModeConnection connection;
      late ModeSession session;
      late AutomationRuntime runtime;
      setUp(() async {
        directory = await Directory.systemTemp.createTemp('automation-modes-');
        final host = Host(),
            tools = Toolchain(directory.path, flutterRoot: directory.path);
        connection = ModeConnection();
        session = ModeSession(mode, directory, connection, host, tools);
        connection.beforeEnable = () async {
          final metadata = decodeObject(
            await File(p.join(directory.path, 'session.json')).readAsString(),
          );
          expect(
            metadata[mode.field],
            true,
            reason: 'Cleanup responsibility must be durable before dispatch',
          );
        };
        runtime = AutomationRuntime(host, tools, OfficialBridge((_) {}));
        runtime.sessions.active[session.id] = session;
      });
      tearDown(() async {
        await runtime.close();
        final resolved = await directory.resolveSymbolicLinks();
        if (!p.isWithin(
          await Directory.systemTemp.resolveSymbolicLinks(),
          resolved,
        )) {
          throw StateError('Unexpected test cleanup path');
        }
        await Directory(resolved).delete(recursive: true);
      });

      test(
        'failed disable retains cleanup responsibility for session close',
        () async {
          await runtime.drive(session, mode.arguments(true), Cancellation());
          connection.failDisable = true;
          await expectLater(
            runtime.drive(session, mode.arguments(false), Cancellation()),
            throwsA(
              isA<AutomationError>().having(
                (e) => e.code,
                'code',
                'restore_failed',
              ),
            ),
          );
          expect(session.toJson()[mode.field], true);
          expect(connection.enabled, true);
          final metadata = decodeObject(
            await File(p.join(directory.path, 'session.json')).readAsString(),
          );
          expect(metadata[mode.field], true);
          final stopped = await runtime.sessions.close(session.id);
          expect(stopped['detached'], true);
          expect(connection.enabled, false);
          expect(connection.disableAttempts, 2);
        },
      );

      test(
        'lost enable reply remains durable and is restored on close',
        () async {
          connection.failEnableReply = true;
          await expectLater(
            runtime.drive(session, mode.arguments(true), Cancellation()),
            throwsA(
              isA<AutomationError>().having(
                (e) => e.code,
                'code',
                'reply_failed',
              ),
            ),
          );
          expect(connection.enabled, true);
          expect(session.toJson()[mode.field], true);
          final metadata = decodeObject(
            await File(p.join(directory.path, 'session.json')).readAsString(),
          );
          expect(metadata[mode.field], true);
          await runtime.sessions.close(session.id);
          expect(connection.enabled, false);
          expect(connection.disableAttempts, 1);
        },
      );

      test('raw request and driver cannot bypass mode tracking', () async {
        final raw = switch (mode) {
          TestMode.textEmulation => {
            'action': 'driver',
            'settle': false,
            'arguments': {
              'command': 'set_text_entry_emulation',
              'enabled': 'true',
            },
          },
          TestMode.foreground => {
            'action': 'request',
            'settle': false,
            'value': 'pretendForeground',
            'arguments': {'enabled': true},
          },
          TestMode.orientation => {
            'action': 'driver',
            'settle': false,
            'arguments': {
              'command': 'request_data',
              'message': '{"command":"orientation","value":"landscape"}',
            },
          },
        };
        await expectLater(
          runtime.drive(session, raw, Cancellation()),
          throwsA(
            isA<AutomationError>().having(
              (e) => e.code,
              'code',
              'tracked_mode',
            ),
          ),
        );
        expect(connection.enabled, false);
        expect(session.toJson()[mode.field], false);
      });
    });
  }
}
