import 'dart:convert';
import 'dart:io';

import 'gateway.dart';
import 'protocol.dart';

enum HookProtocol { fixture, booruflow }

class FlutterConnection {
  FlutterConnection(this.bridge, this.uri, this.hooks);
  final OfficialBridge bridge;
  String uri;
  final HookProtocol hooks;
  String? _isolate;
  int generation = 0;
  bool _connected = false;

  Future<void> connect({Future<void> Function(int)? validateProcess}) async {
    await bridge.tool('vm_service', {'command': 'connect', 'appUri': uri});
    _connected = true;
    if (validateProcess != null) {
      await validateProcess((await vm('getVM')).integer('pid'));
    }
    await waitReady();
    await driver({'command': 'set_frame_sync', 'enabled': 'false'});
  }

  Future<Json> vm(String method, {Json? arguments, String? isolate}) async {
    final result = await bridge.tool('vm_service', {
      'command': 'callMethod',
      'appUri': uri,
      'method': method,
      'arguments': ?arguments,
      'isolateId': ?isolate,
    });
    return decodeObject(OfficialBridge.contentText(result));
  }

  Future<void> rebind() async {
    final vmState = await vm('getVM');
    final isolates = vmState.items('isolates').map(object);
    final main = isolates.where((i) => i['name'] == 'main').firstOrNull;
    if (main == null) {
      throw const AutomationError(
        'app_not_ready',
        'Flutter main isolate is not available',
      );
    }
    final isolate = await vm('getIsolate', isolate: main.text('id'));
    if (!isolate.items('extensionRPCs').contains('ext.flutter.driver')) {
      throw const AutomationError(
        'app_not_ready',
        'Flutter Driver extension is still registering',
      );
    }
    _isolate = main.text('id');
    generation++;
  }

  Future<Json> driver(Json arguments) async {
    if (_isolate == null) await waitReady();
    Json response;
    try {
      response = await vm(
        'ext.flutter.driver',
        isolate: _isolate,
        arguments: {'timeout': '10000', ...arguments},
      );
    } on AutomationError catch (e) {
      // An agent may use the forwarded official hot_restart tool directly.
      // Retry only a rejected dispatch; never repeat an action after a timeout.
      if (e.code != 'flutter_tool_failed' ||
          !RegExp(
            r'Unknown method|Isolate must be runnable|isolate.*not found|invalid.*isolate',
            caseSensitive: false,
          ).hasMatch(e.message)) {
        rethrow;
      }
      _isolate = null;
      await waitReady();
      response = await vm(
        'ext.flutter.driver',
        isolate: _isolate,
        arguments: {'timeout': '10000', ...arguments},
      );
    }
    if (response['isError'] == true) {
      throw AutomationError(
        'driver_failed',
        '${response['response'] ?? response['error']}',
        {'response': response},
      );
    }
    return response['response'] == null ? {} : response.child('response');
  }

  Future<Json> hook(String command, [Json arguments = const {}]) async {
    final response = await driver({
      'command': 'request_data',
      'message': jsonEncode({'command': command, ...arguments}),
    });
    final value = jsonDecode(response.text('message'));
    return value is Map<String, Object?> ? value : {'value': value};
  }

  Future<Json> state() => hook('state');

  /// Ends the presentation hold returned by `prepareCapture`, so the probe is
  /// hidden as soon as no capture needs it. Apps without hold support return
  /// no `hold`; their probe still expires on its own timer.
  Future<void> releaseCapture(Json? probe) async {
    final hold = probe?['hold'];
    if (hold is! int) return;
    try {
      await hook('releaseCapture', {'hold': hold});
    } catch (e) {
      // Best effort: the hold's own expiry still hides the probe.
      stderr.writeln('Probe release: $e');
    }
  }

  Future<Json> orientation(String value, {Cancellation? cancellation}) async {
    final result = await hook('orientation', {'value': value});
    if (result['restoredInterfaceOrientation'] case final int original) {
      await until(
        state,
        (s) => s.child('native')['interfaceOrientation'] == original,
        cancellation: cancellation,
        description: 'original interface orientation',
      );
    }
    return result;
  }

  Future<Json> settle({bool enabled = true}) =>
      enabled && hooks == HookProtocol.fixture
      ? hook('settle')
      : hook('refresh');
  Future<void> update({required bool restart}) async {
    await bridge.tool(restart ? 'hot_restart' : 'hot_reload', {'appUri': uri});
    if (restart) {
      _isolate = null;
      await waitReady();
      await driver({'command': 'set_frame_sync', 'enabled': 'false'});
    }
  }

  Future<void> disconnect() async {
    if (_connected) {
      try {
        await bridge.tool('vm_service', {
          'command': 'disconnect',
          'appUri': uri,
        });
      } on AutomationError catch (e) {
        if (!e.message.contains('Not connected to')) rethrow;
      }
      _connected = false;
    }
  }

  Future<void> waitReady() async {
    AutomationError? lastError;
    try {
      await until(
        () async {
          try {
            await rebind();
            // Extension registration precedes asynchronous native identity setup
            // in test entrypoints. Do not expose a half-initialized session.
            final snapshot = await state();
            return snapshot['native'] is Json &&
                snapshot.child('native')['pid'] is int;
          } on AutomationError catch (e) {
            if ([
              'app_not_ready',
              'flutter_tool_failed',
              'driver_failed',
            ].contains(e.code)) {
              lastError = e;
              return false;
            }
            rethrow;
          }
        },
        (ready) => ready,
        timeout: const Duration(seconds: 25),
        description: 'Flutter Driver extension registration',
      );
    } on AutomationError catch (e) {
      if (e.code == 'timeout') {
        throw AutomationError(
          'app_not_ready',
          'Flutter Driver/native state did not become ready',
          {'lastError': lastError?.toJson()},
        );
      }
      rethrow;
    }
  }
}

Json finder(Json selector) {
  final value = selector['value'];
  return switch (selector.text('kind')) {
    'key' => {
      'finderType': 'ByValueKey',
      'keyValueString': '$value',
      'keyValueType': value is int ? 'int' : 'String',
    },
    'text' => {'finderType': 'ByText', 'text': selector.text('value')},
    'type' => {'finderType': 'ByType', 'type': selector.text('value')},
    'semantics' => {
      'finderType': 'BySemanticsLabel',
      'label': selector.text('value'),
      'isRegExp': 'false',
    },
    'descendant' || 'ancestor' => {
      'finderType': selector.text('kind') == 'ancestor'
          ? 'Ancestor'
          : 'Descendant',
      'of': jsonEncode(finder(selector.child('of'))),
      'matching': jsonEncode(finder(selector.child('matching'))),
      'matchRoot': 'false',
      'firstMatchOnly': '${selector.flag('firstMatchOnly')}',
    },
    _ => throw const AutomationError(
      'invalid_selector',
      'Use key, text, type, semantics, descendant or ancestor',
    ),
  };
}
