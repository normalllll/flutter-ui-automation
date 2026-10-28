import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'flutter_connection.dart';
import 'foreground.dart';
import 'gateway.dart';
import 'host.dart';
import 'media.dart';
import 'pixels.dart';
import 'protocol.dart';
import 'sessions.dart';
import 'windows.dart';
import 'unix_target.dart';

part 'verification.dart';

Json string([List<String>? values]) => {'type': 'string', 'enum': ?values};
Json boolean() => {'type': 'boolean'};
Json numeric(num min, num max, {bool integer = false}) => {
  'type': integer ? 'integer' : 'number',
  'minimum': min,
  'maximum': max,
};
Json definition(
  String name,
  String description,
  Json properties,
  List<String> required,
) => {
  'name': name,
  'description': description,
  'inputSchema': {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  },
};

final toolDefinitions = <Json>[
  definition(
    'automation_service',
    'Inspect or gracefully stop this resident service. Stop cancels its work, restores test modes and stops only apps it owns.',
    {
      'action': string(['status', 'stop']),
    },
    ['action'],
  ),
  definition(
    'automation_verify_cold',
    'Explicit offline fixture cold-start verification. Cycles 1..5, different monitor placement, exact presentation fences and bounded never-presented token rejection. Stops only the instances created by this check. No network app.',
    {
      'platform': string(TargetPlatform.values.map((p) => p.name).toList()),
      'deviceId': string(),
      'cycles': numeric(1, 5, integer: true),
      'job': boolean(),
    },
    ['platform'],
  ),
  definition(
    'automation_session',
    'Persistent Flutter sessions. Start only a verified nonactivating fixture or isolated BooruFlow test runner. Android needs explicit USB device. Attach never owns the app. Hot reload/restart keeps the native app process.',
    {
      'action': string([
        'start',
        'attach',
        'list',
        'state',
        'stop',
        'recover',
        'hotReload',
        'hotRestart',
      ]),
      'sessionId': string(),
      'platform': string(TargetPlatform.values.map((p) => p.name).toList()),
      'project': string(),
      'entrypoint': string(),
      'deviceId': string(),
      'package': string(),
      'hooks': string(['fixture', 'booruflow']),
      'vmUri': string(),
      'executable': string(),
      'placement': string(['auto', 'primary', 'secondary']),
      'renderer': string(['default', 'skia', 'software']),
      'job': boolean(),
      'stopOwned': boolean(),
    },
    ['action'],
  ),
  definition(
    'automation_drive',
    'Use observed widget selectors and Flutter Driver, never host input. Tree, taps, Unicode test input, native Android Back/lifecycle/orientation, bounded waits, and explicit reversible test modes. Read tree before choosing selectors.',
    {
      'sessionId': string(),
      'action': string([
        'tree',
        'tap',
        'wait',
        'absent',
        'tappable',
        'text',
        'enterText',
        'scroll',
        'reveal',
        'center',
        'settle',
        'unfocus',
        'foreground',
        'textEmulation',
        'orientation',
        'back',
        'background',
        'resume',
        'key',
        'tapAt',
        'request',
        'driver',
      ]),
      'selector': {'type': 'object'},
      'text': string(),
      'dx': {'type': 'number'},
      'dy': {'type': 'number'},
      'durationMs': numeric(1, 10000, integer: true),
      'alignment': numeric(0, 1),
      'enabled': boolean(),
      'value': string(),
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'key': string(),
      'arguments': {'type': 'object'},
      'settle': boolean(),
    },
    ['action'],
  ),
  definition(
    'automation_capture',
    'Capture original app PNG and/or independent Windows, Linux X11, macOS window or Android/iOS Simulator display PNG. Each channel has its own result and retained failed attempt. Retry only a failed channel. Foreground observations never invalidate pixels.',
    {
      'sessionId': string(),
      'channels': {
        'type': 'array',
        'items': string(['app', 'native']),
        'minItems': 1,
        'uniqueItems': true,
      },
      'label': string(),
      'backend': string(['wgc', 'printwindow']),
      'settle': boolean(),
      'presentation': boolean(),
      'compare': boolean(),
      'includeImages': boolean(),
    },
    [],
  ),
  definition(
    'automation_record',
    'Bounded app PNG sampling and/or native video, in parallel. Keeps FFV1/BGRA lossless masters and source PNGs/hashes; Android screenrecord remains lossy. Reports actual timing without disguising encoder lag. Returns a job by default.',
    {
      'sessionId': string(),
      'channels': {
        'type': 'array',
        'items': string(['app', 'native']),
        'minItems': 1,
        'uniqueItems': true,
      },
      'seconds': numeric(1, 30, integer: true),
      'fps': numeric(1, 15),
      'nativeFps': numeric(1, 60, integer: true),
      'presentation': boolean(),
      'label': string(),
      'backend': string(['wgc', 'printwindow']),
      'job': boolean(),
    },
    [],
  ),
  definition(
    'automation_build',
    'Build the offline fixture or a specified Flutter test project. Retains build log. No app launch, global focus, or desktop input. Returns a job by default.',
    {
      'platform': string(TargetPlatform.values.map((p) => p.name).toList()),
      'project': string(),
      'entrypoint': string(),
      'job': boolean(),
    },
    ['platform'],
  ),
  definition(
    'automation_verify',
    'Offline fixture walkthrough: navigation, Unicode, modal barrier, scroll, animation, mobile keyboard/lifecycle/orientation and hot reload/restart. Select capture channels explicitly for partial capability checks. Never runs this sequence on a network app. Returns a job by default.',
    {
      'sessionId': string(),
      'record': boolean(),
      'channels': {
        'type': 'array',
        'items': string(['app', 'native']),
        'minItems': 1,
        'uniqueItems': true,
      },
      'checks': {
        'type': 'array',
        'items': string([
          'window',
          'background',
          'foreground',
          'overview',
          'gallery',
          'unicode',
          'native-keyboard',
          'modal',
          'animation',
          'orientation',
          'lifecycle',
          'hot-reload',
          'hot-restart',
        ]),
        'minItems': 1,
        'uniqueItems': true,
      },
      'label': string(),
      'job': boolean(),
    },
    [],
  ),
  definition(
    'automation_jobs',
    'Inspect, wait up to 50 seconds, or cancel owned jobs. Cancellation does not rerun any successful item.',
    {
      'action': string(['list', 'status', 'wait', 'cancel']),
      'jobId': string(),
      'waitSeconds': numeric(0, 50, integer: true),
    },
    ['action'],
  ),
  definition(
    'automation_environment',
    'Inspect service identity, backend paths, connected Android devices and available prerequisites. No app launch.',
    {},
    [],
  ),
  definition(
    'automation_inspect_video',
    'Decode a retained video and measure motion only inside an optional content region, excluding unrelated clocks and presentation markers.',
    {
      'path': string(),
      'rotationDegrees': {
        'type': 'integer',
        'enum': [0, 90, 180, 270],
      },
      'region': {
        'type': 'object',
        'properties': {
          for (final k in ['x', 'y', 'width', 'height'])
            k: numeric(k == 'x' || k == 'y' ? 0 : 1, 64000, integer: true),
        },
        'required': ['x', 'y', 'width', 'height'],
        'additionalProperties': false,
      },
    },
    ['path'],
  ),
];

class Job {
  Job(this.id, this.name, this.arguments);
  final String id, name;
  final Json arguments;
  final cancellation = Cancellation();
  final completed = Completer<void>();
  final started = DateTime.now().toUtc();
  String state = 'queued';
  Json? result;
  Json toJson() => {
    'jobId': id,
    'tool': name,
    'state': state,
    'started': started.toIso8601String(),
    'result': ?result,
  };
}

class AutomationRuntime {
  AutomationRuntime(this.host, this.tools, this.official)
    : sessions = Sessions(host, tools, official),
      media = Media(host, tools);
  final Host host;
  final Toolchain tools;
  final OfficialBridge official;
  final Sessions sessions;
  final Media media;
  final jobs = <String, Job>{};
  final _queues = <String, Future<void>>{};
  final _recording = <String>{};
  final _stopping = <String>{};
  // A record job runs on its own queue; count it from enqueue, not only once
  // record() has started, so stop/hotRestart cannot slip in between.
  bool _recordActive(String id) =>
      _recording.contains(id) || _queues.containsKey('record/$id');
  final _running = <Cancellation>{};
  bool closing = false;
  void Function()? onStop;
  int _sequence = 0;
  Future<Json> call(String name, Json args, Cancellation cancellation) async {
    if (closing) {
      throw const AutomationError(
        'service_closing',
        'Service is shutting down',
      );
    }
    if (name == 'automation_service') {
      if (args['action'] == 'stop') Timer.run(() => onStop?.call());
      return toolResult({
        'pid': pid,
        'stopping': args['action'] == 'stop',
        'sessions': sessions.active.keys.toList(),
        'jobs': jobs.length,
      });
    }
    if (name == 'automation_jobs') return toolResult(await _job(args));
    if (name == 'automation_environment') {
      return toolResult(await _environment(cancellation));
    }
    if (name == 'automation_inspect_video') {
      return toolResult(
        await media.inspect(
          args.text('path'),
          rotation: CaptureRotation.fromDegrees(
            args.integer('rotationDegrees', fallback: 0),
          ),
          region: args['region'] == null ? null : args.child('region'),
          cancellation: cancellation,
        ),
      );
    }
    final asynchronous = args.flag(
      'job',
      fallback:
          const [
            'automation_record',
            'automation_build',
            'automation_verify',
            'automation_verify_cold',
          ].contains(name) ||
          name == 'automation_session' && args['action'] == 'start',
    );
    if (asynchronous) {
      final id = 'job-${++_sequence}-${DateTime.now().microsecondsSinceEpoch}';
      final job = Job(id, name, args);
      jobs[id] = job;
      unawaited(() async {
        try {
          job.result = await _queued(
            name,
            args,
            job.cancellation,
            onStart: () => job.state = 'running',
          );
          job.state = job.cancellation.cancelled ? 'cancelled' : 'completed';
        } catch (e) {
          job.result = toolFailure(e);
          job.state = job.cancellation.cancelled ? 'cancelled' : 'failed';
        } finally {
          try {
            await writeJson(
              File(p.join(tools.artifacts, 'jobs', '$id.json')),
              job.toJson(),
            );
          } catch (e) {
            stderr.writeln('Job evidence: $e');
          } finally {
            job.completed.complete();
          }
        }
      }());
      return toolResult(job.toJson());
    }
    return _queued(name, args, cancellation);
  }

  Future<Json> _queued(
    String name,
    Json args,
    Cancellation cancellation, {
    void Function()? onStart,
  }) async {
    final id = args.text('sessionId', fallback: 'default');
    final key = name == 'automation_build'
        ? 'build'
        : name == 'automation_record'
        ? 'record/$id'
        : id;
    final previous = _queues[key] ?? Future<void>.value();
    _running.add(cancellation);
    final release = Completer<void>();
    _queues[key] = release.future;
    await previous;
    try {
      cancellation.check();
      onStart?.call();
      return await _execute(name, args, cancellation);
    } finally {
      _running.remove(cancellation);
      release.complete();
      if (identical(_queues[key], release.future)) _queues.remove(key);
    }
  }

  Future<Json> _execute(
    String name,
    Json args,
    Cancellation cancellation,
  ) async {
    if (name == 'automation_verify_cold') {
      return toolResult(await verifyCold(args, cancellation));
    }
    if (name == 'automation_build') {
      final platform = TargetPlatform.values.byName(args.text('platform'));
      platform.requireHost();
      final project = args.text('project', fallback: tools.fixture);
      final target = args.text('entrypoint', fallback: platform.entrypoint);
      final result = await host.run(
        tools.dart,
        tools.flutter([
          'build',
          platform.buildTarget,
          if (platform == TargetPlatform.ios) '--simulator',
          '--debug',
          '-t',
          target,
        ]),
        directory: project,
        timeout: const Duration(minutes: 15),
        cancellation: cancellation,
        check: false,
      );
      final log = File(
        p.join(
          tools.artifacts,
          'build-${platform.name}-${DateTime.now().microsecondsSinceEpoch}.log',
        ),
      );
      await log.parent.create(recursive: true);
      await log.writeAsString('${result.text}\n${result.error}');
      if (result.code != 0) {
        throw AutomationError('build_failed', 'Flutter build failed', {
          'log': log.path,
        });
      }
      return toolResult({
        'built': true,
        'platform': platform.name,
        'project': project,
        'log': log.path,
      });
    }
    if (name == 'automation_session') {
      final id = args.text('sessionId', fallback: 'default');
      switch (args.text('action')) {
        case 'start':
        case 'attach':
          return toolResult(
            (await sessions.open(
              args,
              cancellation,
              attach: args['action'] == 'attach',
            )).toJson(),
          );
        case 'list':
          return toolResult({
            'sessions': sessions.active.values.map((s) => s.toJson()).toList(),
          });
        case 'stop':
          if (_recordActive(id)) {
            throw const AutomationError(
              'session_busy',
              'Cancel or finish the recording before stopping its app',
            );
          }
          _stopping.add(id);
          try {
            return toolResult(await sessions.close(id));
          } finally {
            _stopping.remove(id);
          }
        case 'recover':
          return toolResult(
            await sessions.recover(id, stopOwned: args.flag('stopOwned')),
          );
        case 'state':
          return toolResult(await sessions.get(id).state());
        case 'hotReload':
        case 'hotRestart':
          if (_recordActive(id) && args['action'] == 'hotRestart') {
            throw const AutomationError(
              'session_busy',
              'Cancel or finish the recording before hot restart',
            );
          }
          final session = sessions.get(id);
          await session.state();
          await session.connection.update(
            restart: args['action'] == 'hotRestart',
          );
          await session.state();
          await session.save();
          return toolResult(session.toJson());
      }
    }
    final sessionId = args.text('sessionId', fallback: 'default');
    if (name == 'automation_record' && _stopping.contains(sessionId)) {
      throw const AutomationError(
        'session_closing',
        'Session is stopping; recording was not started',
      );
    }
    final session = sessions.get(sessionId);
    await session.state();
    return switch (name) {
      'automation_drive' => toolResult(
        await drive(session, args, cancellation),
      ),
      'automation_capture' => await capture(session, args, cancellation),
      'automation_record' => toolResult(
        await record(session, args, cancellation),
      ),
      'automation_verify' => toolResult(
        await verify(session, args, cancellation),
      ),
      _ => throw AutomationError(
        'unknown_tool',
        'Unknown automation tool $name',
      ),
    };
  }

  /// Hooks that change a reversible app mode must go through their tracked
  /// actions; raw requests would leave stop/recover unaware of the change.
  static void _requireUntrackedHook(String hook) {
    const tracked = {
      'pretendForeground': 'foreground',
      'orientation': 'orientation',
    };
    final action = tracked[hook];
    if (action != null) {
      throw AutomationError(
        'tracked_mode',
        'Use action $action so stop and recover can restore it',
      );
    }
  }

  Future<Json> drive(
    Session session,
    Json args,
    Cancellation cancellation,
  ) async {
    cancellation.check();
    final connection = session.connection;
    final action = args.text('action');
    final selector = args['selector'] == null
        ? null
        : finder(args.child('selector'));
    Future<Json> targeted(String command, [Json extra = const {}]) {
      if (selector == null) {
        throw const AutomationError(
          'missing_selector',
          'This action requires an observed widget selector',
        );
      }
      return connection.driver({'command': command, ...selector, ...extra});
    }

    Json result = {};
    switch (action) {
      case 'tree':
        return connection.driver({'command': 'get_render_tree'});
      case 'tap':
        result = await targeted('tap');
      case 'wait':
        return targeted('waitFor');
      case 'absent':
        return targeted('waitForAbsent');
      case 'tappable':
        return targeted('waitForTappable');
      case 'text':
        return targeted('get_text');
      case 'center':
        return targeted('get_offset', {'offsetType': 'center'});
      case 'scroll':
        result = await targeted('scroll', {
          'dx': '${args.number('dx', fallback: 0)}',
          'dy': '${args.number('dy', fallback: 0)}',
          'duration': '${args.integer('durationMs', fallback: 400) * 1000}',
          'frequency': '60',
        });
      case 'reveal':
        result = await targeted('scrollIntoView', {
          'alignment': '${args.number('alignment', fallback: .5)}',
        });
      case 'enterText':
        result = await connection.driver({
          'command': 'enter_text',
          'text': args.text('text'),
        });
      case 'textEmulation':
        final enabled = args.flag('enabled');
        // A dispatched enable may take effect even when its reply is lost.
        // Persist cleanup responsibility until disabling is acknowledged.
        if (enabled) {
          session.textEmulation = true;
          await session.save();
        }
        result = await connection.driver({
          'command': 'set_text_entry_emulation',
          'enabled': '$enabled',
        });
        session.textEmulation = enabled;
      case 'foreground':
        if (session.platform != TargetPlatform.windows) {
          throw const AutomationError(
            'unsupported_platform',
            'Simulated foreground applies only to Windows',
          );
        }
        final enabled = args.flag('enabled');
        if (enabled) {
          session.simulated = true;
          await session.save();
        }
        result = await connection.hook('pretendForeground', {
          'enabled': enabled,
        });
        session.simulated = enabled;
      case 'orientation':
        if (!session.platform.isMobile) {
          throw const AutomationError(
            'unsupported_platform',
            'Orientation applies only to mobile targets',
          );
        }
        final value = args.text('value');
        if (!['portrait', 'landscape', 'restore'].contains(value)) {
          throw const AutomationError(
            'invalid_orientation',
            'Use portrait, landscape or restore',
          );
        }
        if (value != 'restore') {
          session.orientationChanged = true;
          await session.save();
        }
        result = await connection.orientation(
          value,
          cancellation: cancellation,
        );
        session.orientationChanged = value != 'restore';
        if (value != 'restore') {
          await until(session.state, (s) {
            final v = s.child('view');
            return value == 'portrait'
                ? v.number('height') > v.number('width')
                : v.number('width') > v.number('height');
          }, cancellation: cancellation);
        }
      case 'back':
      case 'background':
      case 'resume':
        final device = session.android;
        if (device == null) {
          await session.unixTarget?.lifecycle(action, cancellation);
          if (session.unixTarget == null) {
            throw const AutomationError(
              'unsupported_platform',
              'Native lifecycle unavailable',
            );
          }
          return {
            'action': action,
            'complete': true,
            'state': await until<Json>(
              session.state,
              (state) =>
                  state.child('native')['isForeground'] == (action == 'resume'),
              cancellation: cancellation,
            ),
          };
        }
        if (action == 'back') await device.back(cancellation);
        if (action == 'background') await device.background(cancellation);
        if (action == 'resume') await device.resume(cancellation);
        return {
          'action': action,
          'complete': true,
          'state': await session.state(),
        };
      case 'settle':
        return connection.settle();
      case 'unfocus':
        result = await connection.hook('unfocus');
      case 'key':
        result = await connection.hook('key', {'key': args.text('key')});
      case 'tapAt':
        result = await connection.hook('tapAt', {
          'x': args.number('x'),
          'y': args.number('y'),
        });
      case 'request':
        _requireUntrackedHook(args.text('value'));
        result = await connection.hook(
          args.text('value'),
          args['arguments'] == null ? {} : args.child('arguments'),
        );
      case 'driver':
        final command = args.child('arguments');
        if (command['command'] == 'set_text_entry_emulation') {
          throw const AutomationError(
            'tracked_mode',
            'Use action textEmulation so stop and recover can restore it',
          );
        }
        if (command['command'] == 'request_data' &&
            command['message'] is String) {
          try {
            final message = decodeObject(command.text('message'));
            if (message['command'] case final String hook) {
              _requireUntrackedHook(hook);
            }
          } on FormatException {
            /* Not a fixture hook request; forward unchanged. */
          } on AutomationError catch (e) {
            if (e.code == 'tracked_mode') rethrow;
          }
        }
        result = await connection.driver(command);
      default:
        throw AutomationError('invalid_action', 'Unknown drive action $action');
    }
    if (args.flag('settle', fallback: true)) await connection.settle();
    final state = await session.state();
    await session.save();
    return {'result': result, 'state': state};
  }

  String _directory(Session session, Json args) {
    final label = args.text('label', fallback: 'capture');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(label)) {
      throw const AutomationError(
        'invalid_label',
        'Labels use letters, digits, _ or -',
      );
    }
    return p.join(
      session.directory.path,
      '$label-${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  Future<Json> _item(String channel, Future<Json> Function() action) async {
    try {
      final result = await action();
      final passed = result['timingPassed'] != false;
      return {
        'channel': channel,
        'passed': passed,
        'result': result,
        if (!passed)
          'error': const AutomationError(
            'timing_mismatch',
            'Capture exceeded the requested acquisition duration; original media retained',
          ).toJson(),
      };
    } catch (e) {
      return {
        'channel': channel,
        'passed': false,
        'error': e is AutomationError ? e.toJson() : {'message': '$e'},
      };
    }
  }

  Future<Json> _observe(Session session) async {
    try {
      return {'state': await session.state()};
    } catch (e) {
      return {
        'stateError': e is AutomationError ? e.toJson() : {'message': '$e'},
      };
    }
  }

  Future<Json> nativeScreenshot(
    Session session,
    String path,
    Json native, {
    Json? probe,
    String backend = 'wgc',
    required Cancellation cancellation,
  }) => switch (session.platform) {
    TargetPlatform.windows => WindowsCapture(host, tools).screenshot(
      path,
      native,
      probe: probe,
      backend: backend,
      cancellation: cancellation,
    ),
    TargetPlatform.android => session.android!.screenshot(
      path,
      probe: probe,
      cancellation: cancellation,
    ),
    _ => session.unixTarget!.screenshot(
      path,
      native,
      probe: probe,
      cancellation: cancellation,
    ),
  };

  Future<Json> capture(
    Session session,
    Json args,
    Cancellation cancellation,
  ) async {
    final directory = _directory(session, args);
    await Directory(directory).create(recursive: true);
    final channels = args['channels'] == null
        ? ['app', 'native']
        : args.items('channels');
    final results = <Json>[];
    // Keep successful evidence even if the next channel has lost its condition.
    if (channels.contains('app')) {
      results.add(
        await _item(
          'app',
          () => media.appPng(
            session,
            p.join(directory, 'app.png'),
            settle: args.flag('settle', fallback: true),
            cancellation: cancellation,
          ),
        ),
      );
    }
    if (channels.contains('native')) {
      results.add(
        await _item('native', () async {
          final probe = args.flag('presentation', fallback: true)
              ? await session.connection.hook('prepareCapture', {
                  'settle': args.flag('settle', fallback: true),
                })
              : null;
          try {
            final native = (await session.state()).child('native');
            return await nativeScreenshot(
              session,
              p.join(directory, 'native.png'),
              native,
              probe: probe,
              backend: args.text('backend', fallback: 'wgc'),
              cancellation: cancellation,
            );
          } finally {
            await session.connection.releaseCapture(probe);
          }
        }),
      );
    }
    final observation = await _observe(session);
    if (args.flag('compare', fallback: args.flag('settle', fallback: true)) &&
        results.length == 2 &&
        results.every((i) => i['passed'] == true) &&
        observation['state'] != null) {
      results.add(
        await _item('comparison', () async {
          final comparison = await compareCapture(
            results.first.child('result'),
            results[1].child('result'),
            android: session.platform.isMobile,
            state: observation.child('state'),
          );
          if (comparison['passed'] != true) {
            throw AutomationError(
              'pixel_mismatch',
              'Native presentation does not match Flutter content',
              comparison,
            );
          }
          return comparison;
        }),
      );
    }
    final report = {'directory': directory, 'items': results, ...observation};
    await writeJson(File(p.join(directory, 'capture.json')), report);
    final images = <Json>[];
    if (args.flag('includeImages')) {
      for (final item in results.where(
        (i) => i['passed'] == true && i['channel'] != 'comparison',
      )) {
        final file = File(item.child('result').text('path'));
        if (await file.length() < 8 * 1024 * 1024) {
          images.add({
            'type': 'image',
            'mimeType': 'image/png',
            'data': base64Encode(await file.readAsBytes()),
          });
        }
      }
    }
    return toolResult(report, content: images);
  }

  Future<Json> record(
    Session session,
    Json args,
    Cancellation cancellation,
  ) async {
    if (!_recording.add(session.id)) {
      throw const AutomationError(
        'session_busy',
        'Recording already runs for this session',
      );
    }
    try {
      final directory = _directory(session, args);
      await Directory(directory).create(recursive: true);
      final channels = args['channels'] == null
          ? ['app', 'native']
          : args.items('channels');
      final seconds = args.integer('seconds', fallback: 5);
      final probe =
          channels.contains('native') &&
              args.flag('presentation', fallback: true)
          ? await session.connection.hook('prepareCapture', {
              'settle': false,
              'holdMs': (seconds + 45) * 1000,
            })
          : null;
      final work = <Future<Json>>[
        if (channels.contains('app'))
          _item(
            'app',
            () => media.appRecording(
              session,
              p.join(directory, 'app.mp4'),
              seconds,
              args.number('fps', fallback: session.platform.isMobile ? 2 : 5),
              cancellation,
            ),
          ),
        if (channels.contains('native'))
          _item(
            'native',
            () => session.platform == TargetPlatform.windows
                ? media.windowsRecording(
                    session,
                    p.join(directory, 'native.mp4'),
                    seconds,
                    args.integer('nativeFps', fallback: 12),
                    args.text('backend', fallback: 'wgc'),
                    probe,
                    cancellation,
                  )
                : session.platform == TargetPlatform.android
                ? media.androidRecording(
                    session,
                    p.join(directory, 'native.mp4'),
                    seconds,
                    probe,
                    cancellation,
                  )
                : media.unixRecording(
                    session,
                    p.join(directory, 'native.mp4'),
                    seconds,
                    args.number(
                      'nativeFps',
                      fallback: session.platform == TargetPlatform.ios ? 1 : 2,
                    ),
                    probe,
                    cancellation,
                  ),
          ),
      ];
      final List<Json> items;
      try {
        items = await Future.wait(work);
      } finally {
        await session.connection.releaseCapture(probe);
      }
      final report = {
        'directory': directory,
        'items': items,
        ...await _observe(session),
      };
      await writeJson(File(p.join(directory, 'record.json')), report);
      return report;
    } finally {
      _recording.remove(session.id);
    }
  }

  Future<Json> _job(Json args) async {
    if (args['action'] == 'list') {
      return {'jobs': jobs.values.map((j) => j.toJson()).toList()};
    }
    final job = jobs[args.text('jobId')];
    if (job == null) throw const AutomationError('no_job', 'Unknown job');
    if (args['action'] == 'cancel' && !job.completed.isCompleted) {
      job.state = 'cancelling';
      job.cancellation.cancel();
    }
    if (args['action'] == 'wait') {
      await job.completed.future.timeout(
        Duration(seconds: args.integer('waitSeconds', fallback: 30)),
        onTimeout: () {},
      );
    }
    return job.toJson();
  }

  Future<Json> _environment(Cancellation cancellation) async {
    final found = <String, Object?>{};
    for (final name in ['adb', 'ffmpeg', 'ffprobe']) {
      try {
        found[name] = tools.program(name, variable: name.toUpperCase());
      } catch (e) {
        found[name] = '$e';
      }
    }
    if (Platform.isWindows) {
      try {
        found['windowCapture'] = tools.helper;
      } catch (e) {
        found['windowCapture'] = '$e';
      }
    }
    final desktop = <String, Object?>{};
    if (Platform.isLinux || Platform.isMacOS) {
      final target = UnixTarget(
        host,
        tools,
        Platform.isLinux ? TargetPlatform.linux : TargetPlatform.macos,
      );
      try {
        found['nativeCapture'] = target.captureHelper;
        if (Platform.isMacOS) {
          desktop.addAll(
            decodeObject(
              (await host.run(target.captureHelper, [
                '--preflight',
              ], cancellation: cancellation)).text,
            ),
          );
        }
      } catch (error) {
        desktop['captureError'] = '$error';
      }
      if (Platform.isLinux) {
        desktop['display'] = host.environment['DISPLAY'];
        desktop['waylandDisplay'] = host.environment['WAYLAND_DISPLAY'];
        desktop['nativeCaptureBackend'] = 'X11 only';
      }
    }
    Json simulators = {};
    if (Platform.isMacOS) {
      try {
        simulators = decodeObject(
          (await host.run('xcrun', [
            'simctl',
            'list',
            'devices',
            '-j',
          ], cancellation: cancellation)).text,
        );
      } catch (error) {
        simulators = {'error': '$error'};
      }
    }
    Json devices = {};
    try {
      devices = {
        'output': (await host.run(tools.program('adb', variable: 'ADB'), [
          'devices',
          '-l',
        ], cancellation: cancellation)).text,
      };
    } catch (e) {
      devices = {'error': '$e'};
    }
    return {
      'pid': pid,
      'runtime': 'Dart',
      'hostPlatform': Platform.operatingSystem,
      'flutterRoot': tools.flutterRoot,
      'artifacts': tools.artifacts,
      'sessions': sessions.active.length,
      'jobs': jobs.length,
      'prerequisites': found,
      'android': devices,
      'desktop': desktop,
      'iosSimulators': simulators,
    };
  }

  Future<void> close() async {
    closing = true;
    for (final cancellation in _running) {
      cancellation.cancel();
    }
    for (final job in jobs.values) {
      if (!job.completed.isCompleted) job.cancellation.cancel();
    }
    await Future.wait(jobs.values.map((j) => j.completed.future));
    await Future.wait(_queues.values.toList());
    await sessions.closeAll();
    await host.close();
  }
}
