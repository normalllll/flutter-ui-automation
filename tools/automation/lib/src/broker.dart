import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:dart_mcp/server.dart';

import 'host.dart';
import 'protocol.dart';
import 'runtime.dart';

/// A thin, loopback-only CLI transport into the same runtime used by MCP.
/// The descriptor carries a fresh per-process secret, never a VM service URI.
class Broker {
  Broker(this.runtime);
  final AutomationRuntime runtime;
  HttpServer? _server;
  RandomAccessFile? _lease;
  late final String token;
  File get descriptor => File(p.join(runtime.tools.artifacts, 'service.json'));
  final _calls = <Future<void>>{};
  File get owner => File(p.join(runtime.tools.artifacts, 'service-owner.json'));
  Future<void> start() async {
    token = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await owner.parent.create(recursive: true);
    // The OS releases this non-blocking lock even after a hard process crash.
    // A partially written descriptor cannot strand the next service startup.
    final lease = await File(
      p.join(runtime.tools.artifacts, 'service.lock'),
    ).open(mode: FileMode.append);
    try {
      await lease.lock(FileLock.exclusive);
    } on FileSystemException {
      await lease.close();
      throw const AutomationError(
        'service_running',
        'Reuse the existing service instead of starting another',
      );
    }
    _lease = lease;
    try {
      await owner.writeAsString(jsonEncode({'token': token, 'pid': pid}));
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await writeJson(descriptor, {
        'pid': pid,
        'port': _server!.port,
        'token': token,
        'version': '0.2.0',
      });
      _server!.listen((request) {
        final call = _serve(request);
        _calls.add(call);
        unawaited(call.whenComplete(() => _calls.remove(call)));
      });
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.method != 'POST' ||
          request.uri.path != '/call' ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $token') {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      final bytes = <int>[];
      await for (final data in request) {
        bytes.addAll(data);
        if (bytes.length > 1024 * 1024) {
          throw const AutomationError(
            'request_too_large',
            'Request exceeds 1 MiB',
          );
        }
      }
      final input = decodeObject(utf8.decode(bytes));
      final name = input.text('name'), args = input.child('arguments');
      final definition = toolDefinitions
          .where((t) => t['name'] == name)
          .firstOrNull;
      if (definition == null) {
        throw const AutomationError(
          'unknown_tool',
          'CLI accepts automation tools only; official Flutter tools use MCP',
        );
      }
      final errors = Tool.fromMap(definition).inputSchema.validate(args);
      if (errors.isNotEmpty) {
        throw AutomationError(
          'invalid_argument',
          errors.map((e) => e.toErrorString()).join('\n'),
        );
      }
      final result = await runtime.call(name, args, Cancellation());
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    } catch (e) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(toolFailure(e)));
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async {
    // Runtime cancels queued jobs separately; allow live short calls to unwind.
    await Future.wait(_calls.toList());
    await _server?.close(force: true);
    if (await descriptor.exists()) {
      try {
        if (decodeObject(await descriptor.readAsString())['token'] == token) {
          await descriptor.delete();
        }
      } catch (e) {
        stderr.writeln('Broker descriptor cleanup: $e');
      }
    }
    if (await owner.exists() &&
        decodeObject(await owner.readAsString())['token'] == token) {
      await owner.delete();
    }
    await _lease?.unlock();
    await _lease?.close();
    _lease = null;
  }
}

Future<Json> brokerCall(
  Toolchain tools,
  String name,
  Json args, {
  Cancellation? cancellation,
}) async {
  final descriptor = File(p.join(tools.artifacts, 'service.json'));
  if (!await descriptor.exists()) {
    throw const AutomationError(
      'service_not_running',
      'Start the MCP connection or run automation serve once',
    );
  }
  final info = decodeObject(await descriptor.readAsString());
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  // Abandoning the request does not stop work already accepted by the owner;
  // long operations use automation_jobs for cancellation.
  unawaited(cancellation?.whenCancelled.then((_) => client.close(force: true)));
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${info.integer('port')}/call'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${info.text('token')}',
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'name': name, 'arguments': args}));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw AutomationError(
        'broker_rejected',
        'Broker returned ${response.statusCode}',
      );
    }
    return decodeObject(await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}
