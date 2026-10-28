import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter_ui_automation/src/broker.dart';
import 'package:flutter_ui_automation/src/client.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/runtime.dart';

Future<void> main(List<String> arguments) async {
  try {
    await run(arguments);
  } catch (e, s) {
    stderr.writeln('$e');
    if (Platform.environment['AUTOMATION_DEBUG'] == '1') stderr.writeln(s);
    exitCode = 1;
  }
}

Future<void> run(List<String> arguments) async {
  final args = arguments.toList();
  String? option(String name) {
    final index = args.indexOf(name);
    if (index < 0) return null;
    if (index + 1 >= args.length) throw FormatException('Missing $name value');
    final value = args[index + 1];
    args.removeRange(index, index + 2);
    return value;
  }

  final root =
      option('--root') ?? Platform.environment['AUTOMATION_ROOT'] ?? _root();
  final tools = Toolchain(
    root,
    flutterRoot: option('--flutter-root'),
    artifacts: option('--artifacts'),
  );
  final command = args.isEmpty ? 'mcp' : args.removeAt(0);
  if (command == 'call') {
    if (args.isEmpty) {
      throw const FormatException(
        'call TOOL JSON or call TOOL @arguments.json',
      );
    }
    final name = args.removeAt(0);
    final raw = args.isEmpty ? '{}' : args.single;
    final input = decodeObject(
      raw.startsWith('@') ? await File(raw.substring(1)).readAsString() : raw,
    );
    final result = await brokerCall(tools, name, input);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
    if (result['isError'] == true) exitCode = 1;
    return;
  }
  if (!['mcp', 'serve'].contains(command)) {
    throw const FormatException('Use mcp, serve, or call TOOL JSON');
  }
  final host = Host();
  late final AutomationRuntime runtime;
  late final Broker broker;
  // A second MCP client for the same artifacts root forwards automation tools
  // to the resident owner instead of exiting before the MCP handshake.
  var forwarded = false;
  final local = command == 'serve' ? StreamChannelController<String>() : null;
  final gateway = AutomationGateway(
    local?.local ?? stdioChannel(input: stdin, output: stdout),
    flutterRoot: tools.flutterRoot,
    tools: toolDefinitions,
    handle: (name, args, c) => forwarded
        ? brokerCall(tools, name, args, cancellation: c)
        : runtime.call(name, args, c),
    closeRuntime: () async {
      if (forwarded) return;
      await runtime.close();
      await broker.close();
    },
  );
  runtime = AutomationRuntime(host, tools, gateway.official);
  runtime.onStop = gateway.stop;
  broker = Broker(runtime);
  try {
    await broker.start();
  } on AutomationError catch (e) {
    if (e.code != 'service_running' || local != null) rethrow;
    forwarded = true;
    stderr.writeln(
      'Forwarding automation tools to the resident service in ${tools.artifacts}',
    );
  }
  final running = gateway.run();
  WireClient? resident;
  if (local != null) {
    resident = WireClient(
      local.foreign,
      root: Directory(tools.fixture).uri.toString(),
    );
    await resident.initialize();
  }
  if (resident != null) {
    stderr.writeln(
      'Flutter automation ready: PID $pid, ${broker.descriptor.path}',
    );
    final stopped = Completer<void>();
    final signals = <StreamSubscription<ProcessSignal>>[];
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      signals.add(
        signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }),
      );
    }
    await Future.any([stopped.future, running]);
    await resident.close();
    for (final signal in signals) {
      await signal.cancel();
    }
  }
  exitCode = await running;
}

String _root() {
  var directory = File(Platform.script.toFilePath()).parent;
  for (var i = 0; i < 7; i++) {
    if (File(p.join(directory.path, 'SKILL.md')).existsSync() &&
        Directory(p.join(directory.path, 'tools', 'automation')).existsSync()) {
      return directory.path;
    }
    directory = directory.parent;
  }
  throw const AutomationError(
    'missing_root',
    'Pass --root REPOSITORY or set AUTOMATION_ROOT',
  );
}
