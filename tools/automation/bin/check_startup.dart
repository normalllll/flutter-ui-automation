import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_ui_automation/src/client.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

/// Exercises the compiled distribution without an app, device, or inherited
/// Dart SDK hints. Source-mode tests cannot detect AOT SDK discovery failures.
Future<void> main(List<String> args) async {
  final root = p.normalize(Directory('../..').absolute.path);
  final tools = Toolchain(root);
  final executable = p.absolute(
    args.isEmpty
        ? p.join('build', Platform.isWindows ? 'automation.exe' : 'automation')
        : args.single,
  );
  final artifacts = await Directory(p.join(root, 'artifacts'))
      .create(recursive: true);
  final output = await artifacts.createTemp('compiled-startup-');
  final environment = {
    for (final entry in Platform.environment.entries)
      if (!['DART_ROOT', 'DART_SDK'].contains(entry.key.toUpperCase()))
        entry.key: entry.value,
  };
  final arguments = [
    '--root',
    root,
    '--flutter-root',
    tools.flutterRoot,
    '--artifacts',
    output.path,
  ];
  final server = await Process.start(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
  );
  final errors = server.stderr.transform(utf8.decoder).join();
  final client = WireClient(
    stdioChannel(input: server.stdout, output: server.stdin),
    root: Directory(tools.fixture).uri.toString(),
  );
  var passed = false;
  try {
    await client.initialize().timeout(const Duration(seconds: 15));
    final names =
        (await client
                .request('tools/list')
                .timeout(const Duration(seconds: 15)))
            .child('result')
            .items('tools')
            .map(object)
            .map((tool) => tool.text('name'))
            .toSet();
    if (!names.containsAll(['vm_service', 'automation_service'])) {
      throw StateError('Compiled MCP did not expose official and local tools');
    }
    final status = (await client.tool('automation_service', {
      'action': 'status',
    })).child('structuredContent');
    if (status['pid'] != server.pid) {
      throw StateError('MCP status did not identify the compiled service');
    }
    // The helper only accepts integer fps. Validate this at the public wire
    // boundary, before any session or capture process is needed.
    final invalid = await client.tool('automation_record', {
      'nativeFps': 1.5,
      'job': false,
    });
    if (invalid['isError'] != true ||
        invalid.child('structuredContent')['code'] != 'invalid_argument') {
      throw StateError('Fractional native fps was accepted: $invalid');
    }
    final valid = await client.tool('automation_record', {
      'nativeFps': 12,
      'job': false,
    });
    if (valid.child('structuredContent')['code'] != 'no_session') {
      throw StateError('Integer native fps did not reach the runtime: $valid');
    }
    final cli = await Process.start(
      executable,
      [...arguments, 'call', 'automation_service', '{"action":"status"}'],
      environment: environment,
      includeParentEnvironment: false,
    );
    final cliOutput = cli.stdout.transform(utf8.decoder).join();
    final cliErrors = cli.stderr.transform(utf8.decoder).join();
    try {
      final code = await cli.exitCode.timeout(const Duration(seconds: 15));
      if (code != 0 ||
          decodeObject(await cliOutput).child('structuredContent')['pid'] !=
              server.pid) {
        throw StateError('Compiled CLI did not reuse MCP: ${await cliErrors}');
      }
    } finally {
      cli.kill();
      await cli.exitCode;
      await cliOutput;
      await cliErrors;
    }
    await client.close().timeout(const Duration(seconds: 15));
    final code = await server.exitCode.timeout(const Duration(seconds: 15));
    if (code != 0 ||
        await File(p.join(output.path, 'service.json')).exists() ||
        await File(p.join(output.path, 'service-owner.json')).exists()) {
      throw StateError('Compiled MCP failed to cleanly close: $code');
    }
    passed = true;
  } catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    server.kill();
    await server.exitCode;
    await client.close();
    final log = await errors;
    await File(p.join(output.path, 'server.log')).writeAsString(log);
    await writeJson(File(p.join(output.path, 'checks.json')), {
      'passed': passed,
      'executable': executable,
      'dartSdkEnvironmentHints': false,
      'checks': [
        'compiled MCP initialization and merged tools',
        'native fps validation before session access',
        'compiled CLI reuse of the same server',
        'EOF shutdown and descriptor cleanup',
      ],
    });
    if (!passed && log.isNotEmpty) stderr.writeln(log);
    stdout.writeln(
      'Compiled startup ${passed ? 'passed' : 'failed'}: ${output.path}',
    );
  }
}
