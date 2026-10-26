import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';

import 'protocol.dart';

/// Raw MCP client used by the resident CLI host and integration tests. The
/// external MCP endpoint remains the official protocol implementation.
class WireClient {
  WireClient(this.channel, {required this.root}) {
    _subscription = channel.stream.listen(
      _receive,
      onDone: () {
        for (final pending in _pending.values) {
          if (!pending.isCompleted) {
            pending.completeError(
              const AutomationError('connection_closed', 'MCP stream closed'),
            );
          }
        }
        _pending.clear();
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }
  final StreamChannel<String> channel;
  final String root;
  late final StreamSubscription<String> _subscription;
  final _pending = <int, Completer<Json>>{};
  final notifications = <Json>[];
  final _closed = Completer<void>();
  int _next = 0;
  void _receive(String line) {
    final message = decodeObject(line);
    if (message['method'] != null) {
      if (message['id'] != null) {
        channel.sink.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            if (message['method'] == 'roots/list')
              'result': {
                'roots': [
                  {'uri': root, 'name': 'automation project'},
                ],
              }
            else
              'error': {
                'code': -32601,
                'message': 'Unsupported client request',
              },
          }),
        );
      } else {
        notifications.add(message);
      }
      return;
    }
    _pending.remove(message['id'])?.complete(message);
  }

  ({int id, Future<Json> result}) begin(String method, [Json? params]) {
    final id = ++_next;
    final pending = Completer<Json>();
    _pending[id] = pending;
    channel.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );
    return (
      id: id,
      result: pending.future
          .timeout(const Duration(minutes: 10))
          .whenComplete(() => _pending.remove(id)),
    );
  }

  Future<Json> request(String method, [Json? params]) =>
      begin(method, params).result;
  void notify(String method, [Json? params]) => channel.sink.add(
    jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': ?params}),
  );
  Future<void> initialize() async {
    final response = await request('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': {
        'roots': {'listChanged': true},
      },
      'clientInfo': {'name': 'flutter-ui-automation', 'version': '0.2.0'},
    });
    if (response['error'] != null) {
      throw AutomationError('initialize_failed', '$response');
    }
    notify('notifications/initialized');
  }

  Future<Json> tool(String name, [Json args = const {}]) async {
    final response = await request('tools/call', {
      'name': name,
      'arguments': args,
    });
    if (response['error'] != null) {
      throw AutomationError('rpc_failed', '${response['error']}');
    }
    return response.child('result');
  }

  Future<void> close() async {
    await channel.sink.close();
    await _closed.future.timeout(const Duration(seconds: 90));
    await _subscription.cancel();
  }
}
