import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/sessions.dart';
import 'package:flutter_ui_automation/src/windows.dart';

class TestHost extends Host {
  int calls = 0;
  Future<void> Function()? onRun;

  @override
  Future<HostResult> run(
    String executable,
    List<String> arguments, {
    String? directory,
    Duration timeout = const Duration(seconds: 30),
    Cancellation? cancellation,
    bool check = true,
  }) async {
    calls++;
    await onRun?.call();
    return HostResult(1, Uint8List(0), '');
  }
}

class TestConnection extends FlutterConnection {
  TestConnection()
    : super(
        OfficialBridge((_) => throw StateError('Unexpected VM request')),
        'ws://127.0.0.1:1234/original=/ws',
        HookProtocol.fixture,
      );
  int disconnects = 0;

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

class TestSession extends Session {
  TestSession(Directory directory, TestConnection connection)
    : super(
        id: 'current',
        platform: TargetPlatform.windows,
        project: directory.path,
        entrypoint: 'lib/driver_main.dart',
        directory: directory,
        lease: Directory(p.join(directory.path, 'leases', 'shared')),
        owned: false,
        connection: connection,
      );
  int observations = 0;

  @override
  Future<Json> state() async {
    observations++;
    return {};
  }
}

void main() {
  late Directory directory;
  late TestHost host;
  late Sessions sessions;
  late TestConnection connection;
  late TestSession current;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('automation-sessions-');
    host = TestHost();
    final tools = Toolchain(
      directory.path,
      flutterRoot: directory.path,
      artifacts: directory.path,
      environment: {'ADB': Platform.resolvedExecutable},
    );
    sessions = Sessions(host, tools, OfficialBridge((_) {}));
    connection = TestConnection();
    current = TestSession(directory, connection);
    sessions.active[current.id] = current;
  });

  tearDown(() async {
    final resolved = await directory.resolveSymbolicLinks();
    if (!p.isWithin(
      await Directory.systemTemp.resolveSymbolicLinks(),
      resolved,
    )) {
      throw StateError('Unexpected test cleanup path');
    }
    await Directory(resolved).delete(recursive: true);
  });

  Matcher code(String value) =>
      isA<AutomationError>().having((error) => error.code, 'code', value);

  for (final conflict in <Json>[
    {'vmUri': 'ws://127.0.0.1:1234/different=/ws'},
    {'vmUri': 'ftp://127.0.0.1:1234/original=/ws'},
    {'hooks': 'booruflow'},
    {'entrypoint': 'lib/another_main.dart'},
  ]) {
    test(
      'session reuse rejects explicit ${conflict.keys.single} conflict',
      () async {
        await expectLater(
          sessions.open(
            {'sessionId': current.id, ...conflict},
            Cancellation(),
            attach: true,
          ),
          throwsA(code('session_conflict')),
        );
        expect(current.observations, 0);
        expect(host.calls, 0);
      },
    );
  }

  test(
    'session reuse accepts the equivalent HTTP VM service endpoint',
    () async {
      final reused = await sessions.open(
        {
          'sessionId': current.id,
          'vmUri': 'http://127.0.0.1:1234/original=/',
          'hooks': 'fixture',
          'entrypoint': p.join(directory.path, 'lib', '.', 'driver_main.dart'),
        },
        Cancellation(),
        attach: true,
      );
      expect(reused, same(current));
      expect(current.observations, 1);
    },
  );

  const oldSupervisor = <String, Object?>{
    'pid': 4294967294,
    'created': 1,
    'image': r'C:\dead\service.exe',
  };
  final oldOwner = <String, Object?>{
    'sessionId': 'old',
    'pid': oldSupervisor['pid'],
    'identity': oldSupervisor,
  };

  Future<File> retained(Json owner) async {
    final lease = current.lease;
    await lease.create(recursive: true);
    final claim = File(p.join(lease.path, 'owner'));
    await claim.writeAsString(jsonEncode(owner));
    final metadata = File(
      p.join(directory.path, 'sessions', 'old', 'session.json'),
    );
    await metadata.parent.create(recursive: true);
    await metadata.writeAsString(
      jsonEncode({
        'supervisor': oldSupervisor,
        'lease': lease.path,
        'platform': 'android',
        'owned': false,
        'deviceId': 'selected-device',
        'package': 'test.fixture',
        'androidIdentity': {'pid': 123, 'startTicks': 'old'},
        'native': <String, Object?>{},
      }),
    );
    return claim;
  }

  group('recovery ownership', () {
    for (final replacement in <Json>[
      {...oldOwner, 'sessionId': 'new-live-session'},
      {...oldOwner, 'pid': 123},
      {
        ...oldOwner,
        'identity': {...oldSupervisor, 'created': 2},
      },
      {
        ...oldOwner,
        'identity': {...oldSupervisor, 'image': r'C:\other.exe'},
      },
    ]) {
      test(
        'rejects a replacement owner before device or VM access: $replacement',
        () async {
          final claim = await retained(replacement);
          await expectLater(
            sessions.recover('old', stopOwned: true),
            throwsA(code('lease_not_owned')),
          );
          expect(host.calls, 0);
          expect(decodeObject(await claim.readAsString()), replacement);
        },
      );
    }

    test('releases a matching abandoned lease', () async {
      await retained(oldOwner);
      final result = await sessions.recover('old', stopOwned: false);
      expect(result['recovered'], true);
      expect(await current.lease.exists(), false);
      expect(host.calls, 1);
    });

    test('rechecks the owner after awaited recovery work', () async {
      final claim = await retained(oldOwner);
      final replacement = {...oldOwner, 'sessionId': 'new-live-session'};
      host.onRun = () => claim.writeAsString(jsonEncode(replacement));
      await expectLater(
        sessions.recover('old', stopOwned: true),
        throwsA(code('lease_not_owned')),
      );
      expect(host.calls, 1);
      expect(decodeObject(await claim.readAsString()), replacement);
    });

    test('a missing claim does not authorize recovery side effects', () async {
      final claim = await retained(oldOwner);
      await claim.delete();
      await expectLater(
        sessions.recover('old', stopOwned: true),
        throwsA(code('lease_not_owned')),
      );
      expect(host.calls, 0);
    });
  }, skip: !Platform.isWindows);

  test('close preserves a replacement lease before touching the app', () async {
    final claim = await retained({...oldOwner, 'sessionId': 'replacement'});
    await expectLater(
      sessions.close(current.id),
      throwsA(code('lease_not_owned')),
    );
    expect(await claim.exists(), true);
    expect(current.observations, 0);
    expect(connection.disconnects, 0);
    expect(sessions.active[current.id], same(current));
  });

  test('close releases its matching lease', () async {
    await current.lease.create(recursive: true);
    await File(p.join(current.lease.path, 'owner')).writeAsString(
      jsonEncode({
        'sessionId': current.id,
        'pid': pid,
        'identity': Platform.isWindows
            ? WindowsApi().identity(pid)?.toJson()
            : null,
      }),
    );
    final result = await sessions.close(current.id);
    expect(result['detached'], true);
    expect(await current.lease.exists(), false);
    expect(sessions.active, isEmpty);
  });

  test('failed open releases only its own claim', () async {
    await expectLater(
      sessions.open({
        'sessionId': 'failed',
        'platform': 'android',
        'deviceId': 'selected-device',
        'package': 'test.fixture',
      }, Cancellation()),
      throwsA(code('device_offline')),
    );
    expect(
      await Directory(p.join(directory.path, 'leases')).list().toList(),
      isEmpty,
    );
  });
}
