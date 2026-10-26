import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';
import 'pixels.dart';
import 'protocol.dart';
import 'sessions.dart';
import 'windows.dart';

List<String> frameHashes(String text) => text
    .split('\n')
    .where((s) => s.trim().isNotEmpty && !s.startsWith('#'))
    .map((s) => s.split(',').last.trim())
    .toList();

class Media {
  Media(this.host, this.tools);
  final Host host;
  final Toolchain tools;
  Future<HostResult> ffmpeg(List<String> args, {Cancellation? cancellation}) =>
      host.run(
        tools.program('ffmpeg', variable: 'FFMPEG'),
        ['-v', 'error', '-xerror', ...args],
        timeout: const Duration(minutes: 3),
        cancellation: cancellation,
      );
  Future<Json> inspect(
    String path, {
    Json? region,
    Cancellation? cancellation,
  }) async {
    final metadata = decodeObject(
      (await host.run(tools.program('ffprobe', variable: 'FFPROBE'), [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_streams',
        '-show_format',
        '-of',
        'json',
        path,
      ], cancellation: cancellation)).text,
    );
    final streams = metadata.items('streams');
    if (streams.isEmpty) {
      throw const AutomationError(
        'invalid_video',
        'Recording contains no video stream',
      );
    }
    final stream = object(streams.first);
    final crop = region == null
        ? ''
        : 'crop=${region.integer('width')}:${region.integer('height')}:${region.integer('x')}:${region.integer('y')},';
    final hashes = frameHashes(
      (await ffmpeg([
        '-i',
        path,
        '-vf',
        '${crop}fps=2,scale=64:36',
        '-pix_fmt',
        'rgb24',
        '-f',
        'framemd5',
        '-',
      ], cancellation: cancellation)).text,
    );
    if (hashes.length < 2) {
      throw const AutomationError(
        'invalid_video',
        'Recording has fewer than two decoded samples',
      );
    }
    return {
      'path': path,
      'width': stream['width'],
      'height': stream['height'],
      'codec': stream['codec_name'],
      'durationSeconds': double.parse(
        metadata.child('format').text('duration'),
      ),
      'decodedSamples': hashes.length,
      'uniqueSampleFrames': hashes.toSet().length,
      'decodable': true,
      'region': ?region,
    };
  }

  Future<Json> finalize(String preview, {Cancellation? cancellation}) async {
    final stem = p.withoutExtension(preview),
        master = '$stem.lossless.mkv',
        source = '$stem.source.framemd5';
    final original = await File(source).readAsString();
    final decoded = (await ffmpeg([
      '-i',
      master,
      '-c:v',
      'rawvideo',
      '-pix_fmt',
      'bgra',
      '-f',
      'framemd5',
      '-',
    ], cancellation: cancellation)).text;
    final expected = frameHashes(original), actual = frameHashes(decoded);
    String dimensions(String value) => value
        .split('\n')
        .where((line) => line.startsWith('#dimensions'))
        .join('\n');
    if (expected.isEmpty ||
        expected.length != actual.length ||
        List.generate(
          expected.length,
          (i) => expected[i] == actual[i],
        ).contains(false) ||
        dimensions(original) != dimensions(decoded)) {
      throw const AutomationError(
        'lossless_mismatch',
        'Decoded master differs from original BGRA frames',
      );
    }
    final partial = '$stem.partial.mp4';
    await ffmpeg([
      '-y',
      '-i',
      master,
      '-an',
      '-vf',
      'pad=ceil(iw/2)*2:ceil(ih/2)*2',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-crf',
      '18',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      partial,
    ], cancellation: cancellation);
    await File(partial).rename(preview);
    return {
      ...await inspect(preview, cancellation: cancellation),
      'masterPath': master,
      'sourceFrameHashes': source,
      'previewIsLossy': true,
      'masterCodec': 'ffv1',
      'masterPixelFormat': 'bgra',
      'losslessVerified': true,
      'verifiedFrames': actual.length,
    };
  }

  Future<Json> appPng(
    Session session,
    String path, {
    bool settle = true,
    Cancellation? cancellation,
  }) async {
    cancellation?.check();
    final shot = await session.connection.hook('appScreenshot', {
      'settle': settle,
    });
    final bytes = base64Decode(shot.text('png'));
    final size = pngSize(bytes);
    if (size.width != shot['width'] || size.height != shot['height']) {
      throw const AutomationError(
        'geometry_changed',
        'App screenshot dimensions disagree with metadata',
      );
    }
    final file = File(path).absolute;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return {
      ...shot..remove('png'),
      'path': file.path,
      'source': 'Flutter content',
      'lossless': true,
    };
  }

  Future<Json> appRecording(
    Session session,
    String path,
    int seconds,
    double fps,
    Cancellation cancellation,
  ) async {
    final frames = Directory('${p.withoutExtension(path)}.frames');
    await frames.create(recursive: true);
    final clock = Stopwatch()..start();
    final count = (seconds * fps).round();
    final samples = <int>[];
    for (var i = 0; i < count; i++) {
      cancellation.check();
      final target = Duration(microseconds: (i * 1000000 / fps).round());
      if (clock.elapsed < target) {
        await cancellation.wait(Future<void>.delayed(target - clock.elapsed));
      }
      samples.add(clock.elapsedMicroseconds);
      await appPng(
        session,
        p.join(frames.path, '${i.toString().padLeft(4, '0')}.png'),
        settle: false,
        cancellation: cancellation,
      );
    }
    final expected = Duration(seconds: seconds);
    if (clock.elapsed < expected) {
      await cancellation.wait(Future<void>.delayed(expected - clock.elapsed));
    }
    final elapsed = clock.elapsedMicroseconds;
    final stem = p.withoutExtension(path);
    await ffmpeg([
      '-y',
      '-framerate',
      '$fps',
      '-i',
      p.join(frames.path, '%04d.png'),
      '-map',
      '0:v:0',
      '-c:v',
      'ffv1',
      '-level',
      '3',
      '-pix_fmt',
      'bgra',
      '$stem.lossless.mkv',
      '-map',
      '0:v:0',
      '-c:v',
      'rawvideo',
      '-pix_fmt',
      'bgra',
      '-f',
      'framemd5',
      '$stem.source.framemd5',
    ], cancellation: cancellation);
    return {
      ...await finalize(path, cancellation: cancellation),
      'originalFramesDirectory': frames.path,
      'sampleMicroseconds': samples,
      'acquisitionMs': elapsed / 1000,
      'expectedMs': seconds * 1000,
      'timingPassed':
          (elapsed - seconds * 1000000).abs() <= seconds * 1000000 * .15,
      'requestedFps': fps,
    };
  }

  Future<Json> windowsRecording(
    Session session,
    String path,
    int seconds,
    int fps,
    String backend,
    Json? probe,
    Cancellation cancellation,
  ) async {
    final native = (await session.state()).child('native');
    final capture = WindowsCapture(host, tools);
    capture.api.requireWindow(native.integer('hwnd'), native.integer('pid'));
    final recorder = await host.start(tools.helper, [
      '--hwnd',
      '${native.integer('hwnd')}',
      '--backend',
      backend,
      '--stream',
      '--seconds',
      '$seconds',
      '--fps',
      '$fps',
      if (probe != null) ...capture.probeArguments(probe),
      '--diagnostic-png',
      '${p.withoutExtension(path)}.failed-native.png',
    ]);
    final ready = Completer<Json>(), messages = <Json>[];
    final log = File('${p.withoutExtension(path)}.native.log').openWrite();
    final stderrDone = recorder.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          log.writeln(line);
          try {
            final value = decodeObject(line);
            messages.add(value);
            if (!ready.isCompleted) {
              value['ready'] == true
                  ? ready.complete(value)
                  : ready.completeError(
                      AutomationError('capture_failed', line),
                    );
            }
          } catch (e) {
            if (!ready.isCompleted) ready.completeError(e);
          }
        })
        .asFuture<void>();
    Process? encoder;
    Future<void>? pipe;
    Future<String>? errors;
    Future<void>? stdoutDone;
    try {
      final metadata = await cancellation.wait(
        ready.future.timeout(const Duration(seconds: 16)),
      );
      final stem = p.withoutExtension(path);
      encoder = await host.start(tools.program('ffmpeg', variable: 'FFMPEG'), [
        '-v',
        'error',
        '-y',
        '-f',
        'rawvideo',
        '-pixel_format',
        'bgra',
        '-video_size',
        '${metadata['width']}x${metadata['height']}',
        '-framerate',
        '$fps',
        '-i',
        'pipe:0',
        '-an',
        '-map',
        '0:v:0',
        '-c:v',
        'ffv1',
        '-level',
        '3',
        '-pix_fmt',
        'bgra',
        '$stem.lossless.mkv',
        '-map',
        '0:v:0',
        '-c:v',
        'rawvideo',
        '-pix_fmt',
        'bgra',
        '-f',
        'framemd5',
        '$stem.source.framemd5',
      ]);
      errors = encoder.stderr.transform(utf8.decoder).join();
      stdoutDone = encoder.stdout.drain<void>();
      pipe = recorder.stdout.pipe(encoder.stdin);
      unawaited(pipe.catchError((Object _) {}));
      final captureCode = await cancellation.wait(
        recorder.exitCode.timeout(Duration(seconds: seconds * 2 + 20)),
      );
      await pipe;
      final encoderCode = await cancellation.wait(
        encoder.exitCode.timeout(const Duration(minutes: 2)),
      );
      await stderrDone;
      if (captureCode != 0 || encoderCode != 0) {
        throw AutomationError(
          'record_failed',
          'Native capture=$captureCode encoder=$encoderCode',
          {'stderr': await errors},
        );
      }
      capture.api.requireWindow(native.integer('hwnd'), native.integer('pid'));
      return {
        ...metadata,
        ...messages.last,
        ...await finalize(path, cancellation: cancellation),
        'presentationVerified': probe != null,
      };
    } finally {
      recorder.kill();
      encoder?.kill();
      await recorder.exitCode;
      await encoder?.exitCode;
      if (pipe != null) {
        try {
          await pipe;
        } catch (_) {}
      }
      await stderrDone;
      await stdoutDone;
      await errors;
      await log.close();
    }
  }

  Future<Json> androidRecording(
    Session session,
    String path,
    int seconds,
    Json? probe,
    Cancellation cancellation,
  ) async {
    final device = session.android!;
    final stem = p.withoutExtension(path);
    final source = await device.screenshot(
      '$stem.source-display.png',
      probe: probe,
      cancellation: cancellation,
    );
    final remote =
        '/data/local/tmp/flutter-capture-$pid-${DateTime.now().microsecondsSinceEpoch}.mp4';
    final candidate = '$stem.partial.mp4';
    final clock = Stopwatch()..start();
    try {
      // screenrecord has its own finite lifetime. Do not claim killing the ADB
      // transport has stopped or finalized the device encoder.
      final recording = await device.command([
        'shell',
        'screenrecord',
        '--display-id',
        source.text('displayId'),
        '--verbose',
        '--time-limit',
        '$seconds',
        remote,
      ], timeout: Duration(seconds: seconds + 25));
      await File(
        '$stem.screenrecord.log',
      ).writeAsString('${recording.text}\n${recording.error}');
      cancellation.check();
      await device.requireTarget(cancellation);
      await device.command(
        ['pull', remote, candidate],
        cancellation: cancellation,
        timeout: const Duration(seconds: 45),
      );
      if (await device.display() != source['displayId']) {
        throw const AutomationError(
          'display_changed',
          'Physical panel changed during recording',
        );
      }
      final metadata = await inspect(candidate, cancellation: cancellation);
      final fit = projection(
        source.integer('width'),
        source.integer('height'),
        metadata.integer('width'),
        metadata.integer('height'),
      );
      var matched = false;
      if (probe != null) {
        for (final offset in [0, .25, .5, 1]) {
          if (offset >= metadata.number('durationSeconds')) continue;
          await ffmpeg([
            '-y',
            '-ss',
            '$offset',
            '-i',
            candidate,
            '-frames:v',
            '1',
            '$stem.presentation.png',
          ], cancellation: cancellation);
          if (await markerInFile(
            '$stem.presentation.png',
            probe,
            displayProjection: fit,
          )) {
            matched = true;
            break;
          }
        }
      }
      if (probe != null && !matched) {
        throw const AutomationError(
          'stale_presentation',
          'Recording never presented requested marker',
        );
      }
      await File(candidate).rename(path);
      return {
        ...metadata,
        'path': path,
        'source': 'Android screenrecord',
        'sourceIsLossy': true,
        'losslessVerified': false,
        'presentationVerified': matched,
        'displayProjection': fit,
        'displayId': source['displayId'],
        'elapsedMs': clock.elapsedMilliseconds,
        'expectedMs': seconds * 1000,
        'timingPassed':
            (metadata.number('durationSeconds') - seconds).abs() <=
            seconds * .15,
      };
    } finally {
      if (await File(candidate).exists()) {
        await File(candidate).rename('$stem.failed-device.mp4');
      }
      try {
        await device.command(['shell', 'rm', '-f', remote], check: false);
      } catch (e) {
        stderr.writeln('Device artifact cleanup: $e');
      }
    }
  }
}
