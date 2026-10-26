import 'dart:async';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/client.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

void main() {
  test(
    'upstream initialization failure closes the gateway with an error',
    () async {
      final wire = StreamChannelController<String>();
      var closed = false;
      final output = wire.foreign.stream.drain<void>();
      final gateway = AutomationGateway(
        wire.local,
        flutterRoot:
            '${Directory.systemTemp.path}/missing-automation-flutter-sdk',
        tools: [],
        handle: (_, _, _) async => toolResult({}),
        closeRuntime: () async => closed = true,
      );
      expect(await gateway.run().timeout(const Duration(seconds: 5)), 1);
      await output;
      expect(closed, true);
      await wire.foreign.sink.close();
    },
  );
  test('embedded official protocol, validation, cancellation and clean EOF', () async {
    final wire = StreamChannelController<String>();
    final started = Completer<void>(), cancelled = Completer<void>();
    var calls = 0, closed = false;
    final root = Directory('../..').absolute.path;
    final gateway = AutomationGateway(
      wire.local,
      flutterRoot: Toolchain(root).flutterRoot,
      tools: [
        {
          'name': 'automation_test',
          'description': 'Local protocol test',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'delay': {'type': 'boolean'},
            },
            'additionalProperties': false,
          },
        },
      ],
      handle: (name, args, c) async {
        calls++;
        if (args.flag('delay')) {
          started.complete();
          await c.whenCancelled;
          cancelled.complete();
          c.check();
        }
        return toolResult({'echo': true});
      },
      closeRuntime: () async {
        closed = true;
      },
    );
    final running = gateway.run();
    final client = WireClient(
      wire.foreign,
      root: Directory(root).uri.toString(),
    );
    try {
      await client.initialize();
      final list = (await client.request('tools/list'))
          .child('result')
          .items('tools')
          .map(object)
          .map((t) => t.text('name'));
      expect(
        list,
        containsAll(['automation_test', 'hot_reload', 'vm_service']),
      );
      final invalid = await client.tool('automation_test', {
        'unexpected': true,
      });
      expect(invalid['isError'], true);
      expect(calls, 0);
      expect(
        (await client.request('tools/call', {'name': 3}))['error'],
        isNotNull,
      );
      client.notify('notifications/cancelled');
      expect(
        (await client.tool('automation_test'))
            .child('structuredContent')['echo'],
        true,
      );
      final slow = client.begin('tools/call', {
        'name': 'automation_test',
        'arguments': {'delay': true},
      });
      unawaited(slow.result.catchError((Object _) => <String, Object?>{}));
      await started.future;
      client.notify('notifications/cancelled', {'requestId': slow.id});
      await cancelled.future;
      expect((await client.request('unknown-method'))['error'], isNotNull);
      expect(
        (await client.request('resources/list')).child('result')['resources'],
        isA<List<Object?>>(),
      );
      expect(
        (await client.request('prompts/list')).child('result')['prompts'],
        isA<List<Object?>>(),
      );
    } finally {
      // Closing the sink delivers EOF; do not wait on a cancelled request which
      // correctly receives no late success response after cancellation.
      await client.close();
      await running.timeout(const Duration(seconds: 10));
    }
    expect(closed, true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
