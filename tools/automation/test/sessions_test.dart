import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/sessions.dart';
import 'package:flutter_ui_automation/src/windows.dart';

class TestHost extends Host {
  int calls = 0;
  final commands = <List<String>>[];
  Future<void> Function()? onRun;
  Future<HostResult> Function(List<String>)? handle;

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
    commands.add(arguments);
    await onRun?.call();
    if (handle != null) return handle!(arguments);
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
  int restores = 0;
  Json snapshot = {};

  @override
  Future<Json> state() async => snapshot;

  @override
  Future<Json> hook(String command, [Json arguments = const {}]) async {
    restores++;
    return {};
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

class AppBridge extends OfficialBridge {
  AppBridge(this.state) : super((_) {});
  final Json state;
  final commands = <String>[];

  @override
  Future<Json> tool(String name, Json arguments) async {
    final command = arguments.text('command');
    commands.add(command);
    if (command != 'callMethod') return toolResult({});
    return toolResult(switch (arguments.text('method')) {
      'getVM' => {
        'isolates': [
          {'name': 'main', 'id': 'isolates/1'},
        ],
      },
      'getIsolate' => {
        'extensionRPCs': ['ext.flutter.driver'],
      },
      'ext.flutter.driver' => {
        'response': arguments.child('arguments')['command'] == 'request_data'
            ? {'message': jsonEncode(state)}
            : <String, Object?>{},
      },
      _ => throw StateError('Unexpected VM request: $arguments'),
    });
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
    expect(host.calls, 0);
    expect(connection.restores, 0);
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

  test('session IDs cannot escape storage through open or recover', () async {
    for (final id in [
      '../other',
      r'..\other',
      '/absolute',
      'C:\\other',
      'a/b',
      '',
    ]) {
      await expectLater(
        sessions.open({'sessionId': id}, Cancellation()),
        throwsA(code('invalid_session')),
      );
      await expectLater(
        sessions.recover(id, stopOwned: true),
        throwsA(code('invalid_session')),
      );
    }
    expect(host.calls, 0);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'different session names cannot claim the same Android target',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      host.onRun = () async {
        entered.complete();
        await release.future;
      };
      final first = sessions.open({
        'sessionId': 'one',
        'platform': 'android',
        'deviceId': 'host:5555',
        'package': 'test.fixture',
      }, Cancellation());
      final firstFinished = expectLater(first, throwsA(code('device_offline')));
      await entered.future;
      final leases = Directory(p.join(directory.path, 'leases'));
      final claim = File(
        p.join((await leases.list().toList()).single.path, 'owner'),
      );
      final original = await claim.readAsString();
      try {
        await expectLater(
          sessions.open({
            'sessionId': 'two',
            'platform': 'android',
            'deviceId': 'host:5555',
            'package': 'test.fixture',
          }, Cancellation()),
          throwsA(code('session_leased')),
        );
        expect(await claim.readAsString(), original);
        expect(host.calls, 1);
      } finally {
        release.complete();
        await firstFinished;
      }
      expect(await leases.list().toList(), isEmpty);
    },
  );

  test(
    'device IDs stay distinct and cannot escape the hashed lease root',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var waiting = 0;
      host.onRun = () async {
        if (++waiting == 3) entered.complete();
        await release.future;
      };
      final finished = <Future<void>>[];
      final devices = ['host:5555', 'host_5555', '../other'];
      for (var i = 0; i < devices.length; i++) {
        finished.add(
          expectLater(
            sessions.open({
              'sessionId': 'device-$i',
              'platform': 'android',
              'deviceId': devices[i],
              'package': 'test.fixture',
            }, Cancellation()),
            throwsA(code('device_offline')),
          ),
        );
      }
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        final leases = Directory(p.join(directory.path, 'leases'));
        final entries = await leases.list().toList();
        expect(entries, hasLength(3));
        for (final entry in entries) {
          expect(p.isWithin(leases.path, entry.path), true);
          expect(p.basename(entry.path), matches(RegExp(r'^[a-f0-9]{20}$')));
        }
      } finally {
        release.complete();
        await Future.wait(finished);
      }
    },
  );

  HostResult output(String value) => HostResult(0, utf8.encode(value), '');

  Future<void> claimCurrent() async {
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
  }

  Session androidSession({required bool owned}) => Session(
    id: current.id,
    platform: TargetPlatform.android,
    project: directory.path,
    entrypoint: 'lib/android_driver_main.dart',
    directory: directory,
    lease: current.lease,
    owned: owned,
    connection: connection,
    android: AndroidDevice(
      host,
      sessions.tools,
      'selected-device',
      'test.fixture',
    ),
  )..androidIdentity = {'pid': 123, 'startTicks': 'old'};

  void deviceProcess(int nativePid, String startTicks) {
    host.handle = (arguments) async {
      if (arguments.contains('pidof')) return output('$nativePid');
      if (arguments.last == '/proc/$nativePid/stat') {
        return output(
          '$nativePid (fixture) S ${List.filled(18, '0').join(' ')} $startTicks',
        );
      }
      throw StateError('Unexpected device command: $arguments');
    };
  }

  test('attached stop only disconnects and releases its lease', () async {
    connection.snapshot = {
      'native': <String, Object?>{'pid': 123},
    };
    deviceProcess(123, 'old');
    sessions.active[current.id] = androidSession(owned: false);
    await claimCurrent();
    final result = await sessions.close(current.id);
    expect(result['appStopped'], false);
    expect(result['detached'], true);
    expect(connection.disconnects, 2);
    expect(connection.restores, 0);
    expect(
      host.commands.every(
        (args) => args.contains('pidof') || args.last == '/proc/123/stat',
      ),
      true,
    );
    expect(await current.lease.exists(), false);
  });

  for (final replacement in [
    (pid: 456, ticks: 'new'),
    (pid: 123, ticks: 'new'),
  ]) {
    test(
      'owned stop rejects a replacement Android process: $replacement',
      () async {
        connection.snapshot = {
          'native': <String, Object?>{'pid': 123},
        };
        deviceProcess(replacement.pid, replacement.ticks);
        final stale = androidSession(owned: true)..simulated = true;
        sessions.active[current.id] = stale;
        await claimCurrent();
        await expectLater(
          sessions.close(current.id),
          throwsA(code('target_changed')),
        );
        expect(await current.lease.exists(), true);
        expect(sessions.active[current.id], same(stale));
        expect(connection.disconnects, 0);
        expect(connection.restores, 0);
        expect(host.commands.any((args) => args.contains('force-stop')), false);
      },
    );
  }

  test('an already exited owned process can still release its lease', () async {
    connection.snapshot = {
      'native': <String, Object?>{'pid': 123},
    };
    sessions.active[current.id] = androidSession(owned: true);
    await claimCurrent();
    final result = await sessions.close(current.id);
    expect(result['appStopped'], true);
    expect(await current.lease.exists(), false);
    expect(sessions.active, isEmpty);
    expect(host.commands.any((args) => args.contains('force-stop')), false);
  });

  test(
    'recycled Windows PID cannot restore or stop the current process',
    () async {
      final native = WindowsApi().identity(pid)!;
      final stale = Session(
        id: current.id,
        platform: TargetPlatform.windows,
        project: directory.path,
        entrypoint: 'lib/driver_main.dart',
        directory: directory,
        lease: current.lease,
        owned: true,
        connection: connection,
        windowsIdentity: WindowsIdentity(pid, native.created + 1, native.image),
      )..simulated = true;
      sessions.active[current.id] = stale;
      await claimCurrent();
      await expectLater(
        sessions.close(current.id),
        throwsA(code('target_changed')),
      );
      expect(native.same(WindowsApi().identity(pid)), true);
      expect(connection.restores, 0);
      expect(connection.disconnects, 0);
      expect(await current.lease.exists(), true);
    },
    skip: !Platform.isWindows,
  );

  test(
    'attach rejects a VM token from another device and releases the claim',
    () async {
      host.handle = (arguments) async {
        expect(arguments.take(2), ['-s', 'selected-device']);
        if (arguments.last == 'get-state') return output('device');
        if (arguments.contains('run-as')) {
          return output('selected-device-token');
        }
        throw StateError('Unexpected device command: $arguments');
      };
      final bridge = AppBridge({
        'native': <String, Object?>{
          'pid': 123,
          'package': 'test.fixture',
          'instanceToken': 'other-device-token',
        },
      });
      final targets = Sessions(host, sessions.tools, bridge);
      await expectLater(
        targets.open(
          {
            'sessionId': 'wrong-device',
            'platform': 'android',
            'deviceId': 'selected-device',
            'package': 'test.fixture',
            'vmUri': 'ws://127.0.0.1:1234/other=/ws',
          },
          Cancellation(),
          attach: true,
        ),
        throwsA(code('wrong_instance')),
      );
      expect(targets.active, isEmpty);
      expect(bridge.commands.last, 'disconnect');
      expect(
        await Directory(p.join(directory.path, 'leases')).list().toList(),
        isEmpty,
      );
      expect(host.commands.any((args) => args.contains('force-stop')), false);
    },
  );

  test(
    'failed metadata save releases its claim without publishing a live session',
    () async {
      host.handle = (arguments) async {
        if (arguments.last == 'get-state') return output('device');
        if (arguments.contains('run-as')) {
          return output('selected-device-token');
        }
        if (arguments.contains('pidof')) return output('123');
        if (arguments.last == '/proc/123/stat') {
          return output(
            '123 (fixture) S ${List.filled(18, '0').join(' ')} old',
          );
        }
        throw StateError('Unexpected device command: $arguments');
      };
      final bridge = AppBridge({
        'native': <String, Object?>{
          'pid': 123,
          'package': 'test.fixture',
          'instanceToken': 'selected-device-token',
        },
      });
      final targets = Sessions(host, sessions.tools, bridge);
      final arguments = <String, Object?>{
        'sessionId': 'retry',
        'platform': 'android',
        'deviceId': 'selected-device',
        'package': 'test.fixture',
        'vmUri': 'ws://127.0.0.1:1234/original=/ws',
      };
      final obstacle = Directory(
        p.join(directory.path, 'sessions', 'retry', 'session.json'),
      );
      await obstacle.create(recursive: true);
      try {
        await expectLater(
          targets.open(arguments, Cancellation(), attach: true),
          throwsA(isA<FileSystemException>()),
        );
        expect(targets.active, isEmpty);
        expect(bridge.commands.last, 'disconnect');
        final leases = Directory(p.join(directory.path, 'leases'));
        expect(await leases.list().toList(), isEmpty);
        expect(host.commands.any((args) => args.contains('force-stop')), false);

        await obstacle.delete();
        final opened = await targets.open(
          arguments,
          Cancellation(),
          attach: true,
        );
        expect(targets.get('retry'), same(opened));
        expect(await File(obstacle.path).exists(), true);
        expect(await leases.list().toList(), hasLength(1));
        await targets.close('retry');
        expect(await leases.list().toList(), isEmpty);
      } finally {
        await targets.closeAll();
      }
    },
  );
}
