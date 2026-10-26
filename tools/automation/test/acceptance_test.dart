import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/runtime.dart';
import 'package:flutter_ui_automation/src/sessions.dart';

class FixtureConnection extends FlutterConnection {
  FixtureConnection()
    : super(OfficialBridge((_) {}), 'ws://unused', HookProtocol.fixture);
  final png = image.encodePng(image.Image(width: 2, height: 2));
  String page = 'overview';
  int clicks = 0;
  double scrollOffset = 0;
  void Function()? onUpdate;
  void Function()? onState;
  Json snapshot() => {
    'page': page,
    'clicks': clicks,
    'scrollOffset': scrollOffset,
    'text': 'retained input',
    'native': <String, Object?>{'pid': 246},
  };

  @override
  Future<Json> driver(Json arguments) async {
    switch (arguments.text('command')) {
      case 'request_data':
        final request = decodeObject(arguments.text('message'));
        switch (request.text('command')) {
          case 'appScreenshot':
            return {
              'message': jsonEncode({
                'png': base64Encode(png),
                'width': 2,
                'height': 2,
              }),
            };
          case 'state':
            onState?.call();
            return {'message': jsonEncode(snapshot())};
          case 'unfocus':
          case 'settle':
            return {'message': jsonEncode(snapshot())};
          default:
            throw StateError('Unexpected hook: $request');
        }
      case 'tap':
        final key = arguments.text('keyValueString');
        if (key.startsWith('nav-')) {
          page = key.substring(4);
        } else if (page == 'gallery' && key == 'tile-0') {
          clicks++;
        } else {
          throw StateError('Widget $key absent on $page');
        }
        return {};
      case 'scroll':
        if (page != 'gallery') throw StateError('Gallery is not visible');
        scrollOffset = 350;
        return {};
      case 'set_text_entry_emulation':
        return {};
      default:
        throw StateError('Unexpected Driver command: $arguments');
    }
  }

  @override
  Future<void> update({required bool restart}) async => onUpdate?.call();
  @override
  Future<void> disconnect() async {}
}

class FixtureDevice extends AndroidDevice {
  FixtureDevice(Host host, Toolchain tools, this.connection)
    : super(host, tools, 'selected-device', 'test.fixture');
  final FixtureConnection connection;
  bool failCapture = false;
  @override
  Future<Json?> identity() async => {'pid': 246, 'startTicks': '1'};
  @override
  Future<Json> screenshot(
    String output, {
    Json? probe,
    required Cancellation cancellation,
  }) async {
    if (failCapture) {
      throw const AutomationError(
        'stale_presentation',
        'Native capture failed',
      );
    }
    await File(output).writeAsBytes(connection.png);
    return {'path': output, 'width': 2, 'height': 2};
  }
}

class FixtureSession extends Session {
  FixtureSession(
    Toolchain tools,
    Directory directory,
    FixtureConnection connection,
    FixtureDevice device,
  ) : super(
        id: 'fixture',
        platform: TargetPlatform.android,
        project: tools.fixture,
        entrypoint: 'lib/android_driver_main.dart',
        directory: directory,
        lease: Directory(p.join(directory.path, 'lease')),
        owned: false,
        connection: connection,
        android: device,
      ) {
    androidIdentity = {'pid': 246, 'startTicks': '1'};
  }
  @override
  Future<Json> state() => connection.state();
  @override
  Future<void> save() async {}
}

class FixtureRuntime extends AutomationRuntime {
  FixtureRuntime(super.host, super.tools, super.official);
  @override
  Future<Json> capture(Session session, Json args, Cancellation cancellation) =>
      super.capture(session, {
        ...args,
        'presentation': false,
        'compare': false,
      }, cancellation);
}

void main() {
  late Directory directory;
  late FixtureConnection connection;
  late FixtureDevice device;
  late FixtureSession session;
  late FixtureRuntime runtime;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('automation-acceptance-');
    final host = Host(),
        tools = Toolchain(directory.path, flutterRoot: directory.path);
    connection = FixtureConnection();
    device = FixtureDevice(host, tools, connection);
    session = FixtureSession(tools, directory, connection, device);
    runtime = FixtureRuntime(host, tools, OfficialBridge((_) {}));
    runtime.sessions.active[session.id] = session;
  });
  tearDown(() async {
    await runtime.close();
    final resolved = await directory.resolveSymbolicLinks();
    if (!p.isWithin(
      await Directory.systemTemp.resolveSymbolicLinks(),
      resolved,
    )) {
      throw StateError('Unexpected test cleanup path');
    }
    await Directory(resolved).delete(recursive: true);
  });

  test(
    'native failures retain app PNGs and do not stop later fixture interactions',
    () async {
      device.failCapture = true;
      final report = await runtime.verify(session, {
        'checks': ['overview', 'gallery'],
      }, Cancellation());
      expect(report['completed'], true);
      expect(report['passed'], false);
      expect(connection.clicks, 1);
      expect(connection.scrollOffset, 350);
      final items = report.items('items').map(object).toList();
      expect(
        items.singleWhere((item) => item['channel'] == 'gallery')['passed'],
        true,
      );
      for (final page in ['overview', 'gallery']) {
        expect(
          items.singleWhere(
            (item) => item['channel'] == '$page/native',
          )['passed'],
          false,
        );
        final app = items.singleWhere((item) => item['channel'] == '$page/app');
        expect(app['passed'], true);
        expect(
          await File(app.child('result').text('path')).readAsBytes(),
          connection.png,
        );
      }
      final saved = decodeObject(
        await File(
          p.join(report.text('directory'), 'report.json'),
        ).readAsString(),
      );
      expect(saved['completed'], true);
      expect(saved['passed'], false);
    },
  );

  test(
    'cancellation after every requested group succeeds cannot publish acceptance',
    () async {
      final cancellation = Cancellation();
      connection.onUpdate = cancellation.cancel;
      await expectLater(
        runtime.verify(session, {
          'checks': ['hot-reload'],
        }, cancellation),
        throwsA(
          isA<AutomationError>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      final reports = await directory
          .list(recursive: true)
          .where((file) => p.basename(file.path) == 'report.json')
          .toList();
      final report = decodeObject(
        await File(reports.single.path).readAsString(),
      );
      expect(report['completed'], false);
      expect(report['passed'], false);
      expect(report.items('items').map(object).single['passed'], true);
    },
  );
  test(
    'cancelled verification job retains incomplete evidence and cannot complete',
    () async {
      connection.onUpdate = () =>
          runtime.jobs.values.single.cancellation.cancel();
      final started = (await runtime.call('automation_verify', {
        'sessionId': session.id,
        'checks': ['hot-reload'],
      }, Cancellation())).child('structuredContent');
      final completed = (await runtime.call('automation_jobs', {
        'action': 'wait',
        'jobId': started['jobId'],
        'waitSeconds': 5,
      }, Cancellation())).child('structuredContent');
      expect(completed['state'], 'cancelled');
      final result = completed.child('result');
      expect(result['isError'], true);
      expect(result.child('structuredContent')['code'], 'cancelled');
      final reports = await directory
          .list(recursive: true)
          .where((file) => p.basename(file.path) == 'report.json')
          .toList();
      final report = decodeObject(
        await File(reports.single.path).readAsString(),
      );
      expect(report['completed'], false);
      expect(report['passed'], false);
      expect(report.items('items').map(object).single['passed'], true);
    },
  );

  test(
    'cancellation during final report persistence cannot publish acceptance',
    () async {
      final cancellation = Cancellation();
      connection.onUpdate = () {
        var observations = 0;
        connection.onState = () {
          // The first observation completes the reload check; the next is the
          // final state. Its timer runs while the report's async write is pending.
          if (++observations == 2) Timer.run(cancellation.cancel);
        };
      };
      await expectLater(
        runtime.verify(session, {
          'checks': ['hot-reload'],
        }, cancellation),
        throwsA(
          isA<AutomationError>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(cancellation.cancelled, true);
      final reports = await directory
          .list(recursive: true)
          .where((file) => p.basename(file.path) == 'report.json')
          .toList();
      final report = decodeObject(
        await File(reports.single.path).readAsString(),
      );
      expect(report['completed'], false);
      expect(report['passed'], false);
      expect(report.items('items').map(object).single['passed'], true);
    },
  );

  test(
    'job cancelled during final persistence retains an incomplete report',
    () async {
      connection.onUpdate = () {
        var observations = 0;
        connection.onState = () {
          if (++observations == 2) {
            Timer.run(runtime.jobs.values.single.cancellation.cancel);
          }
        };
      };
      final started = (await runtime.call('automation_verify', {
        'sessionId': session.id,
        'checks': ['hot-reload'],
      }, Cancellation())).child('structuredContent');
      final completed = (await runtime.call('automation_jobs', {
        'action': 'wait',
        'jobId': started['jobId'],
        'waitSeconds': 5,
      }, Cancellation())).child('structuredContent');
      expect(completed['state'], 'cancelled');
      final result = completed.child('result');
      expect(result['isError'], true);
      expect(result.child('structuredContent')['code'], 'cancelled');
      final reports = await directory
          .list(recursive: true)
          .where((file) => p.basename(file.path) == 'report.json')
          .toList();
      final report = decodeObject(
        await File(reports.single.path).readAsString(),
      );
      expect(report['completed'], false);
      expect(report['passed'], false);
      expect(report.items('items').map(object).single['passed'], true);
    },
  );
}
