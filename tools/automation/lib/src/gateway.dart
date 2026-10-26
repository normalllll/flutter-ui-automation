import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp_server/dart_mcp_server.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';

import 'protocol.dart';

typedef ToolHandler = Future<Json> Function(
  String name,
  Json arguments,
  Cancellation cancellation,
);

class OfficialBridge {
  OfficialBridge(this._send);
  final void Function(Json) _send;
  final _pending = <String, Completer<Json>>{};
  int _sequence = 0;
  final _prefix =
      'automation-internal-${Random.secure().nextInt(1 << 32)}-${Random.secure().nextInt(1 << 32)}';
  final ready = Completer<void>();
  Future<Json> request(
    String method,
    Json params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    await ready.future.timeout(const Duration(seconds: 30));
    final id = '$_prefix-${++_sequence}';
    final completed = Completer<Json>();
    _pending[id] = completed;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    try {
      return await completed.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  bool receive(Json message) {
    final completed = _pending[message['id']];
    if (completed == null) {
      return message['id'] is String &&
          (message['id']! as String).startsWith('$_prefix-');
    }
    if (message['error'] case final Map<String, Object?> error) {
      completed.completeError(
        AutomationError('upstream_rpc', '${error['message']}', error),
      );
    } else {
      completed.complete(object(message['result']));
    }
    return true;
  }

  Future<Json> tool(String name, Json arguments) async {
    final value = await request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    if (value['isError'] == true) {
      throw AutomationError('flutter_tool_failed', contentText(value), {
        'tool': name,
      });
    }
    return value;
  }

  static String contentText(Json result) => result
      .items('content')
      .map(object)
      .where((c) => c['type'] == 'text')
      .map((c) => c.text('text'))
      .join('\n');
  void closed() {
    for (final completed in _pending.values) {
      if (!completed.isCompleted) {
        completed.completeError(
          const AutomationError(
            'connection_closed',
            'Official MCP connection closed',
          ),
        );
      }
    }
    _pending.clear();
  }
}

/// A single external MCP connection, with the unmodified official implementation
/// embedded in process. Upstream protocol frames keep their IDs and direction.
class AutomationGateway {
  AutomationGateway(
    this.external, {
    required this.flutterRoot,
    required this.tools,
    required this.handle,
    required this.closeRuntime,
  }) {
    official = OfficialBridge(_forward);
  }
  final StreamChannel<String> external;
  final String flutterRoot;
  final List<Json> tools;
  final ToolHandler handle;
  final Future<void> Function() closeRuntime;
  late final OfficialBridge official;
  final _upstream = StreamChannelController<String>();
  final _lists = <Object, bool>{};
  final _connections = <String>{};
  final _vmActions = <Object, ({String command, String uri})>{};
  final _active =
      <Object, ({Cancellation cancellation, Future<void> completion})>{};
  bool _closing = false;
  final _stop = Completer<void>();
  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }

  void _forward(Json message) {
    if (message['method'] == 'tools/call') {
      final params = object(message['params']);
      if (params['name'] == 'vm_service' &&
          params['arguments'] is Map<String, Object?>) {
        final args = params.child('arguments');
        if (args['appUri'] case final String uri) {
          final command = args['command'];
          if (command == 'connect' || command == 'disconnect') {
            _vmActions[message['id']!] = (
              command: command! as String,
              uri: uri,
            );
          }
        }
      }
    }
    _upstream.foreign.sink.add(jsonEncode(message));
  }

  Future<int> run() async {
    final subscription = _upstream.foreign.stream.listen(
      (line) {
        final message = decodeObject(line);
        if (message['method'] == null) {
          final action = _vmActions.remove(message['id']);
          if (action != null &&
              message['error'] == null &&
              object(message['result'])['isError'] != true) {
            action.command == 'connect'
                ? _connections.add(action.uri)
                : _connections.remove(action.uri);
          }
        }
        if (official.receive(message) || _closing) return;
        final append = _lists.remove(message['id']);
        if (append == true && message['result'] is Map<String, Object?>) {
          final result = message.child('result');
          final upstreamTools = result.items('tools');
          final names = upstreamTools
              .map(object)
              .map((t) => t.text('name'))
              .toSet();
          if (tools.any((t) => names.contains(t['name']))) {
            _replyError(message['id'], 'Tool namespace collision');
            return;
          }
          result['tools'] = [...upstreamTools, ...tools];
          external.sink.add(jsonEncode(message));
        } else {
          external.sink.add(line);
        }
      },
      onError: (Object e, StackTrace s) {
        stderr.writeln('$e\n$s');
      },
    );
    final server = DartMCPServer.run([
      // A compiled host is outside the SDK, so upstream cannot infer Dart's
      // location from Platform.resolvedExecutable.
      '--dart-sdk=${p.join(flutterRoot, 'bin', 'cache', 'dart-sdk')}',
      '--flutter-sdk=$flutterRoot',
      '--enable=flutter_driver_command',
    ], channel: _upstream.local);
    // Upstream can reject its configuration before listening. Close the
    // external connection as well so clients do not wait forever for initialize.
    unawaited(
      server.then<void>((_) {
        if (!_closing) stop();
      }, onError: (Object _, StackTrace _) => stop()),
    );
    final incoming = StreamIterator(external.stream);
    try {
      while (await Future.any([
        incoming.moveNext(),
        _stop.future.then((_) => false),
      ])) {
        final line = incoming.current;
        Json message;
        try {
          message = decodeObject(line);
        } catch (e) {
          _replyError(null, '$e', code: -32700);
          continue;
        }
        final requestId = message['id'];
        if (message['jsonrpc'] != '2.0' ||
            requestId != null && requestId is! int && requestId is! String) {
          _replyError(null, 'Invalid JSON-RPC envelope', code: -32600);
          continue;
        }
        try {
          final method = message['method'];
          if (method == 'notifications/initialized' &&
              !official.ready.isCompleted) {
            official.ready.complete();
          }
          if (method == 'notifications/cancelled') {
            final requestId = object(message['params'])['requestId'];
            final local = _active[requestId];
            if (local != null) {
              local.cancellation.cancel();
              continue;
            }
          }
          if (method == 'tools/list' && message['id'] != null) {
            _lists[message['id']!] =
                message['params'] == null ||
                object(message['params'])['cursor'] == null;
          }
          if (method == 'tools/call' && message['id'] != null) {
            final params = object(message['params']);
            final name = params.text('name');
            final definition = tools
                .where((t) => t['name'] == name)
                .firstOrNull;
            if (definition != null) {
              final id = message['id']!;
              final cancellation = Cancellation();
              final completion = _call(id, definition, params, cancellation);
              _active[id] = (
                cancellation: cancellation,
                completion: completion,
              );
              unawaited(completion.whenComplete(() => _active.remove(id)));
              continue;
            }
          }
          _forward(message);
        } on AutomationError catch (e) {
          if (requestId != null) {
            _replyError(requestId, e.message, code: -32602);
          }
        }
      }
    } finally {
      _closing = true;
      await incoming.cancel();
      // Stop owned work before tearing down the connection it needs for cleanup.
      for (final call in _active.values) {
        call.cancellation.cancel();
      }
      try {
        await Future.wait(_active.values.map((c) => c.completion))
            .timeout(const Duration(seconds: 70));
      } catch (e) {
        stderr.writeln('Active call shutdown: $e');
      }
      try {
        await closeRuntime();
      } catch (e) {
        stderr.writeln('Runtime shutdown: $e');
      }
      for (final uri in _connections.toList()) {
        try {
          await official.tool('vm_service', {
            'command': 'disconnect',
            'appUri': uri,
          });
        } catch (e) {
          if (e is! AutomationError ||
              !e.message.contains('Not connected to')) {
            stderr.writeln('VM disconnect: $e');
          }
        }
      }
      _closing = true;
      // If startup failed, upstream never subscribed and the sink's done
      // future cannot complete. Closing still delivers EOF to a live server.
      unawaited(_upstream.foreign.sink.close());
      await server.timeout(const Duration(seconds: 10));
      official.closed();
      await subscription.cancel();
      await external.sink.close();
    }
    return await server;
  }

  Future<void> _call(
    Object id,
    Json definition,
    Json params,
    Cancellation cancellation,
  ) async {
    Json response;
    try {
      final arguments = params['arguments'] == null
          ? <String, Object?>{}
          : params.child('arguments');
      final errors = Tool.fromMap(definition).inputSchema.validate(arguments);
      if (errors.isNotEmpty) {
        throw AutomationError(
          'invalid_argument',
          errors.map((e) => e.toErrorString()).join('\n'),
        );
      }
      response = await handle(params.text('name'), arguments, cancellation);
    } catch (e) {
      response = toolFailure(e);
    }
    // Cancellation is acknowledged by the caller's notification, not a stale
    // success delivered after it asked to stop.
    if (!cancellation.cancelled && !_closing) {
      external.sink.add(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': response}),
      );
    }
  }

  void _replyError(Object? id, String message, {int code = -32603}) {
    external.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      }),
    );
  }
}
