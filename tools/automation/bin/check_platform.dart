import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_ui_automation/src/client.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/target_platform.dart';

/// Opt-in runtime acceptance. Run on the native target host, in an authorized
/// dedicated display/simulator. This is intentionally separate from unit tests.
Future<void> main(List<String> arguments) async {
  final platform = TargetPlatform.values.byName(arguments.first);
  final appOnly = arguments.contains('--app-only');
  final device = arguments
      .where((arg) => arg != '--app-only')
      .skip(1)
      .firstOrNull;
  final root = p.normalize(Directory('../..').absolute.path);
  final tools = Toolchain(root);
  final artifacts = await Directory(
    p.join(root, 'artifacts'),
  ).create(recursive: true);
  final output = await artifacts.createTemp('runtime-${platform.name}-');
  final server = await Process.start(
    p.absolute('build', Platform.isWindows ? 'automation.exe' : 'automation'),
    [
      '--root',
      root,
      '--flutter-root',
      tools.flutterRoot,
      '--artifacts',
      output.path,
    ],
  );
  final errors = server.stderr.pipe(
    File(p.join(output.path, 'server.log')).openWrite(),
  );
  final client = WireClient(
    stdioChannel(input: server.stdout, output: server.stdin),
    root: Directory(tools.fixture).uri.toString(),
  );
  final checks = <Json>[];
  var opened = false;
  Future<Json> call(String name, Json args) async {
    var result = await client.tool(name, args);
    if (result['isError'] == true) {
      throw StateError('$name: ${result['structuredContent']}');
    }
    var data = result.child('structuredContent');
    if (data['jobId'] != null) {
      while (data['state'] == 'running' ||
          data['state'] == 'queued' ||
          data['state'] == 'cancelling') {
        result = await client.tool('automation_jobs', {
          'action': 'wait',
          'jobId': data['jobId'],
          'waitSeconds': 30,
        });
        data = result.child('structuredContent');
      }
      if (data['state'] != 'completed') throw StateError('$name job: $data');
      final value = data.child('result');
      if (value['isError'] == true) throw StateError('$name result: $value');
      return value['structuredContent'] is Json
          ? value.child('structuredContent')
          : value;
    }
    return data;
  }

  try {
    await client.initialize();
    final session = await call('automation_session', {
      'action': 'start',
      'sessionId': 'acceptance',
      'platform': platform.name,
      'deviceId': ?device,
      if (platform == TargetPlatform.linux) 'renderer': 'software',
    });
    opened = true;
    checks.add({'name': 'start', 'passed': true, 'session': session});
    final tree = await call('automation_drive', {
      'sessionId': 'acceptance',
      'action': 'tree',
    });
    checks.add({'name': 'tree', 'passed': tree.isNotEmpty});
    // Verify a source change reaches the running engine, beyond acknowledging
    // the reload RPC. Always restore this dedicated fixture source afterward.
    final source = File(p.join(tools.fixture, 'lib', 'src', 'lab_app.dart'));
    final original = await source.readAsString();
    const changedTitle = 'Automation source reload verified';
    if (!original.contains('Automation overview')) {
      throw StateError('Fixture title missing');
    }
    try {
      await source.writeAsString(
        original.replaceAll('Automation overview', changedTitle),
      );
      await call('automation_session', {
        'action': 'hotReload',
        'sessionId': 'acceptance',
      });
      final changed = await call('automation_drive', {
        'sessionId': 'acceptance',
        'action': 'tree',
      });
      checks.add({
        'name': 'source-hot-reload',
        'passed': jsonEncode(changed).contains(changedTitle),
      });
    } finally {
      await source.writeAsString(original);
      await call('automation_session', {
        'action': 'hotReload',
        'sessionId': 'acceptance',
      });
    }
    final verified = await call('automation_verify', {
      'sessionId': 'acceptance',
      'record': !appOnly,
      if (appOnly) 'channels': ['app'],
    });
    checks.add({
      'name': 'fixture',
      'passed': verified['passed'] == true,
      'report': verified,
    });
    final capture = await call('automation_capture', {
      'sessionId': 'acceptance',
      'label': 'final',
      if (appOnly) 'channels': ['app'],
    });
    checks.add({
      'name': 'capture',
      'passed': capture
          .items('items')
          .map(object)
          .every((item) => item['passed'] == true),
      'report': capture,
    });
    final recording = (await client.tool('automation_record', {
      'sessionId': 'acceptance',
      'seconds': 10,
      'fps': 2,
      'channels': ['app'],
    })).child('structuredContent');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await client.tool('automation_jobs', {
      'action': 'cancel',
      'jobId': recording['jobId'],
    });
    var cancelled = <String, Object?>{};
    do {
      cancelled = (await client.tool('automation_jobs', {
        'action': 'wait',
        'jobId': recording['jobId'],
        'waitSeconds': 30,
      })).child('structuredContent');
    } while (cancelled['state'] == 'cancelling' ||
        cancelled['state'] == 'running');
    checks.add({
      'name': 'recording-cancellation',
      'passed': cancelled['state'] == 'cancelled',
      'report': cancelled,
    });
    final stopped = await call('automation_session', {
      'action': 'stop',
      'sessionId': 'acceptance',
    });
    opened = false;
    checks.add({
      'name': 'stop',
      'passed': stopped['appStopped'] == true,
      'report': stopped,
    });
    if (!appOnly) {
      final cold = await call('automation_verify_cold', {
        'platform': platform.name,
        'cycles': 1,
        'deviceId': ?device,
      });
      checks.add({
        'name': 'cold-start-and-presentation-fences',
        'passed': cold['passed'] == true,
        'report': cold,
      });
    }
  } catch (error, stack) {
    checks.add({
      'name': 'runtime',
      'passed': false,
      'error': '$error',
      'stack': '$stack',
    });
    stderr.writeln(error);
  } finally {
    if (opened) {
      try {
        await call('automation_session', {
          'action': 'stop',
          'sessionId': 'acceptance',
        });
      } catch (error) {
        stderr.writeln('Session cleanup: $error');
      }
    }
    await client.close();
    try {
      await server.exitCode.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // Keep the evidence below; a hung server must not discard it.
      stderr.writeln('Server did not exit; killing it');
      server.kill(ProcessSignal.sigkill);
      await server.exitCode;
    }
    await errors;
    final passed =
        checks.isNotEmpty && checks.every((item) => item['passed'] == true);
    await writeJson(File(p.join(output.path, 'checks.json')), {
      'passed': passed,
      'platform': platform.name,
      'appOnly': appOnly,
      'checks': checks,
    });
    stdout.writeln(jsonEncode({'passed': passed, 'evidence': output.path}));
    if (!passed) exitCode = 1;
  }
}
