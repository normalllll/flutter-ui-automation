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
import 'package:flutter_ui_automation/src/unix_process.dart';
import 'package:flutter_ui_automation/src/unix_target.dart';

class TestHost extends Host {
  TestHost({super.environment});
  int calls = 0;
  final commands = <List<String>>[];
  Future<void> Function()? onRun;
  Future<HostResult> Function(List<String>)? handle;
  Future<Process> Function()? onStart;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? directory,
    Map<String, String> extraEnvironment = const {},
  }) =>
      onStart?.call() ??
      super.start(
        executable,
        arguments,
        directory: directory,
        extraEnvironment: extraEnvironment,
      );

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
  bool failRestore = false;

  @override
  Future<Json> state() async => snapshot;

  @override
  Future<Json> hook(String command, [Json arguments = const {}]) async {
    restores++;
    if (failRestore) {
      throw const AutomationError('restore_failed', 'Test failure');
    }
    return {};
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

class AppBridge extends OfficialBridge {
  AppBridge(this.state, {this.vmPid}) : super((_) {});
  final Json state;
  final int? vmPid;
  final commands = <String>[];
  final driverCommands = <String>[];

  @override
  Future<Json> tool(String name, Json arguments) async {
    final command = arguments.text('command');
    commands.add(command);
    if (arguments['method'] == 'ext.flutter.driver') {
      driverCommands.add(arguments.child('arguments').text('command'));
    }
    if (command != 'callMethod') return toolResult({});
    return toolResult(switch (arguments.text('method')) {
      'getVM' => {
        'pid': vmPid ?? state.child('native')['pid'],
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
  test('start cannot silently adopt an attached session ID', () async {
    await expectLater(
      sessions.open({'sessionId': current.id}, Cancellation()),
      throwsA(code('session_conflict')),
    );
    expect(current.observations, 0);
  });

  test('a second session cannot attach to an endpoint in use', () async {
    await expectLater(
      sessions.open(
        {
          'sessionId': 'other',
          'platform': 'windows',
          // Same endpoint in its HTTP spelling.
          'vmUri': 'http://127.0.0.1:1234/original=/',
        },
        Cancellation(),
        attach: true,
      ),
      throwsA(code('session_conflict')),
    );
    expect(host.calls, 0);
    expect(Directory(p.join(directory.path, 'leases')).existsSync(), false);
  });

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
            : UnixIdentity.read(pid)?.toJson(),
      }),
    );
    final result = await sessions.close(current.id);
    expect(result['detached'], true);
    expect(await current.lease.exists(), false);
    expect(sessions.active, isEmpty);
    expect(host.calls, 0);
    expect(connection.restores, 0);
  });

  test(
    'retained Unix recovery rejects a recycled VM endpoint before Driver changes',
    () async {
      final identity = UnixIdentity.read(pid)!;
      final supervisor = {
        'pid': 4294967294,
        'birth': 'dead',
        'image': '/dead/service',
      };
      await current.lease.create(recursive: true);
      final claim = File(p.join(current.lease.path, 'owner'));
      await claim.writeAsString(
        jsonEncode({
          'sessionId': 'old',
          'pid': supervisor['pid'],
          'identity': supervisor,
        }),
      );
      final metadata = File(
        p.join(directory.path, 'sessions', 'old', 'session.json'),
      );
      await metadata.parent.create(recursive: true);
      await metadata.writeAsString(
        jsonEncode({
          'supervisor': supervisor,
          'lease': current.lease.path,
          'platform': Platform.operatingSystem,
          'owned': false,
          'unixIdentity': identity.toJson(),
          'vmUri': 'ws://recycled',
          'hooks': 'fixture',
          'native': {'pid': pid, 'platform': Platform.operatingSystem},
        }),
      );
      final bridge = AppBridge({
        'native': <String, Object?>{'pid': pid + 1},
      });
      final targets = Sessions(host, sessions.tools, bridge);
      await expectLater(
        targets.recover('old', stopOwned: true),
        throwsA(code('cleanup_incomplete')),
      );
      expect(bridge.driverCommands, isEmpty);
      expect(await claim.exists(), true);
      identity.requireCurrent();
    },
    skip: Platform.isWindows,
  );

  test(
    'native state cannot replace the independently verified Unix VM process',
    () async {
      final host = TestHost(environment: {'DISPLAY': ':999'});
      final bridge = AppBridge({
        'native': <String, Object?>{
          'pid': pid + 1,
          'platform': Platform.operatingSystem,
        },
      }, vmPid: pid);
      final targets = Sessions(host, sessions.tools, bridge);
      await expectLater(
        targets.open(
          {
            'sessionId': 'forged-native',
            'platform': Platform.operatingSystem,
            'vmUri': 'ws://unused',
          },
          Cancellation(),
          attach: true,
        ),
        throwsA(code('target_changed')),
      );
      expect(targets.active, isEmpty);
      expect(UnixIdentity.read(pid), isNotNull);
      expect(
        await Directory(p.join(directory.path, 'leases')).list().toList(),
        isEmpty,
      );
    },
    skip: Platform.isWindows,
  );

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
            : UnixIdentity.read(pid)?.toJson(),
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

  test(
    'failed attached restore retains modes and lease for a successful retry',
    () async {
      connection.snapshot = {
        'native': <String, Object?>{'pid': 123},
      };
      deviceProcess(123, 'old');
      final attached = androidSession(owned: false)..orientationChanged = true;
      sessions.active[current.id] = attached;
      await claimCurrent();
      connection.failRestore = true;
      await expectLater(
        sessions.close(current.id),
        throwsA(code('cleanup_incomplete')),
      );
      expect(await current.lease.exists(), true);
      expect(attached.closing, false);
      expect(attached.orientationChanged, true);
      expect(connection.disconnects, 0);
      connection.failRestore = false;
      await sessions.close(current.id);
      expect(attached.orientationChanged, false);
      expect(await current.lease.exists(), false);
    },
  );

  test('lease release failure leaves the live session retryable', () async {
    connection.snapshot = {
      'native': <String, Object?>{'pid': 123},
    };
    deviceProcess(123, 'old');
    final attached = androidSession(owned: false);
    sessions.active[current.id] = attached;
    await claimCurrent();
    final obstacle = File(p.join(current.lease.path, 'unexpected'));
    await obstacle.writeAsString('preserve');
    await expectLater(
      sessions.close(current.id),
      throwsA(code('lease_not_empty')),
    );
    expect(attached.closing, false);
    expect(sessions.active[current.id], same(attached));
    await obstacle.delete();
    // The owner file must also remain available for retry.
    expect(await File(p.join(current.lease.path, 'owner')).exists(), true);
    await sessions.close(current.id);
  });

  test(
    'iOS instance validation rejects a VM from a different simulator before any action',
    () async {
      host.handle = (arguments) async =>
          output('${pid + 1} 0 UIKitApplication:test.fixture[another-device]');
      final target = UnixTarget(
        host,
        sessions.tools,
        TargetPlatform.ios,
        deviceId: '00000000-0000-0000-0000-000000000001',
        bundleId: 'test.fixture',
      )..expectedIdentity = UnixIdentity.read(pid);
      await expectLater(
        target.validateInstance(
          native: {'pid': pid, 'platform': 'ios', 'bundleId': 'test.fixture'},
        ),
        throwsA(code('target_changed')),
      );
      await expectLater(
        target.lifecycle('resume', Cancellation()),
        throwsA(code('target_changed')),
      );
      expect(host.commands.any((args) => args.contains('launch')), false);
    },
    skip: Platform.isWindows,
  );

  test(
    'iOS attach validates the VM PID before changing Driver settings',
    () async {
      const device = '00000000-0000-0000-0000-000000000001';
      host.handle = (args) async {
        if (args.contains('devices')) {
          return output(
            jsonEncode({
              'devices': {
                'runtime': [
                  {'udid': device, 'state': 'Booted', 'isAvailable': true},
                ],
              },
            }),
          );
        }
        return output('${pid + 1} 0 UIKitApplication:test.fixture[other]');
      };
      final bridge = AppBridge({
        'native': <String, Object?>{
          'pid': pid,
          'platform': 'ios',
          'bundleId': 'test.fixture',
        },
      });
      final targets = Sessions(host, sessions.tools, bridge);
      await expectLater(
        targets.open(
          {
            'sessionId': 'wrong-simulator',
            'platform': 'ios',
            'deviceId': device,
            'package': 'test.fixture',
            'vmUri': 'ws://unused',
          },
          Cancellation(),
          attach: true,
        ),
        throwsA(code('target_changed')),
      );
      expect(bridge.driverCommands, isEmpty);
      expect(bridge.commands.last, 'disconnect');
      expect(
        await Directory(p.join(directory.path, 'leases')).list().toList(),
        isEmpty,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'exited attached app releases its lease even with saved temporary modes',
    () async {
      connection.snapshot = {
        'native': <String, Object?>{'pid': 123},
      };
      final attached = androidSession(owned: false)..orientationChanged = true;
      sessions.active[current.id] = attached;
      await claimCurrent();
      await sessions.close(current.id);
      expect(await current.lease.exists(), false);
      expect(connection.restores, 0);
    },
  );

  for (final replacement in [
    (pid: 456, ticks: 'new'),
    (pid: 123, ticks: 'new'),
  ]) {
    test(
      'owned stop treats a replacement Android process as exited: $replacement',
      () async {
        connection.snapshot = {
          'native': <String, Object?>{'pid': 123},
        };
        deviceProcess(replacement.pid, replacement.ticks);
        final stale = androidSession(owned: true)..simulated = true;
        sessions.active[current.id] = stale;
        await claimCurrent();
        // The original instance is gone: release the lease instead of leaving
        // the session stuck, but never restore or stop the replacement.
        await sessions.close(current.id);
        expect(await current.lease.exists(), false);
        expect(sessions.active, isEmpty);
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
    'recycled Windows PID is treated as exited without touching the new process',
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
      await sessions.close(current.id);
      expect(native.same(WindowsApi().identity(pid)), true);
      expect(connection.restores, 0);
      expect(await current.lease.exists(), false);
      expect(sessions.active, isEmpty);
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

  test(
    'failed owned session publication stops the native app after its controller has exited',
    () async {
      final app = await Process.start('sh', ['-c', 'echo ready; read value']);
      final errors = app.stderr.drain<void>();
      try {
        await app.stdout.first;
        final original = UnixIdentity.read(app.pid)!;
        host.onStart = () async {
          final controller = await Process.start('sh', [
            '-c',
            '''printf '%s\\n' '[{"event":"app.debugPort","params":{"wsUri":"ws://unused"}}]' '[{"event":"app.started"}]' ''',
          ]);
          await controller.exitCode;
          return controller;
        };
        final bridge = AppBridge({
          'native': <String, Object?>{'pid': app.pid, 'platform': 'linux'},
        });
        final targets = Sessions(host, sessions.tools, bridge);
        final obstacle = Directory(
          p.join(directory.path, 'sessions', 'rollback', 'session.json'),
        );
        await obstacle.create(recursive: true);
        await expectLater(
          targets.open({
            'sessionId': 'rollback',
            'platform': 'linux',
          }, Cancellation()),
          throwsA(isA<FileSystemException>()),
        );
        expect(original.same(UnixIdentity.read(app.pid)), false);
        expect(targets.active, isEmpty);
        expect(
          await Directory(p.join(directory.path, 'leases')).list().toList(),
          isEmpty,
        );
      } finally {
        app.kill();
        await app.exitCode;
        await errors;
      }
    },
    skip: !Platform.isLinux,
  );
}
