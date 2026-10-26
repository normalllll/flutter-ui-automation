import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_ui_automation/src/broker.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

Future<void> main() async {
  final root = p.normalize(Directory('../..').absolute.path);
  final directory = Directory(
    p.join(
      root,
      'artifacts',
      'dart-broker-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await directory.create(recursive: true);
  final executable = p.join(Directory.current.path, 'build', 'automation.exe');
  final args = ['--root', root, '--artifacts', directory.path];
  final server = await Process.start(executable, [...args, 'serve']);
  final errors = server.stderr.pipe(
    File(p.join(directory.path, 'server.log')).openWrite(),
  );
  final output = server.stdout.drain<void>();
  final tools = Toolchain(root, artifacts: directory.path);
  final checks = <Json>[], warm = <int>[], cold = <int>[];
  try {
    await until(
      () async => File(p.join(directory.path, 'service.json')).exists(),
      (exists) => exists,
    );
    final info = decodeObject(
      await File(p.join(directory.path, 'service.json')).readAsString(),
    );
    final http = HttpClient();
    try {
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${info['port']}/call'),
      );
      final response = await request.close();
      if (response.statusCode != 403) {
        throw StateError('Unauthenticated call accepted');
      }
      await response.drain<void>();
    } finally {
      http.close(force: true);
    }
    checks.add({
      'name': 'unauthenticated loopback call rejected',
      'passed': true,
    });
    for (var i = 0; i < 10; i++) {
      final watch = Stopwatch()..start();
      final result = await brokerCall(tools, 'automation_service', {
        'action': 'status',
      });
      warm.add(watch.elapsedMicroseconds);
      if (result.child('structuredContent')['pid'] != server.pid) {
        throw StateError('Service changed');
      }
    }
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      final result = await Process.run(executable, [
        ...args,
        'call',
        'automation_service',
        jsonEncode({'action': 'status'}),
      ]);
      cold.add(watch.elapsedMicroseconds);
      if (result.exitCode != 0 ||
          decodeObject(
                result.stdout as String,
              ).child('structuredContent')['pid'] !=
              server.pid) {
        throw StateError(
          'Compiled client did not reuse service: ${result.stderr}',
        );
      }
    }
    checks.add({
      'name': 'warm and compiled CLI calls reuse one service',
      'passed': true,
      'warmMicroseconds': warm,
      'compiledClientMicroseconds': cold,
    });
    final duplicate = await Process.run(executable, [...args, 'serve']);
    if (duplicate.exitCode == 0 ||
        !('${duplicate.stderr}').contains('service_running')) {
      throw StateError('Duplicate service was not rejected');
    }
    checks.add({
      'name': 'duplicate service cannot replace descriptor',
      'passed': true,
    });
    await brokerCall(tools, 'automation_service', {'action': 'stop'});
    final code = await server.exitCode.timeout(const Duration(seconds: 30));
    if (code != 0 ||
        await File(p.join(directory.path, 'service.json')).exists() ||
        await File(p.join(directory.path, 'service-owner.json')).exists()) {
      throw StateError('Unclean shutdown: $code');
    }
    checks.add({
      'name': 'graceful daemon shutdown removes live descriptors',
      'passed': true,
    });
    final crashed = await Process.start(executable, [...args, 'serve']);
    final crashErrors = crashed.stderr.drain<void>(),
        crashOutput = crashed.stdout.drain<void>();
    Process? recovered;
    Future<void>? recoveredErrors, recoveredOutput;
    try {
      await until(() async {
        try {
          return decodeObject(
                await File(
                  p.join(directory.path, 'service.json'),
                ).readAsString(),
              )['pid'] ==
              crashed.pid;
        } catch (_) {
          return false;
        }
      }, (ready) => ready);
      crashed.kill();
      await crashed.exitCode;
      await crashErrors;
      await crashOutput;
      await File(
        p.join(directory.path, 'service-owner.json'),
      ).writeAsString('{');
      recovered = await Process.start(executable, [...args, 'serve']);
      recoveredErrors = recovered.stderr.drain<void>();
      recoveredOutput = recovered.stdout.drain<void>();
      await until(() async {
        try {
          return decodeObject(
                await File(
                  p.join(directory.path, 'service.json'),
                ).readAsString(),
              )['pid'] ==
              recovered!.pid;
        } catch (_) {
          return false;
        }
      }, (ready) => ready);
      await brokerCall(tools, 'automation_service', {'action': 'stop'});
      if (await recovered.exitCode != 0) {
        throw StateError('Recovered service failed');
      }
      checks.add({
        'name': 'OS lease recovers after hard crash and partial descriptor',
        'passed': true,
      });
    } finally {
      crashed.kill();
      recovered?.kill();
      await crashed.exitCode;
      await recovered?.exitCode;
      await crashErrors;
      await crashOutput;
      await recoveredErrors;
      await recoveredOutput;
    }
  } catch (e) {
    checks.add({'name': 'broker', 'passed': false, 'error': '$e'});
    exitCode = 1;
    server.kill();
    await server.exitCode;
  } finally {
    await errors;
    await output;
    await File(
      p.join(directory.path, 'checks.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
    stdout.writeln('Evidence: ${directory.path}');
  }
}
