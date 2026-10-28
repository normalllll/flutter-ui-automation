import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'android.dart';
import 'flutter_connection.dart';
import 'gateway.dart';
import 'host.dart';
import 'protocol.dart';
import 'windows.dart';
import 'target_platform.dart';
import 'unix_process.dart';
import 'unix_target.dart';

export 'target_platform.dart';

class FlutterProcess {
  FlutterProcess(this.process, this.log);
  final Process process;
  final IOSink log;
  final _pending = <int, Completer<Json>>{};
  final ready = Completer<void>();
  int _sequence = 0;
  String? appId, vmUri;
  bool exited = false;
  Future<void> listen() async {
    final errors = process.stderr.transform(utf8.decoder).forEach(log.write);
    try {
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        log.writeln(line);
        Object? value;
        try {
          value = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (value is! List<Object?>) continue;
        for (final event in value.map(object)) {
          if (event['id'] case final int id) {
            final completed = _pending.remove(id);
            if (completed != null) {
              event['error'] != null
                  ? completed.completeError(
                      AutomationError('flutter_process', '${event['error']}'),
                    )
                  : completed.complete(event);
            }
          }
          final params = event['params'] is Map<String, Object?>
              ? event.child('params')
              : <String, Object?>{};
          switch (event['event']) {
            case 'app.start':
              appId = params.text('appId');
            case 'app.debugPort':
              vmUri = params.text('wsUri');
            case 'app.started':
              if (!ready.isCompleted) ready.complete();
          }
        }
      }
    } finally {
      exited = true;
      if (!ready.isCompleted) {
        ready.completeError(
          const AutomationError(
            'launch_failed',
            'Flutter exited before app.started; inspect flutter-run.log',
          ),
        );
      }
      for (final completed in _pending.values) {
        completed.completeError(
          const AutomationError('flutter_process', 'Flutter process exited'),
        );
      }
      _pending.clear();
      await errors;
      await log.close();
    }
  }

  Future<Json> request(String method) async {
    if (exited) return {};
    final id = ++_sequence;
    final completed = Completer<Json>();
    _pending[id] = completed;
    process.stdin.writeln(
      jsonEncode([
        {
          'id': id,
          'method': method,
          'params': {'appId': appId},
        },
      ]),
    );
    await process.stdin.flush();
    try {
      return await completed.future.timeout(const Duration(seconds: 25));
    } on AutomationError {
      // app.stop/app.detach can close the machine channel before its reply.
      // Their caller verifies the owned native identity has actually exited.
      if (exited && (method == 'app.stop' || method == 'app.detach')) {
        return {'exited': true};
      }
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }
}

class Session {
  Session({
    required this.id,
    required this.platform,
    required this.project,
    required this.entrypoint,
    required this.directory,
    required this.lease,
    required this.owned,
    required this.connection,
    this.android,
    this.flutter,
    this.executableProcess,
    this.windowsIdentity,
    this.unixTarget,
    this.unixIdentity,
  });
  final String id, project, entrypoint;
  final TargetPlatform platform;
  final Directory directory, lease;
  final bool owned;
  final FlutterConnection connection;
  final AndroidDevice? android;
  final UnixTarget? unixTarget;
  UnixIdentity? unixIdentity;
  String? get deviceId => android?.serial ?? unixTarget?.deviceId;
  String? get package => android?.package ?? unixTarget?.bundleId;
  FlutterProcess? flutter;
  Process? executableProcess;
  WindowsIdentity? windowsIdentity;
  Json? androidIdentity;
  Json lastState = {};
  bool simulated = false,
      textEmulation = false,
      orientationChanged = false,
      closing = false;
  final opened = DateTime.now().toUtc();
  Future<Json> state() async {
    if (closing) {
      throw const AutomationError('session_closing', 'Session is closing');
    }
    final state = await connection.state();
    final native = state.child('native');
    if (platform == TargetPlatform.windows) {
      final current = WindowsApi().identity(native.integer('pid'));
      if (windowsIdentity != null && !windowsIdentity!.same(current)) {
        throw const AutomationError(
          'target_changed',
          'Windows process identity changed',
        );
      }
      WindowsApi().requireWindow(native.integer('hwnd'), native.integer('pid'));
    } else if (platform == TargetPlatform.android) {
      final current = await android!.identity();
      if (current?['pid'] != native['pid'] ||
          (androidIdentity?['startTicks'] != null &&
              current?['startTicks'] != androidIdentity?['startTicks'])) {
        throw const AutomationError(
          'target_changed',
          'Android process identity changed',
        );
      }
    } else {
      await unixTarget!.validateInstance(native: native);
    }
    lastState = state;
    return state;
  }

  Json toJson() => {
    'sessionId': id,
    'platform': platform.name,
    'project': project,
    'entrypoint': entrypoint,
    'owned': owned,
    'vmUri': connection.uri,
    'hooks': connection.hooks.name,
    'generation': connection.generation,
    'opened': opened.toIso8601String(),
    'lease': lease.path,
    'supervisor': Platform.isWindows
        ? WindowsApi().identity(pid)?.toJson()
        : UnixIdentity.read(pid)?.toJson(),
    'simulated': simulated,
    'textEmulation': textEmulation,
    'orientationChanged': orientationChanged,
    'deviceId': deviceId,
    'package': package,
    'windowsIdentity': windowsIdentity?.toJson(),
    'androidIdentity': androidIdentity,
    'unixIdentity': unixIdentity?.toJson(),
    'native': lastState['native'],
    'state': lastState,
  };
  Future<void> save() =>
      writeJson(File(p.join(directory.path, 'session.json')), toJson());
}

class Sessions {
  Sessions(this.host, this.tools, this.official);
  final Host host;
  final Toolchain tools;
  final OfficialBridge official;
  final active = <String, Session>{};
  Session get(String id) =>
      active[id] ??
      (throw AutomationError('no_session', 'No live session named $id'));

  Json _leaseOwner(String id) => {
    'pid': pid,
    'sessionId': id,
    'identity': Platform.isWindows
        ? WindowsApi().identity(pid)?.toJson()
        : UnixIdentity.read(pid)?.toJson(),
  };

  WindowsIdentity _identity(Json value) => WindowsIdentity(
    value.integer('pid'),
    value.integer('created'),
    value.text('image'),
  );

  Future<void> _requireLeaseOwner(Directory lease, Json expected) async {
    try {
      final actual = decodeObject(
        await File(p.join(lease.path, 'owner')).readAsString(),
      );
      final expectedIdentity = expected['identity'];
      if (actual['sessionId'] == expected['sessionId'] &&
          actual['pid'] == expected['pid'] &&
          (expectedIdentity is Json
              ? Platform.isWindows
                    ? _identity(
                        expectedIdentity,
                      ).same(_identity(actual.child('identity')))
                    : UnixIdentity.fromJson(
                        expectedIdentity,
                      ).same(UnixIdentity.fromJson(actual.child('identity')))
              : actual['identity'] == null)) {
        return;
      }
    } catch (_) {
      // Missing or incomplete ownership cannot authorize recovery or deletion.
    }
    throw const AutomationError(
      'lease_not_owned',
      'Session lease is missing or belongs to another supervisor or session',
    );
  }

  Future<void> _releaseLease(Directory lease, Json expected) async {
    if (!await lease.exists()) return;
    // Recovery can await app cleanup for some time. Recheck at release as well
    // so stale metadata never deletes a replacement owner's claim.
    await _requireLeaseOwner(lease, expected);
    final claim = File(p.join(lease.path, 'owner'));
    if ((await lease.list().toList()).any(
      (entry) => entry.path != claim.path,
    )) {
      throw const AutomationError(
        'lease_not_empty',
        'Unexpected lease contents; ownership retained',
      );
    }
    await claim.delete();
    // Delete only the empty directory; never enumerate and delete other claims.
    try {
      await lease.delete();
    } on FileSystemException {
      // Preserve retry authority if the directory could not be removed. An
      // exclusive create never overwrites a new owner's intervening claim.
      try {
        await claim.create(exclusive: true);
        await claim.writeAsString(jsonEncode(expected));
      } on FileSystemException {
        /* Preserve another owner's claim. */
      }
      rethrow;
    }
  }

  Future<bool> _requireCleanupTarget(Session session) async {
    if (session.platform == TargetPlatform.windows) {
      final expected = session.windowsIdentity;
      // No retained OS identity is not evidence of process exit. In that case
      // preserve the existing restore responsibility and rely on state().
      if (expected == null) return true;
      final current = WindowsApi().identity(expected.pid);
      // A different creation time proves the original instance exited and the
      // PID was reused. Treat that as exit; never restore or stop the new one.
      if (current == null || current.created != expected.created) return false;
      if (expected.same(current)) return true;
    } else if (session.platform == TargetPlatform.android) {
      final current = await session.android!.identity();
      final expected = session.androidIdentity;
      if (current == null) return false;
      if (current['pid'] == expected?['pid'] &&
          (expected?['startTicks'] == null ||
              current['startTicks'] == expected?['startTicks'])) {
        return true;
      }
      // The package now runs as another process: the original instance is
      // gone. Leave the replacement alone rather than blocking cleanup.
      if (expected != null) return false;
    } else {
      final expected = session.unixIdentity;
      final current = expected == null ? null : UnixIdentity.read(expected.pid);
      if (current == null || current.birth != expected!.birth) return false;
      if (expected.same(current)) {
        await session.unixTarget!.validateInstance();
        return true;
      }
    }
    throw const AutomationError(
      'target_changed',
      'Native process identity changed; refusing to restore or stop a different app',
    );
  }

  Uri _vmEndpoint(String value) {
    final uri = Uri.parse(value);
    if (!['http', 'https', 'ws', 'wss'].contains(uri.scheme)) return uri;
    final path = uri.path.endsWith('/ws')
        ? uri.path
        : '${uri.path}${uri.path.endsWith('/') ? '' : '/'}ws';
    return uri.replace(
      scheme: uri.isScheme('https') || uri.isScheme('wss') ? 'wss' : 'ws',
      path: path,
    );
  }

  Future<FlutterProcess> _flutter(
    List<String> args,
    String project,
    Directory directory,
    Map<String, String> env,
    Cancellation cancellation,
  ) async {
    final process = await host.start(
      tools.dart,
      tools.flutter(args),
      directory: project,
      extraEnvironment: env,
    );
    final resident = FlutterProcess(
      process,
      File(p.join(directory.path, 'flutter-run.log')).openWrite(),
    );
    unawaited(
      resident.listen().catchError((Object e, StackTrace s) {
        stderr.writeln('Flutter output: $e\n$s');
      }),
    );
    try {
      await cancellation.wait(
        resident.ready.future.timeout(const Duration(minutes: 5)),
      );
      return resident;
    } catch (_) {
      if (resident.appId != null && !resident.exited) {
        try {
          await resident.request(
            args.first == 'attach' ? 'app.detach' : 'app.stop',
          );
        } catch (e) {
          stderr.writeln('Launch cancellation cleanup: $e');
        }
      }
      await host.terminate(process);
      rethrow;
    }
  }

  Future<Session> open(
    Json args,
    Cancellation cancellation, {
    bool attach = false,
  }) async {
    final id = args.text('sessionId', fallback: 'default');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      throw const AutomationError(
        'invalid_session',
        'Session IDs use 1..64 letters, digits, _ or -',
      );
    }
    if (active.containsKey(id)) {
      final existing = get(id);
      if ((args['platform'] != null &&
              args['platform'] != existing.platform.name) ||
          (args['deviceId'] != null && args['deviceId'] != existing.deviceId) ||
          (args['package'] != null && args['package'] != existing.package) ||
          (args['vmUri'] != null &&
              _vmEndpoint(args.text('vmUri')) !=
                  _vmEndpoint(existing.connection.uri)) ||
          (args['hooks'] != null &&
              args['hooks'] != existing.connection.hooks.name) ||
          // start must not silently adopt an attached session, nor attach
          // reuse an owned one; ownership decides who stops the app.
          attach == existing.owned ||
          (args['executable'] != null && existing.executableProcess == null) ||
          (args['entrypoint'] != null &&
              !p.equals(
                p.normalize(p.join(existing.project, args.text('entrypoint'))),
                p.normalize(p.join(existing.project, existing.entrypoint)),
              )) ||
          (args['project'] != null &&
              !p.equals(
                p.normalize(Directory(args.text('project')).absolute.path),
                existing.project,
              ))) {
        throw const AutomationError(
          'session_conflict',
          'Session ID already refers to a different target',
        );
      }
      await existing.state();
      return existing;
    }
    if (attach && args['vmUri'] is String) {
      // The embedded server keeps one VM connection per URI; stopping either
      // session would disconnect the other's endpoint.
      final endpoint = _vmEndpoint(args.text('vmUri'));
      final holder = active.values
          .where((s) => _vmEndpoint(s.connection.uri) == endpoint)
          .firstOrNull;
      if (holder != null) {
        throw AutomationError(
          'session_conflict',
          'VM endpoint already belongs to session ${holder.id}',
        );
      }
    }
    final platform = TargetPlatform.values.byName(args.text('platform'));
    platform.requireHost();
    final project = p.normalize(
      Directory(args.text('project', fallback: tools.fixture)).absolute.path,
    );
    final fixture = p.equals(p.normalize(project), p.normalize(tools.fixture));
    final protocol = HookProtocol.values.byName(
      args.text('hooks', fallback: 'fixture'),
    );
    final entrypoint = args.text(
      'entrypoint',
      fallback: protocol == HookProtocol.booruflow
          ? platform == TargetPlatform.android
                ? 'tool/automation/android_mcp.dart'
                : 'tool/automation/main.dart'
          : platform.entrypoint,
    );
    final serial = platform.isMobile ? args.text('deviceId') : null;
    final package = platform.isMobile
        ? args.text(
            'package',
            fallback: platform == TargetPlatform.ios
                ? 'dev.flutter.flutterCaptureLab'
                : protocol == HookProtocol.booruflow
                ? 'io.github.normalllll.booruflow.automation'
                : 'dev.flutter.flutter_capture_lab',
          )
        : null;
    final android = platform != TargetPlatform.android
        ? null
        : AndroidDevice(host, tools, serial!, package!);
    final unixTarget = platform.isUnixTarget
        ? UnixTarget(host, tools, platform, deviceId: serial, bundleId: package)
        : null;
    final directory = Directory(p.join(tools.artifacts, 'sessions', id));
    await directory.create(recursive: true);
    final leaseKey = sha256
        .convert(utf8.encode('$platform|${serial ?? project}|${package ?? id}'))
        .toString()
        .substring(0, 20);
    final lease = Directory(p.join(tools.artifacts, 'leases', leaseKey));
    await lease.parent.create(recursive: true);
    try {
      await lease.create();
    } on FileSystemException {
      throw const AutomationError(
        'session_leased',
        'Target already has a session lease; inspect or recover its owner',
      );
    }
    // Directory.create succeeds for an existing directory, so create a file with
    // exclusive mode as the atomic claim. Keep it until the owned app is gone.
    final claim = File(p.join(lease.path, 'owner'));
    final owner = _leaseOwner(id);
    try {
      await claim.create(exclusive: true);
    } on FileSystemException {
      throw const AutomationError('session_leased', 'Target is already leased');
    }
    try {
      await claim.writeAsString(jsonEncode(owner));
    } catch (_) {
      // Creation succeeded, so this incomplete claim belongs to this call.
      // A failed write must not strand an unreadable lease indefinitely.
      try {
        await claim.delete();
        await lease.delete();
      } on FileSystemException catch (cleanup) {
        stderr.writeln('Incomplete lease cleanup: $cleanup');
      }
      rethrow;
    }
    FlutterProcess? resident;
    Process? executableProcess;
    FlutterConnection? connection;
    Session? session;
    UnixIdentity? launchedIdentity;
    try {
      await unixTarget?.ready(cancellation);
      if (!attach) await unixTarget?.requireStopped(cancellation);
      if (android != null) {
        await android.ready(cancellation);
        if (!attach && await android.identity() != null) {
          throw const AutomationError(
            'app_already_running',
            'App already runs; attach explicitly instead of replacing it',
          );
        }
      }
      String uri;
      if (attach) {
        uri = args.text('vmUri');
      } else if (platform == TargetPlatform.macos) {
        if (!fixture) {
          throw const AutomationError(
            'unsafe_launch',
            'Attach explicitly to non-fixture macOS applications',
          );
        }
        // Flutter's macOS run path deliberately invokes `open` to foreground
        // the app. Build, launch the test bundle directly, then attach instead.
        await host.run(
          tools.dart,
          tools.flutter([
            'build',
            'macos',
            '--debug',
            '--no-pub',
            '-t',
            entrypoint,
          ]),
          directory: project,
          timeout: const Duration(minutes: 15),
          cancellation: cancellation,
        );
        final executable = p.join(
          project,
          'build',
          'macos',
          'Build',
          'Products',
          'Debug',
          'flutter_capture_lab.app',
          'Contents',
          'MacOS',
          'flutter_capture_lab',
        );
        executableProcess = await host.start(
          executable,
          [],
          extraEnvironment: {
            'CAPTURE_LAB_AUTOMATION': '1',
            'FLUTTER_ENGINE_SWITCHES': '1',
            'FLUTTER_ENGINE_SWITCH_1': 'vm-service-port=0',
          },
        );
        final vm = Completer<String>();
        final log = File(p.join(directory.path, 'app.log')).openWrite();
        void observe(String line) {
          log.writeln(line);
          final match = RegExp(
            r'The Dart VM service is listening on (http://\S+)',
          ).firstMatch(line);
          if (match != null && !vm.isCompleted) vm.complete(match[1]!);
        }

        final out = executableProcess.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(observe);
        final errors = executableProcess.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(observe);
        unawaited(
          executableProcess.exitCode.then((code) async {
            await Future.wait([out, errors]);
            await log.close();
            if (!vm.isCompleted) {
              vm.completeError(
                AutomationError('launch_failed', 'macOS app exited $code'),
              );
            }
          }),
        );
        uri = await cancellation.wait(
          vm.future.timeout(const Duration(seconds: 50)),
        );
        resident = await _flutter(
          [
            'attach',
            '--machine',
            '--debug-uri',
            uri,
            '-d',
            'macos',
            '-t',
            entrypoint,
          ],
          project,
          directory,
          {},
          cancellation,
        );
        uri = resident.vmUri!;
      } else if (args['executable'] case final String executable) {
        if (platform != TargetPlatform.windows ||
            protocol != HookProtocol.booruflow) {
          throw const AutomationError(
            'unsafe_launch',
            'Executable launch currently requires the verified BooruFlow test runner',
          );
        }
        final file = File(executable).absolute;
        final kernel = File(
          p.join(file.parent.path, 'data', 'flutter_assets', 'kernel_blob.bin'),
        );
        if (!await kernel.exists() ||
            !utf8
                .decode(await kernel.readAsBytes(), allowMalformed: true)
                .contains(
                  'Set an explicit absolute BOORUFLOW_AUTOMATION_PROFILE',
                )) {
          throw const AutomationError(
            'unsafe_launch',
            'Executable is not an isolated Debug automation bundle',
          );
        }
        final profile = Directory(
          p.join(
            directory.path,
            'profile-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
        await profile.create();
        final env = {
          'BOORUFLOW_AUTOMATION_PROFILE': profile.path,
          'FLUTTER_ENGINE_SWITCHES': '4',
          'FLUTTER_ENGINE_SWITCH_1': 'enable-dart-profiling=true',
          'FLUTTER_ENGINE_SWITCH_2': 'enable-checked-mode=true',
          'FLUTTER_ENGINE_SWITCH_3': 'verify-entry-points=true',
          'FLUTTER_ENGINE_SWITCH_4': 'vm-service-port=0',
        };
        executableProcess = await host.start(
          file.path,
          [],
          directory: file.parent.path,
          extraEnvironment: env,
        );
        final log = File(p.join(directory.path, 'app.log')).openWrite();
        final vm = Completer<String>();
        void line(String value) {
          log.writeln(value);
          final match = RegExp(
            r'The Dart VM service is listening on (http://\S+)',
          ).firstMatch(value);
          if (match != null && !vm.isCompleted) vm.complete(match[1]!);
        }

        final out = executableProcess.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(line);
        final errors = executableProcess.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(line);
        unawaited(
          executableProcess.exitCode.then((code) async {
            // Drain buffered output before closing; a late write to a closed
            // sink would be an uncaught error that ends the whole service.
            await Future.wait([out, errors]);
            await log.close();
            if (!vm.isCompleted) {
              vm.completeError(
                AutomationError('launch_failed', 'App exited $code'),
              );
            }
          }),
        );
        uri = await cancellation.wait(
          vm.future.timeout(const Duration(seconds: 50)),
        );
        resident = await _flutter(
          [
            'attach',
            '--machine',
            '--debug-uri',
            uri,
            '-d',
            'windows',
            '-t',
            entrypoint,
          ],
          project,
          directory,
          {},
          cancellation,
        );
        uri = resident.vmUri!;
      } else {
        if (!fixture) {
          final entry = File(p.join(project, entrypoint));
          final gradle = File(
            p.join(project, 'android', 'app', 'build.gradle.kts'),
          );
          final isolatedAndroid =
              platform == TargetPlatform.android &&
              protocol == HookProtocol.booruflow &&
              package == 'io.github.normalllll.booruflow.automation' &&
              entrypoint == 'tool/automation/android_mcp.dart' &&
              await entry.exists() &&
              (await entry.readAsString()).contains(
                'BOORUFLOW_ANDROID_MCP_TEST_ONLY',
              ) &&
              await gradle.exists() &&
              RegExp(
                r'applicationId\s*=\s*"io\.github\.normalllll\.booruflow\.automation"',
              ).hasMatch(await gradle.readAsString());
          if (!isolatedAndroid) {
            throw const AutomationError(
              'unsafe_launch',
              'Use the verified fixture, an isolated BooruFlow test project, or attach to another project',
            );
          }
        }
        final env = <String, String>{
          if (platform.isUnixTarget) 'CAPTURE_LAB_AUTOMATION': '1',
        };
        if (platform == TargetPlatform.windows) {
          env['CAPTURE_LAB_PLACEMENT'] = args.text(
            'placement',
            fallback: 'auto',
          );
          env['CAPTURE_LAB_RENDERER'] = args.text(
            'renderer',
            fallback: 'default',
          );
        }
        final renderer = args.text('renderer', fallback: 'default');
        resident = await _flutter(
          [
            'run',
            '--machine',
            '--no-pub',
            '-d',
            serial ?? platform.device,
            '-t',
            entrypoint,
            if (renderer == 'software') ...[
              '--enable-software-rendering',
              '--no-enable-impeller',
            ],
            if (renderer == 'skia') '--no-enable-impeller',
          ],
          project,
          directory,
          env,
          cancellation,
        );
        uri = resident.vmUri!;
      }
      cancellation.check();
      connection = FlutterConnection(official, uri, protocol);
      await connection.connect(
        validateProcess: unixTarget == null
            ? null
            : (pid) async {
                final identity = UnixIdentity.read(pid);
                if (identity == null) {
                  throw const AutomationError(
                    'target_unavailable',
                    'Cannot inspect VM process',
                  );
                }
                unixTarget.expectedIdentity = identity;
                await unixTarget.validateInstance(cancellation: cancellation);
                if (!attach) launchedIdentity = identity;
              },
      );
      final state = await connection.state();
      final native = state.child('native');
      if (android != null) await android.validateInstance(native, cancellation);
      final unixIdentity = unixTarget?.expectedIdentity;
      if (platform.isUnixTarget && unixIdentity == null) {
        throw const AutomationError(
          'target_unavailable',
          'Cannot inspect native process identity',
        );
      }
      await unixTarget?.validateInstance(
        native: native,
        cancellation: cancellation,
      );
      if (!attach) launchedIdentity = unixIdentity;
      final windowsIdentity = platform == TargetPlatform.windows
          ? WindowsApi().identity(native.integer('pid'))
          : null;
      if (platform == TargetPlatform.windows && windowsIdentity == null) {
        throw const AutomationError(
          'target_unavailable',
          'Cannot inspect Windows process identity',
        );
      }
      session = Session(
        id: id,
        platform: platform,
        project: project,
        entrypoint: entrypoint,
        directory: directory,
        lease: lease,
        owned: !attach,
        connection: connection,
        android: android,
        flutter: resident,
        executableProcess: executableProcess,
        windowsIdentity: windowsIdentity,
        unixTarget: unixTarget,
        unixIdentity: unixIdentity,
      );
      session.androidIdentity = await android?.identity();
      session.lastState = state;
      // Connecting does not observe cancellation. Re-check before publishing
      // so a cancelled start never leaves a live session behind it.
      cancellation.check();
      await session.save();
      active[id] = session;
      return session;
    } catch (error, stack) {
      final cleanupErrors = <String>[];
      Future<void> step(String label, Future<void> Function() action) async {
        try {
          await action();
        } catch (e) {
          cleanupErrors.add('$label: $e');
        }
      }

      await step('Disconnect', () async => connection?.disconnect());
      if (resident != null && !resident.exited) {
        final controller = resident;
        await step(
          'Controller stop',
          () => controller.request(
            executableProcess == null ? 'app.stop' : 'app.detach',
          ),
        );
        await step('Controller exit', () => host.terminate(controller.process));
      }
      if (executableProcess != null) {
        final app = executableProcess;
        await step('App exit', () => host.terminate(app));
      }
      final ownedIdentity = launchedIdentity;
      if (ownedIdentity != null &&
          ownedIdentity.same(UnixIdentity.read(ownedIdentity.pid))) {
        // Controller exit does not imply app exit. A failure while saving or
        // publishing the session must roll back the verified native instance.
        await step('Native rollback', () async {
          await unixTarget!.validateInstance();
          if (platform == TargetPlatform.ios) {
            await unixTarget.simctl(['terminate', serial!, package!]);
            await until(
              () async =>
                  !ownedIdentity.same(UnixIdentity.read(ownedIdentity.pid)),
              (gone) => gone,
            );
          } else {
            await ownedIdentity.terminate();
          }
        });
      }
      if (!attach && android != null && resident != null) {
        // Start refused a running app before launching, so an instance after
        // this call's own launch is the one it owns.
        await step('Android rollback', () async {
          if (await android.identity() != null) {
            await android.command([
              'shell',
              'am',
              'force-stop',
              android.package,
            ]);
          }
        });
      }
      // The lease is released even when a rollback step failed; the errors
      // are reported with the original failure instead of stranding it.
      await step('Lease release', () => _releaseLease(lease, owner));
      if (cleanupErrors.isNotEmpty) {
        await File(p.join(directory.path, 'start-cleanup.json')).writeAsString(
          jsonEncode({'error': '$error', 'cleanup': cleanupErrors}),
        );
        if (error is AutomationError) {
          Error.throwWithStackTrace(
            AutomationError(error.code, error.message, {
              ...error.detail,
              'cleanupErrors': cleanupErrors,
            }),
            stack,
          );
        }
      }
      rethrow;
    }
  }

  Future<Json> close(String id) async {
    final session = get(id);
    final owner = _leaseOwner(id);
    if (await session.lease.exists()) {
      await _requireLeaseOwner(session.lease, owner);
    }
    final errors = <String>[];
    var observed = false;
    Json state = session.lastState;
    try {
      state = await session.state();
      observed = true;
    } catch (e) {
      errors.add('State unavailable during cleanup: $e');
    }
    // Failed state observation can mean a destroyed HWND, an exited process,
    // or a replacement instance. Only the first two permit owned cleanup.
    final targetAlive = await _requireCleanupTarget(session);
    if (!targetAlive) {
      // An exited attached app has no remaining temporary modes to restore.
      session.simulated = session.orientationChanged = session.textEmulation =
          false;
    }
    for (final restore in <Future<void> Function()>[
      if (session.simulated)
        () async {
          await session.connection.hook('pretendForeground', {
            'enabled': false,
          });
          session.simulated = false;
        },
      if (session.orientationChanged)
        () async {
          await session.connection.orientation('restore');
          session.orientationChanged = false;
        },
      if (session.textEmulation)
        () async {
          await session.connection.driver({
            'command': 'set_text_entry_emulation',
            'enabled': 'false',
          });
          session.textEmulation = false;
        },
    ]) {
      try {
        if (!observed) {
          throw const AutomationError(
            'target_unavailable',
            'Cannot restore modes through an unverified VM endpoint',
          );
        }
        await restore();
      } catch (e) {
        errors.add('Restore: $e');
      }
    }
    if (!session.owned &&
        (session.simulated ||
            session.orientationChanged ||
            session.textEmulation)) {
      await session.save();
      throw AutomationError(
        'cleanup_incomplete',
        'Attached app modes could not be restored; session and lease retained for retry',
        {'cleanupErrors': errors},
      );
    }
    // Release the service's debugger connection while the engine can still
    // acknowledge it. Window destruction and process teardown are distinct.
    try {
      await session.connection.disconnect();
    } catch (e) {
      errors.add('Disconnect: $e');
    }
    final ownedAlive = session.owned && await _requireCleanupTarget(session);
    if (session.owned && !ownedAlive) {
      // The owned instance already exited, possibly with its PID or package now
      // used by a replacement. The controller's own stop path would act on the
      // replacement (Android force-stops the package), so end it without
      // letting it run app cleanup.
      final controller = session.flutter;
      if (controller != null && !controller.exited) {
        controller.process.kill(ProcessSignal.sigkill);
        try {
          await controller.process.exitCode.timeout(
            const Duration(seconds: 10),
          );
        } on TimeoutException {
          errors.add('Controller did not exit after SIGKILL');
        }
      }
    }
    if (ownedAlive) {
      try {
        await session.flutter?.request(
          session.executableProcess != null ? 'app.detach' : 'app.stop',
        );
      } catch (e) {
        errors.add('Controller stop: $e');
      }
      if (session.executableProcess == null && session.flutter != null) {
        try {
          await session.flutter!.process.exitCode.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          /* The verified native fallback below owns cleanup. */
        }
      }
      if (session.platform == TargetPlatform.windows) {
        final expected = session.windowsIdentity!;
        if (expected.same(WindowsApi().identity(expected.pid))) {
          try {
            WindowsApi().closeWindow(
              state.child('native').integer('hwnd'),
              expected.pid,
            );
          } on AutomationError catch (e) {
            if (e.code != 'target_changed') rethrow;
          }
        }
      } else if (session.platform == TargetPlatform.android) {
        final current = await session.android!.identity();
        if (current?['pid'] == session.androidIdentity?['pid'] &&
            current?['startTicks'] == session.androidIdentity?['startTicks']) {
          await session.android!.validateInstance(
            state.child('native'),
            Cancellation(),
          );
          await session.android!.command([
            'shell',
            'am',
            'force-stop',
            session.android!.package,
          ]);
        }
      } else {
        final expected = session.unixIdentity!;
        if (expected.same(UnixIdentity.read(expected.pid))) {
          // A kernel identity check is mandatory before the owned fallback.
          if (session.platform == TargetPlatform.ios) {
            await session.unixTarget!.simctl([
              'terminate',
              session.deviceId!,
              session.package!,
            ]);
          } else {
            await expected.terminate();
          }
        }
      }
      Future<bool> gone() async {
        if (session.platform == TargetPlatform.windows) {
          return !session.windowsIdentity!.same(
            WindowsApi().identity(session.windowsIdentity!.pid),
          );
        }
        if (session.platform == TargetPlatform.android) {
          final current = await session.android!.identity();
          return current?['pid'] != session.androidIdentity?['pid'] ||
              current?['startTicks'] != session.androidIdentity?['startTicks'];
        }
        return !session.unixIdentity!.same(
          UnixIdentity.read(session.unixIdentity!.pid),
        );
      }

      try {
        await until(gone, (gone) => gone, description: 'owned app exit');
      } on AutomationError catch (e) {
        // An owned Windows app that ignores WM_CLOSE would otherwise make every
        // stop time out. Force only the verified instance this session started.
        if (e.code != 'timeout' ||
            session.platform != TargetPlatform.windows ||
            !WindowsApi().terminate(session.windowsIdentity!)) {
          rethrow;
        }
        errors.add('Owned app ignored close; terminated verified instance');
        await until(gone, (gone) => gone, description: 'owned app exit');
      }
      if (session.flutter != null) {
        try {
          await session.flutter!.process.exitCode.timeout(
            const Duration(seconds: 10),
          );
        } on TimeoutException {
          await host.terminate(session.flutter!.process);
        }
      }
    }
    try {
      await session.connection.disconnect();
    } catch (e) {
      errors.add('Disconnect: $e');
    }
    await _releaseLease(session.lease, owner);
    session.closing = true;
    active.remove(id);
    await writeJson(File(p.join(session.directory.path, 'closed.json')), {
      'sessionId': id,
      'owned': session.owned,
      'appStopped': session.owned,
      'cleanupErrors': errors,
    });
    return {
      'sessionId': id,
      'appStopped': session.owned,
      'detached': !session.owned,
      'cleanupErrors': errors,
    };
  }

  Future<void> closeAll() async {
    for (final id in active.keys.toList()) {
      try {
        await close(id);
      } catch (e) {
        stderr.writeln('Session $id cleanup: $e');
      }
    }
  }

  Future<Json> recover(String id, {required bool stopOwned}) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      throw const AutomationError('invalid_session', 'Invalid session ID');
    }
    if (active.containsKey(id)) {
      throw const AutomationError(
        'session_live',
        'Stop the live session through its current service',
      );
    }
    final file = File(p.join(tools.artifacts, 'sessions', id, 'session.json'));
    if (!await file.exists()) {
      throw const AutomationError('no_session', 'No retained session metadata');
    }
    final data = decodeObject(await file.readAsString());
    final supervisorData = data.child('supervisor');
    final supervisorPid = supervisorData.integer('pid');
    final supervisorAlive = Platform.isWindows
        ? _identity(supervisorData).same(WindowsApi().identity(supervisorPid))
        : UnixIdentity.fromJson(
            supervisorData,
          ).same(UnixIdentity.read(supervisorPid));
    if (supervisorAlive) {
      throw const AutomationError(
        'supervisor_live',
        'The original service is still running',
      );
    }
    final lease = Directory(p.normalize(data.text('lease')));
    if (!p.isWithin(
      p.normalize(p.join(tools.artifacts, 'leases')),
      lease.path,
    )) {
      throw const AutomationError(
        'invalid_lease',
        'Lease lies outside the configured artifact root',
      );
    }
    final owner = {
      'sessionId': id,
      'pid': supervisorPid,
      'identity': supervisorData,
    };
    // Retained session metadata outlives its lease. Establish authority before
    // connecting, restoring modes, or stopping an app described by that metadata.
    await _requireLeaseOwner(lease, owner);
    final platform = TargetPlatform.values.byName(data.text('platform'));
    final own = data.flag('owned');
    var alive = false;
    AndroidDevice? device;
    WindowsIdentity? target;
    UnixIdentity? unixIdentity;
    UnixTarget? unixTarget;
    if (platform == TargetPlatform.windows) {
      target = _identity(data.child('windowsIdentity'));
      alive = target.same(WindowsApi().identity(target.pid));
    } else if (platform == TargetPlatform.android) {
      device = AndroidDevice(
        host,
        tools,
        data.text('deviceId'),
        data.text('package'),
      );
      final current = await device.identity();
      alive =
          current?['pid'] == data.child('androidIdentity')['pid'] &&
          current?['startTicks'] == data.child('androidIdentity')['startTicks'];
      if (alive) {
        await device.validateInstance(data.child('native'), Cancellation());
      }
    } else {
      platform.requireHost();
      unixIdentity = UnixIdentity.fromJson(data.child('unixIdentity'));
      alive = unixIdentity.same(UnixIdentity.read(unixIdentity.pid));
      unixTarget = UnixTarget(
        host,
        tools,
        platform,
        deviceId: data['deviceId'] as String?,
        bundleId: data['package'] as String?,
      );
      unixTarget.expectedIdentity = unixIdentity;
      if (alive) {
        await unixTarget.validateInstance(native: data.child('native'));
      }
    }
    if (alive && own && !stopOwned) {
      return {
        'sessionId': id,
        'recoverable': true,
        'ownedAppAlive': true,
        'requiresStopOwned': true,
      };
    }
    final errors = <String>[];
    if (alive) {
      final connection = FlutterConnection(
        official,
        data.text('vmUri'),
        HookProtocol.values.byName(data.text('hooks')),
      );
      try {
        await connection.connect(
          validateProcess: unixTarget == null
              ? null
              : (pid) async {
                  if (pid != unixIdentity!.pid) {
                    throw const AutomationError(
                      'target_changed',
                      'Retained VM endpoint changed',
                    );
                  }
                  await unixTarget!.validateInstance();
                },
        );
        final native = (await connection.state()).child('native');
        if (unixTarget != null) {
          await unixTarget.validateInstance(native: native);
        } else if (device != null) {
          await device.validateInstance(native, Cancellation());
          if (native['pid'] != data.child('androidIdentity')['pid']) {
            throw const AutomationError(
              'target_changed',
              'Retained VM endpoint changed',
            );
          }
        } else if (native['pid'] != target!.pid ||
            !target.same(WindowsApi().identity(target.pid))) {
          throw const AutomationError(
            'target_changed',
            'Retained VM endpoint changed',
          );
        }
        if (data.flag('simulated')) {
          await connection.hook('pretendForeground', {'enabled': false});
        }
        if (data.flag('orientationChanged')) {
          await connection.orientation('restore');
        }
        if (data.flag('textEmulation')) {
          await connection.driver({
            'command': 'set_text_entry_emulation',
            'enabled': 'false',
          });
        }
      } catch (e) {
        errors.add('Restore: $e');
      } finally {
        try {
          await connection.disconnect();
        } catch (e) {
          errors.add('Disconnect: $e');
        }
      }
      if (!own && errors.isNotEmpty) {
        throw AutomationError(
          'cleanup_incomplete',
          'Attached app recovery failed; lease retained for retry',
          {'cleanupErrors': errors},
        );
      }
      if (own) {
        if (target != null) {
          if (!target.same(WindowsApi().identity(target.pid))) {
            throw const AutomationError(
              'target_changed',
              'Target identity changed before cleanup',
            );
          }
          WindowsApi().closeWindow(
            data.child('native').integer('hwnd'),
            target.pid,
          );
          await until(
            () async => !target!.same(WindowsApi().identity(target.pid)),
            (gone) => gone,
            description: 'recovered owned app exit',
          );
        } else if (device != null) {
          await device.validateInstance(data.child('native'), Cancellation());
          await device.command(['shell', 'am', 'force-stop', device.package]);
        } else {
          unixIdentity!.requireCurrent();
          if (platform == TargetPlatform.ios) {
            await unixTarget!.validateInstance();
            await unixTarget.simctl([
              'terminate',
              unixTarget.deviceId!,
              unixTarget.bundleId!,
            ]);
          } else {
            await unixIdentity.terminate();
          }
          await until(
            () async =>
                !unixIdentity!.same(UnixIdentity.read(unixIdentity.pid)),
            (gone) => gone,
          );
        }
      }
    }
    await _releaseLease(lease, owner);
    final result = {
      'sessionId': id,
      'recovered': true,
      'appStopped': alive && own,
      'attachedAppPreserved': alive && !own,
      'cleanupErrors': errors,
    };
    await writeJson(File(p.join(file.parent.path, 'recovered.json')), result);
    return result;
  }
}
