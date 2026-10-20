import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

import 'driver.dart' show request;

/// Records Flutter content via the existing test capture hook, not the desktop.
Future<void> main(List<String> args) async {
  stdout.encoding = utf8;
  if (args.length != 4) {
    stderr.writeln('record_app.dart VM_URI FRAME_DIRECTORY SECONDS FPS');
    exitCode = 64;
    return;
  }
  final directory = Directory(args[1]);
  final seconds = int.parse(args[2]);
  final fps = int.parse(args[3]);
  if (seconds < 1 || seconds > 30 || fps < 1 || fps > 15) {
    throw ArgumentError('seconds 1..30; fps 1..15');
  }
  await directory.create(recursive: true);
  final driver = await FlutterDriver.connect(
    dartVmServiceUrl: args[0],
    logCommunicationToFile: false,
  ).timeout(const Duration(seconds: 15));
  try {
    await driver.runUnsynchronized(() async {
      final clock = Stopwatch()..start();
      Map<String, Object?>? dimensions;
      // A slow capture hook delays later frames. The PNG sequence is encoded
      // at a constant rate, so lag compresses the video timeline; report it.
      var lateFrames = 0;
      var maxLagUs = 0;
      stdout.writeln(jsonEncode({'ready': true}));
      for (var index = 0; index < seconds * fps; index++) {
        final lag = clock.elapsedMicroseconds - index * 1000000 ~/ fps;
        if (lag > maxLagUs) maxLagUs = lag;
        if (lag > 1000000 ~/ fps ~/ 2) lateFrames++;
        final frame = jsonDecode(
          await request(driver, 'appScreenshot'),
        ) as Map<String, Object?>;
        final current = {
          'width': frame['width'],
          'height': frame['height'],
          'pixelRatio': frame['pixelRatio'],
        };
        dimensions ??= current;
        if (jsonEncode(current) != jsonEncode(dimensions)) {
          throw StateError(
            'App resized during recording; restart at its new size',
          );
        }
        await File('${directory.path}/${index.toString().padLeft(4, '0')}.png')
            .writeAsBytes(base64Decode(frame['png'] as String));
        final wait = ((index + 1) * 1000000 ~/ fps) - clock.elapsedMicroseconds;
        if (wait > 0) await Future<void>.delayed(Duration(microseconds: wait));
      }
      stdout.writeln(
        jsonEncode({
          'complete': true,
          'frames': seconds * fps,
          'fps': fps,
          'elapsedSeconds': clock.elapsedMilliseconds / 1000,
          'elapsedMs': clock.elapsedMilliseconds,
          'expectedMs': seconds * 1000,
          'lateFrames': lateFrames,
          'maxLagMs': maxLagUs ~/ 1000,
          ...?dimensions,
        }),
      );
    });
  } finally {
    await driver.close();
  }
}
