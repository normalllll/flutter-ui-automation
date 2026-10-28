import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_ui_automation/src/client.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/broker.dart';
import 'package:flutter_ui_automation/src/host.dart';

/// Runs the shipped executable through its actual MCP endpoint, without an
/// editor-specific registration. GUI arguments are deliberate, never inferred.
Future<void> main(List<String> args) async {
  final root = Directory('../..').absolute.path;
  final output = Directory(
    p.join(
      root,
      'artifacts',
      'dart-mcp-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await output.create(recursive: true);
  final server = await Process.start(
    p.join(Directory.current.path, 'build', 'automation.exe'),
    ['--root', root, '--artifacts', output.path],
    environment: {...Platform.environment, 'AUTOMATION_DEBUG': '1'},
  );
  final stderrDone = server.stderr.pipe(
    File(p.join(output.path, 'server.log')).openWrite(),
  );
  final client = WireClient(
    stdioChannel(input: server.stdout, output: server.stdin),
    root: Directory(p.join(root, 'examples', 'capture_lab')).uri.toString(),
  );
  final transcript = <Json>[];
  final checks = <Json>[];
  Future<Json> tool(String name, Json arguments) async {
    final watch = Stopwatch()..start();
    var result = await client.tool(name, arguments);
    transcript.add({
      'name': name,
      'arguments': arguments,
      'elapsedMs': watch.elapsedMilliseconds,
      'result': result,
    });
    if (result['isError'] == true) throw StateError('$name: $result');
    var value = result.child('structuredContent');
    while (value['jobId'] != null &&
        ['queued', 'running'].contains(value['state'])) {
      result = await client.tool('automation_jobs', {
        'action': 'wait',
        'jobId': value['jobId'],
        'waitSeconds': 20,
      });
      value = result.child('structuredContent');
      stdout.writeln('$name: ${value['state']} (${watch.elapsed.inSeconds}s)');
    }
    if (value['jobId'] != null) {
      if (value['state'] != 'completed') throw StateError('$value');
      result = value.child('result');
      value = result.child('structuredContent');
    }
    checks.add({
      'name': name,
      'passed': true,
      'elapsedMs': watch.elapsedMilliseconds,
      'result': value,
    });
    if ((name == 'automation_verify' || name == 'automation_verify_cold') &&
        value['passed'] != true) {
      throw StateError('Fixture assertions failed: ${value['directory']}');
    }
    return value;
  }

  try {
    await client.initialize();
    final list = await client.request('tools/list');
    final names = list
        .child('result')
        .items('tools')
        .map(object)
        .map((t) => t.text('name'))
        .toList();
    if (!names.contains('hot_reload') ||
        !names.contains('automation_capture')) {
      throw StateError('Incomplete merged tool list: $names');
    }
    checks.add({
      'name': 'merged official and local tools',
      'passed': true,
      'tools': names,
    });
    await tool('automation_environment', {});
    if (args.isNotEmpty) {
      final platform = args.first;
      if (!['windows', 'android'].contains(platform)) {
        throw ArgumentError('Pass windows or android SERIAL');
      }
      if (!args.contains('--quick') &&
          !args.contains('--expanded') &&
          !args.contains('--cold')) {
        await tool('automation_build', {'platform': platform});
      }
      if (args.contains('--cold')) {
        await tool('automation_verify_cold', {
          'platform': platform,
          'cycles': 1,
          if (platform == 'android') 'deviceId': args[1],
        });
      } else {
        await tool('automation_session', {
          'action': 'start',
          'platform': platform,
          'sessionId': 'check-$platform',
          if (platform == 'android') 'deviceId': args[1],
        });
        if (args.contains('--stop-only')) {
          // Recheck cleanup without repeating already accepted captures.
        } else if (args.contains('--quick')) {
          final id = 'check-$platform';
          if (platform == 'windows') {
            await tool('automation_drive', {
              'sessionId': id,
              'action': 'foreground',
              'enabled': true,
            });
          }
          final before = await tool('automation_session', {
            'action': 'state',
            'sessionId': id,
          });
          final source = File(
            p.join(
              root,
              'examples',
              'capture_lab',
              'lib',
              'src',
              'lab_app.dart',
            ),
          );
          final original = await source.readAsString();
          const anchor = "      'page': ['overview'";
          if (!original.contains(anchor)) {
            throw StateError('Snapshot anchor missing');
          }
          final modified = original.replaceFirst(
            anchor,
            "      'automationSourceProbe': 'live-edit-proof',\n$anchor",
          );
          await source.writeAsString(modified);
          try {
            await tool('automation_session', {
              'action': 'hotReload',
              'sessionId': id,
            });
            final state = await tool('automation_session', {
              'action': 'state',
              'sessionId': id,
            });
            if (state['automationSourceProbe'] != 'live-edit-proof' ||
                state.child('native')['pid'] != before.child('native')['pid']) {
              throw StateError('Source hot reload not reflected in same app');
            }
          } finally {
            if (await source.readAsString() != modified) {
              throw StateError(
                'Source edited externally; refusing to overwrite it',
              );
            }
            await source.writeAsString(original);
            await tool('automation_session', {
              'action': 'hotReload',
              'sessionId': id,
            });
          }
          await tool('automation_session', {
            'action': 'hotRestart',
            'sessionId': id,
          });
          final after = await tool('automation_session', {
            'action': 'state',
            'sessionId': id,
          });
          if (after.containsKey('automationSourceProbe') ||
              after.child('native')['pid'] != before.child('native')['pid']) {
            throw StateError('Restart identity or source restoration failed');
          }
          if (platform == 'windows') {
            await tool('automation_drive', {
              'sessionId': id,
              'action': 'foreground',
              'enabled': true,
            });
          }
          await tool('automation_capture', {
            'sessionId': id,
            'label': 'after-source-restore',
          });
          final started = (await client.tool('automation_record', {
            'sessionId': id,
            'channels': ['app'],
            'seconds': 10,
            'fps': 2,
            'label': 'cancel-proof',
          })).child('structuredContent');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await tool('automation_drive', {
            'sessionId': id,
            'action': 'tap',
            'selector': {'kind': 'key', 'value': 'nav-gallery'},
          });
          await client.tool('automation_jobs', {
            'action': 'cancel',
            'jobId': started['jobId'],
          });
          var job = (await client.tool('automation_jobs', {
            'action': 'wait',
            'jobId': started['jobId'],
            'waitSeconds': 20,
          })).child('structuredContent');
          if (job['state'] != 'cancelled') {
            throw StateError('Cancel failed: $job');
          }
          checks.add({
            'name': 'drive while recording and targeted cancellation',
            'passed': true,
            'job': job,
          });
          final broker = await brokerCall(
            Toolchain(root, artifacts: output.path),
            'automation_service',
            {'action': 'status'},
          );
          if (broker.child('structuredContent')['pid'] != server.pid) {
            throw StateError('CLI broker did not reuse MCP process');
          }
          checks.add({
            'name': 'CLI broker reuses MCP process',
            'passed': true,
            'result': broker,
          });
        } else {
          await tool('automation_verify', {
            'sessionId': 'check-$platform',
            'record': true,
            if (args.contains('--expanded'))
              'checks': platform == 'windows'
                  ? [
                      'window',
                      'background',
                      'foreground',
                      'unicode',
                      'modal',
                      'animation',
                    ]
                  : [
                      'unicode',
                      'native-keyboard',
                      'modal',
                      'animation',
                      'orientation',
                    ],
          });
        }
        await tool('automation_session', {
          'action': 'stop',
          'sessionId': 'check-$platform',
        });
      }
    }
  } catch (e, s) {
    checks.add({
      'name': 'runtime',
      'passed': false,
      'error': '$e',
      'stack': '$s',
    });
    exitCode = 1;
  } finally {
    await File(
      p.join(output.path, 'transcript.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(transcript));
    await File(
      p.join(output.path, 'checks.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
    await client.close();
    try {
      await server.exitCode.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      stderr.writeln('Server did not exit; killing it');
      server.kill(ProcessSignal.sigkill);
      await server.exitCode;
    }
    await stderrDone;
    stdout.writeln('Evidence: ${output.path}');
  }
}
