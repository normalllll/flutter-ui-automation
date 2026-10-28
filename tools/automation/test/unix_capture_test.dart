import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/pixels.dart';
import 'package:flutter_ui_automation/src/target_platform.dart';
import 'package:flutter_ui_automation/src/unix_process.dart';
import 'package:flutter_ui_automation/src/unix_target.dart';

class _DisplayHost extends Host {
  _DisplayHost(this.capture);
  final Future<void> Function(String) capture;
  @override
  Future<HostResult> run(
    String executable,
    List<String> arguments, {
    String? directory,
    Duration timeout = const Duration(seconds: 30),
    Cancellation? cancellation,
    bool check = true,
  }) async {
    expect(executable, 'xcrun');
    if (arguments.contains('launchctl')) {
      return HostResult(
        0,
        utf8.encode('$pid 0 UIKitApplication:dev.example.fixture[test]'),
        '',
      );
    }
    expect(arguments.take(3), [
      'simctl',
      'io',
      '00000000-0000-0000-0000-000000000001',
    ]);
    await capture(arguments.last);
    return HostResult(0, Uint8List(0), '');
  }
}

void main() {
  test(
    'simulator process query selects exact running bundle, excluding cached jobs',
    () {
      const listing =
          'PID Status Label\n'
          '- 0 UIKitApplication:dev.example.fixture[old]\n'
          '900 0 UIKitApplication:dev.example.fixtureExtra[other]\n'
          '123 0 UIKitApplication:dev.example.fixture[c00a][rb-legacy]\n';
      expect(simulatorAppPid(listing, 'dev.example.fixture'), 123);
      expect(simulatorAppPid(listing, 'dev.example.missing'), null);
    },
  );
  for (final rotated in CaptureRotation.values) {
    test(
      'retains rejected display frame and resolves exact token (rotated: $rotated)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'unix-capture-',
        );
        final output = File(p.join(directory.path, 'shot.png'));
        final rejected = File(p.join(directory.path, 'shot.failed-native.png'));
        await output.writeAsString('old success');
        final portrait = image.encodePng(image.Image(width: 40, height: 80));
        final landscape = image.Image(width: 80, height: 40);
        for (var y = 0; y < 40; y++) {
          for (var x = 0; x < 80; x++) {
            landscape.setPixelRgb(x, y, x * 3, y * 6, (x + y) * 2);
          }
        }
        const token = 123;
        paintProbe(landscape, {
          'token': token,
          'pixelRatio': 1,
          'rect': {'x': 0, 'y': 0, 'width': 80, 'height': 40},
          'native': {
            'viewBounds': {'x': 0, 'y': 0, 'width': 80, 'height': 40},
          },
        });
        final expected = image.encodePng(rotated.apply(landscape));
        var attempts = 0;
        final host = _DisplayHost((path) async {
          expect(await output.exists(), false);
          await File(path).writeAsBytes(++attempts == 1 ? portrait : expected);
        });
        final target = UnixTarget(
          host,
          Toolchain(directory.path, flutterRoot: directory.path),
          TargetPlatform.ios,
          deviceId: '00000000-0000-0000-0000-000000000001',
          bundleId: 'dev.example.fixture',
        )..expectedIdentity = UnixIdentity.read(pid);
        try {
          final result = await target.screenshot(
            output.path,
            {
              'pid': pid,
              'platform': 'ios',
              'bundleId': 'dev.example.fixture',
              'viewBounds': {'x': 0, 'y': 0, 'width': 80, 'height': 40},
            },
            probe: {
              'token': token,
              'pixelRatio': 1,
              'rect': {'x': 0, 'y': 0, 'width': 80, 'height': 40},
              'native': {
                'viewBounds': {'x': 0, 'y': 0, 'width': 80, 'height': 40},
              },
            },
            cancellation: Cancellation(),
          );
          expect(result['presentationVerified'], true);
          expect(result['rotationToAppDegrees'], (360 - rotated.degrees) % 360);
          expect(attempts, 2);
          expect(await rejected.readAsBytes(), portrait);
          expect(await output.readAsBytes(), expected);
          final app = File(p.join(directory.path, 'app.png'));
          await app.writeAsBytes(image.encodePng(landscape));
          final comparison = await compareCapture(
            {'path': app.path},
            result,
            android: true,
            state: {
              'native': {
                'viewBounds': {'x': 0, 'y': 0, 'width': 80, 'height': 40},
              },
            },
          );
          expect(comparison['passed'], true);
          expect(await File('${output.path}.partial.png').exists(), false);
        } finally {
          for (final file in await directory.list().toList()) {
            await file.delete();
          }
          await directory.delete();
        }
      },
      skip: Platform.isWindows,
    );
  }
}
