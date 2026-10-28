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
    CaptureRotation rotation = CaptureRotation.none,
    Cancellation? cancellation,
    int minimumSamples = 2,
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
        '${rotation.videoFilter}${crop}fps=2,scale=64:36',
        '-pix_fmt',
        'rgb24',
        '-f',
        'framemd5',
        '-',
      ], cancellation: cancellation)).text,
    );
    if (hashes.length < minimumSamples) {
      throw AutomationError(
        'invalid_video',
        'Recording has fewer than $minimumSamples decoded samples',
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
      'analysisRotationDegrees': rotation.degrees,
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
  ) => _pngRecording(
    path,
    seconds,
    fps,
    cancellation,
    (frame) =>
        appPng(session, frame, settle: false, cancellation: cancellation),
  );

  Future<Json> unixRecording(
    Session session,
    String path,
    int seconds,
    double fps,
    Json? probe,
    Cancellation cancellation,
  ) async {
    final native = (await session.state()).child('native');
    CaptureRotation? rotation;
    final result = await _pngRecording(path, seconds, fps, cancellation, (
      frame,
    ) async {
      final currentNative = (await session.state()).child('native');
      final bounds = native.child('viewBounds');
      final currentBounds = currentNative.child('viewBounds');
      if ([
            'x',
            'y',
            'width',
            'height',
          ].any((key) => bounds[key] != currentBounds[key]) ||
          native['interfaceOrientation'] !=
              currentNative['interfaceOrientation']) {
        throw const AutomationError(
          'geometry_changed',
          'Native viewport changed during recording',
        );
      }
      final capture = await session.unixTarget!.screenshot(
        frame,
        currentNative,
        probe: probe,
        cancellation: cancellation,
      );
      final current = CaptureRotation.fromDegrees(
        capture.integer('rotationToAppDegrees', fallback: 0),
      );
      if (rotation != null && rotation != current) {
        throw const AutomationError(
          'geometry_changed',
          'Display rotation changed during recording',
        );
      }
      rotation = current;
      return capture;
    });
    return {
      ...result,
      'source': session.platform.name,
      'clientX': native.child('viewBounds')['x'],
      'clientY': native.child('viewBounds')['y'],
      'presentationVerified': probe != null,
      'rotationToAppDegrees': rotation?.degrees ?? 0,
    };
  }

  Future<Json> _pngRecording(
    String path,
    int seconds,
    double fps,
    Cancellation cancellation,
    Future<Json> Function(String) capture,
  ) async {
    final frames = Directory('${p.withoutExtension(path)}.frames');
    await frames.create(recursive: true);
    // One untimed capture first: the first full-resolution app screenshot pays
    // one-off raster/shader preparation that is not representative of the
    // sampling rate. It is discarded and never enters the recording.
    final warmup = File(p.join(frames.path, 'warmup.png'));
    await capture(warmup.path);
    if (await warmup.exists()) await warmup.delete();
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
      await capture(p.join(frames.path, '${i.toString().padLeft(4, '0')}.png'));
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
      Object? pipeError;
      try {
        await pipe;
      } catch (e) {
        // An encoder that exits early breaks the pipe; report its stderr.
        pipeError = e;
      }
      final encoderCode = await cancellation.wait(
        encoder.exitCode.timeout(const Duration(minutes: 2)),
      );
      await stderrDone;
      if (captureCode != 0 || encoderCode != 0 || pipeError != null) {
        throw AutomationError(
          'record_failed',
          'Native capture=$captureCode encoder=$encoderCode',
          {'stderr': await errors, 'pipe': ?pipeError?.toString()},
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
      final recording = await device.command(
        [
          'shell',
          'screenrecord',
          '--display-id',
          source.text('displayId'),
          '--verbose',
          '--time-limit',
          '$seconds',
          remote,
        ],
        timeout: Duration(seconds: seconds + 25),
        cancellation: cancellation,
      );
      final recordedMs = clock.elapsedMilliseconds;
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
      // screenrecord emits frames only when the display changes, so a static
      // screen can produce a single frame and a short encoded duration.
      final metadata = await inspect(
        candidate,
        cancellation: cancellation,
        minimumSamples: 1,
      );
      final encodedSeconds = metadata.number('durationSeconds');
      final encodedTiming = (encodedSeconds - seconds).abs() <= seconds * .15;
      // A short file is accepted only when the device encoder demonstrably ran
      // for the requested interval; the basis is reported, never hidden.
      final staticTail =
          !encodedTiming &&
          encodedSeconds < seconds &&
          recordedMs >= seconds * 1000 * .85;
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
        'recordedMs': recordedMs,
        'timingBasis': encodedTiming
            ? 'encodedDuration'
            : staticTail
            ? 'screenrecordWallClock'
            : 'encodedDuration',
        'staticTail': staticTail,
        'timingPassed': encodedTiming || staticTail,
      };
    } finally {
      if (await File(candidate).exists()) {
        await File(candidate).rename('$stem.failed-device.mp4');
      }
      if (cancellation.cancelled) {
        // Killing the ADB client does not stop the device encoder.
        try {
          await device.command([
            'shell',
            'pkill',
            '-INT',
            '-f',
            remote,
          ], check: false);
        } catch (e) {
          stderr.writeln('Device recorder cleanup: $e');
        }
      }
      try {
        await device.command(['shell', 'rm', '-f', remote], check: false);
      } catch (e) {
        stderr.writeln('Device artifact cleanup: $e');
      }
    }
  }
}
