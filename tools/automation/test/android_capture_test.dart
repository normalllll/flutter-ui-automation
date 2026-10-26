import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _package = 'test.capture.fixture';
const _serial = 'explicit-device:5555';

HostResult _result(String value) =>
    HostResult(0, Uint8List.fromList(utf8.encode(value)), '');

class _AdbHost extends Host {
  _AdbHost(this.handle);
  final FutureOr<HostResult> Function(List<String>) handle;
  final calls = <List<String>>[];

  @override
  Future<HostResult> run(
    String executable,
    List<String> arguments, {
    String? directory,
    Duration timeout = const Duration(seconds: 30),
    Cancellation? cancellation,
    bool check = true,
  }) async {
    cancellation?.check();
    expect(arguments.take(2), ['-s', _serial]);
    final command = arguments.skip(2).toList();
    calls.add(command);
    return handle(command);
  }
}

Toolchain _tools(Directory directory) => Toolchain(
  directory.path,
  flutterRoot: directory.path,
  environment: {'ADB': Platform.resolvedExecutable},
);

Matcher _error(String code) =>
    isA<AutomationError>().having((e) => e.code, 'code', code);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('android-capture-');
  });
  tearDown(() async {
    final resolved = await directory.resolveSymbolicLinks();
    if (!p.isWithin(
      await Directory.systemTemp.resolveSymbolicLinks(),
      resolved,
    )) {
      throw StateError('Unexpected test cleanup path');
    }
    await Directory(resolved).delete(recursive: true);
  });

  test('device and package must be explicit, safe ADB targets', () {
    final host = _AdbHost((_) => throw StateError('Unexpected ADB command'));
    for (final serial in ['', '-s', 'multiple devices', 'a\nb']) {
      expect(
        () => AndroidDevice(host, _tools(directory), serial, _package),
        throwsA(_error('invalid_device')),
      );
    }
    for (final package in ['', 'singleword', 'test.app;other']) {
      expect(
        () => AndroidDevice(host, _tools(directory), _serial, package),
        throwsA(_error('invalid_package')),
      );
    }
    expect(host.calls, isEmpty);
  });

  test(
    'instance validation matches package, device token and native PID',
    () async {
      var token = 'owned-instance';
      var devicePid = 42;
      final host = _AdbHost((args) {
        return switch (args.join(' ')) {
          'get-state' => _result('device\n'),
          'shell run-as $_package cat files/capture-instance' => _result(token),
          'shell pidof $_package' => _result('$devicePid\n'),
          _ when args.take(2).join(' ') == 'shell cat' => _result(
            '$devicePid (fixture worker) S ${List.filled(18, '0').join(' ')} 12345 0',
          ),
          _ => throw StateError('Unexpected ADB command: $args'),
        };
      });
      final device = AndroidDevice(host, _tools(directory), _serial, _package);
      final native = <String, Object?>{
        'package': _package,
        'instanceToken': 'owned-instance',
        'pid': 42,
      };
      await device.validateInstance(native, Cancellation());
      expect(await device.identity(), {'pid': 42, 'startTicks': '12345'});
      await expectLater(
        device.validateInstance({
          ...native,
          'package': 'other.app',
        }, Cancellation()),
        throwsA(_error('wrong_instance')),
      );
      token = 'another-device-instance';
      await expectLater(
        device.validateInstance(native, Cancellation()),
        throwsA(_error('wrong_instance')),
      );
      token = 'owned-instance';
      devicePid = 43;
      await expectLater(
        device.validateInstance(native, Cancellation()),
        throwsA(_error('wrong_instance')),
      );
    },
  );

  test(
    'screenshot preserves PNG bytes and selects the current physical panel',
    () async {
      final png = image.encodePng(image.Image(width: 32, height: 18));
      var targetChecks = 0;
      final host = _AdbHost(
        (args) => switch (args.join(' ')) {
          'get-state' => _result('device'),
          'shell dumpsys activity activities' => _result(
            'mResumedActivity: ActivityRecord{ $_package/.MainActivity }',
          ),
          'shell dumpsys display' => _result('''Display 0:
    mPrimaryDisplayDevice=Internal (local:34)
  Display 1:
    mPrimaryDisplayDevice=Other (local:12)
'''),
          'exec-out screencap -p -d 34' => HostResult(0, png, ''),
          _ => throw StateError('Unexpected ADB command: $args'),
        },
      );
      final device = AndroidDevice(host, _tools(directory), _serial, _package);
      final output = File(p.join(directory.path, 'shot.png'));
      final notes = await device.screenshot(
        output.path,
        cancellation: Cancellation(),
      );
      expect(await output.readAsBytes(), png);
      expect(notes, containsPair('displayId', '34'));
      expect(notes, containsPair('deviceId', _serial));
      expect(notes, containsPair('presentationVerified', false));
      targetChecks = host.calls.where((a) => a.join(' ') == 'get-state').length;
      expect(targetChecks, 2);
      expect(host.calls.where((a) => a.first == 'exec-out').single, [
        'exec-out',
        'screencap',
        '-p',
        '-d',
        '34',
      ]);
    },
  );

  test(
    'panel switch retains failed pixels and removes stale successful output',
    () async {
      final png = image.encodePng(image.Image(width: 32, height: 18));
      var panelReads = 0;
      final host = _AdbHost(
        (args) => switch (args.join(' ')) {
          'get-state' => _result('device'),
          'shell dumpsys activity activities' => _result(
            'topResumedActivity: ActivityRecord{ $_package/.MainActivity }',
          ),
          'shell dumpsys display' => _result(
            'Display 0:\n mPrimaryDisplayDevice=Internal (local:${++panelReads == 1 ? 12 : 34})\n',
          ),
          'exec-out screencap -p -d 12' => HostResult(0, png, ''),
          _ => throw StateError('Unexpected ADB command: $args'),
        },
      );
      final output = File(p.join(directory.path, 'shot.png'));
      await output.writeAsString('old success');
      await File('${output.path}.partial.png').writeAsString('old partial');
      final diagnostic = File(p.join(directory.path, 'shot.failed-device.png'));
      await diagnostic.writeAsString('old failure');
      await expectLater(
        AndroidDevice(
          host,
          _tools(directory),
          _serial,
          _package,
        ).screenshot(output.path, cancellation: Cancellation()),
        throwsA(_error('display_changed')),
      );
      expect(await output.exists(), false);
      expect(await File('${output.path}.partial.png').exists(), false);
      expect(await diagnostic.readAsBytes(), png);
    },
  );

  test(
    'stale presented marker is retried without publishing its pixels',
    () async {
      Uint8List marker(int token) {
        final pixels = image.Image(width: 320, height: 50);
        final word = (0xa << 28) | (token << 4) | 5;
        for (var bit = 0; bit < 32; bit++) {
          final color = word >> (31 - bit) & 1 == 1
              ? [240, 180, 41]
              : [22, 50, 79];
          for (var y = 0; y < 8; y++) {
            for (var x = bit * 10; x < (bit + 1) * 10; x++) {
              pixels.setPixelRgb(x, y, color[0], color[1], color[2]);
            }
          }
        }
        return image.encodePng(pixels);
      }

      final stale = marker(1), fresh = marker(2);
      final output = File(p.join(directory.path, 'shot.png'));
      var captures = 0;
      final host = _AdbHost((args) async {
        if (args.join(' ') == 'exec-out screencap -p -d 34') {
          expect(await output.exists(), false);
          return HostResult(0, ++captures == 1 ? stale : fresh, '');
        }
        return switch (args.join(' ')) {
          'get-state' => _result('device'),
          'shell dumpsys activity activities' => _result(
            'mResumedActivity: ActivityRecord{ $_package/.MainActivity }',
          ),
          'shell dumpsys display' => _result(
            'Display 0:\n mPrimaryDisplayDevice=Internal (local:34)\n',
          ),
          _ => throw StateError('Unexpected ADB command: $args'),
        };
      });
      final notes =
          await AndroidDevice(
            host,
            _tools(directory),
            _serial,
            _package,
          ).screenshot(
            output.path,
            cancellation: Cancellation(),
            probe: {
              'token': 2,
              'rect': {'x': 0, 'y': 0, 'width': 320, 'height': 8},
              'pixelRatio': 1,
              'native': {
                'viewBounds': {'x': 0, 'y': 0, 'width': 320, 'height': 50},
              },
            },
          );
      expect(captures, 2);
      expect(notes['presentationVerified'], true);
      expect(await output.readAsBytes(), fresh);
      expect(await File('${output.path}.partial.png').exists(), false);
    },
  );

  test(
    'unpresented token times out without a success PNG and retains rejected pixels',
    () async {
      final png = image.encodePng(image.Image(width: 320, height: 50));
      final output = File(p.join(directory.path, 'shot.png'));
      final diagnostic = File(p.join(directory.path, 'shot.failed-device.png'));
      await output.writeAsString('old success');
      await diagnostic.writeAsString('old failure');
      var captures = 0;
      final host = _AdbHost((args) async {
        if (args.join(' ') == 'exec-out screencap -p -d 34') {
          expect(await output.exists(), false);
          captures++;
          // Model transport latency without changing the production deadline.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return HostResult(0, png, '');
        }
        return switch (args.join(' ')) {
          'get-state' => _result('device'),
          'shell dumpsys activity activities' => _result(
            'mResumedActivity: ActivityRecord{ $_package/.MainActivity }',
          ),
          'shell dumpsys display' => _result(
            'Display 0:\n mPrimaryDisplayDevice=Internal (local:34)\n',
          ),
          _ => throw StateError('Unexpected ADB command: $args'),
        };
      });
      await expectLater(
        AndroidDevice(host, _tools(directory), _serial, _package).screenshot(
          output.path,
          cancellation: Cancellation(),
          probe: {
            'token': 2,
            'rect': {'x': 0, 'y': 0, 'width': 320, 'height': 8},
            'pixelRatio': 1,
            'native': {
              'viewBounds': {'x': 0, 'y': 0, 'width': 320, 'height': 50},
            },
          },
        ),
        throwsA(_error('stale_presentation')),
      );
      expect(captures, greaterThan(1));
      expect(await output.exists(), false);
      expect(await File('${output.path}.partial.png').exists(), false);
      expect(await diagnostic.readAsBytes(), png);
    },
    timeout: const Timeout(Duration(seconds: 25)),
  );

  test('wrong resumed app blocks capture and clears old evidence', () async {
    final host = _AdbHost(
      (args) => switch (args.join(' ')) {
        'get-state' => _result('device'),
        'shell dumpsys activity activities' => _result(
          'mResumedActivity: ActivityRecord{ other.app/.MainActivity }',
        ),
        _ => throw StateError('Capture/input must not run: $args'),
      },
    );
    final output = File(p.join(directory.path, 'shot.png'));
    final diagnostic = File(p.join(directory.path, 'shot.failed-device.png'));
    await output.writeAsString('old success');
    await diagnostic.writeAsString('old failure');
    await expectLater(
      AndroidDevice(
        host,
        _tools(directory),
        _serial,
        _package,
      ).screenshot(output.path, cancellation: Cancellation()),
      throwsA(_error('target_not_resumed')),
    );
    expect(await output.exists(), false);
    expect(await diagnostic.exists(), false);
    expect(host.calls.any((a) => a.contains('screencap')), false);
  });
}
