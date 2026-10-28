import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/gateway.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/media.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/sessions.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:flutter_ui_automation/src/pixels.dart';
import 'package:test/test.dart';

class _Frames extends FlutterConnection {
  _Frames()
    : super(OfficialBridge((_) {}), 'ws://unused', HookProtocol.fixture);
  var screenshots = 0;

  @override
  Future<Json> hook(String command, [Json arguments = const {}]) async {
    expect(command, 'appScreenshot');
    expect(arguments['settle'], false);
    final pixels = image.Image(width: 65, height: 37);
    image.fill(
      pixels,
      color: image.ColorRgb8(20 + screenshots++ * 40, 80, 120),
    );
    return {
      'png': base64Encode(image.encodePng(pixels)),
      'width': pixels.width,
      'height': pixels.height,
    };
  }
}

Session _session(
  Directory directory, {
  FlutterConnection? connection,
  AndroidDevice? device,
}) => Session(
  id: 'media-test',
  platform: TargetPlatform.android,
  project: directory.path,
  entrypoint: 'test.dart',
  directory: directory,
  lease: Directory(p.join(directory.path, 'lease')),
  owned: false,
  connection: connection ?? _Frames(),
  android: device,
);

const _probe = <String, Object?>{
  'token': 42,
  'rect': {'x': 8, 'y': 8, 'width': 96, 'height': 48},
  'pixelRatio': 2,
  'native': {
    'viewBounds': {'x': 10, 'y': 20, 'width': 300, 'height': 150},
  },
};

Uint8List _markerPng() {
  final pixels = image.Image(width: 320, height: 180);
  image.fill(pixels, color: image.ColorRgb8(245, 247, 251));
  paintProbe(pixels, _probe);
  return image.encodePng(pixels);
}

class _RecordedDevice extends AndroidDevice {
  _RecordedDevice(Host host, Toolchain tools, this.video)
    : super(host, tools, 'explicit-device', 'test.capture.fixture');
  final File video;
  final calls = <List<String>>[];
  String panel = '34';
  Json? screenshotProbe;
  var targetChecks = 0;
  bool switchPanel = false;

  @override
  Future<Json> screenshot(
    String output, {
    Json? probe,
    required Cancellation cancellation,
  }) async {
    cancellation.check();
    screenshotProbe = probe;
    await File(output).writeAsBytes(_markerPng());
    return {'path': output, 'width': 320, 'height': 180, 'displayId': panel};
  }

  @override
  Future<void> requireTarget(Cancellation cancellation) async {
    cancellation.check();
    targetChecks++;
  }

  @override
  Future<String> display() async => panel;

  @override
  Future<HostResult> command(
    List<String> args, {
    Cancellation? cancellation,
    bool check = true,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    cancellation?.check();
    calls.add(args);
    if (args.first == 'pull') {
      await video.copy(args[2]);
      if (switchPanel) panel = '12';
    } else if (args.take(2).join(' ') != 'shell screenrecord' &&
        args.take(3).join(' ') != 'shell rm -f') {
      throw StateError('Unexpected ADB command: $args');
    }
    return HostResult(0, Uint8List(0), '');
  }
}

Matcher _error(String code) =>
    isA<AutomationError>().having((e) => e.code, 'code', code);

void main() {
  late Directory directory;
  late Host host;
  late Toolchain tools;
  late Media media;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('automation-media-');
    host = Host();
    tools = Toolchain(directory.path, flutterRoot: directory.path);
    media = Media(host, tools);
  });
  tearDown(() async {
    await host.close();
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
    'app recording retains source PNGs and verifies BGRA master at requested rate',
    () async {
      final frames = _Frames();
      final output = p.join(directory.path, 'app.mp4');
      final notes = await media.appRecording(
        _session(directory, connection: frames),
        output,
        2,
        2,
        Cancellation(),
      );
      // One discarded warm-up capture precedes the four timed samples.
      expect(frames.screenshots, 5);
      expect(notes['losslessVerified'], true);
      expect(notes['verifiedFrames'], 4);
      expect(notes['previewIsLossy'], true);
      expect(notes['durationSeconds'], closeTo(2, .05));
      expect(notes['sampleMicroseconds'], hasLength(4));
      expect(notes['width'], 66);
      expect(notes['height'], 38);
      final originals = await Directory(
        notes.text('originalFramesDirectory'),
      ).list().toList();
      expect(originals, hasLength(4));
      final first = image.decodePng(
        await File(
          p.join(notes.text('originalFramesDirectory'), '0000.png'),
        ).readAsBytes(),
      )!;
      expect((first.width, first.height), (65, 37));
      // The warm-up frame (r = 20) is not part of the recording.
      expect(first.getPixel(0, 0).r, 60);
      expect(
        (await media.inspect(notes.text('masterPath')))['durationSeconds'],
        closeTo(2, .05),
      );
      final hashFile = File(notes.text('sourceFrameHashes'));
      final hashes = await hashFile.readAsString();
      expect(frameHashes(hashes).toSet(), hasLength(4));
      await hashFile.writeAsString(
        hashes.replaceFirst(
          frameHashes(hashes).first,
          '00000000000000000000000000000000',
        ),
      );
      await expectLater(
        media.finalize(output),
        throwsA(_error('lossless_mismatch')),
      );
    },
  );

  Future<File> sourceVideo() async {
    final png = File(p.join(directory.path, 'source.png'));
    await png.writeAsBytes(_markerPng());
    final video = File(p.join(directory.path, 'source.mp4'));
    await media.ffmpeg([
      '-y',
      '-loop',
      '1',
      '-i',
      png.path,
      '-t',
      '2',
      '-vf',
      'scale=300:168,pad=300:300:0:66',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      video.path,
    ]);
    return video;
  }

  test(
    'Android recording uses screenshot panel, verifies projected marker and preserves original lossy video',
    () async {
      final original = await sourceVideo();
      final device = _RecordedDevice(host, tools, original);
      final output = p.join(directory.path, 'android.mp4');
      final notes = await media.androidRecording(
        _session(directory, device: device),
        output,
        2,
        _probe,
        Cancellation(),
      );
      expect(await File(output).readAsBytes(), await original.readAsBytes());
      expect(notes['presentationVerified'], true);
      expect(notes['sourceIsLossy'], true);
      expect(notes['losslessVerified'], false);
      expect(notes['timingPassed'], true);
      expect(notes['displayId'], '34');
      expect(notes['displayProjection'], {
        'x': 0,
        'y': 66,
        'width': 300,
        'height': 168,
        'sourceWidth': 320,
        'sourceHeight': 180,
      });
      expect(device.screenshotProbe, _probe);
      final record = device.calls.first;
      expect(record.take(4), ['shell', 'screenrecord', '--display-id', '34']);
      expect(record[record.indexOf('--time-limit') + 1], '2');
      expect(device.targetChecks, 1);
      expect(device.calls.last, ['shell', 'rm', '-f', record.last]);
    },
  );

  test(
    'Android stale marker and panel switch retain rejected original without successful video',
    () async {
      final original = await sourceVideo();
      for (final switchPanel in [false, true]) {
        final device = _RecordedDevice(host, tools, original)
          ..switchPanel = switchPanel;
        final output = p.join(directory.path, 'rejected-$switchPanel.mp4');
        await expectLater(
          media.androidRecording(
            _session(directory, device: device),
            output,
            2,
            {..._probe, 'token': 43},
            Cancellation(),
          ),
          throwsA(
            _error(switchPanel ? 'display_changed' : 'stale_presentation'),
          ),
        );
        expect(await File(output).exists(), false);
        expect(
          await File('${p.withoutExtension(output)}.partial.mp4').exists(),
          false,
        );
        expect(
          await File(
            '${p.withoutExtension(output)}.failed-device.mp4',
          ).readAsBytes(),
          await original.readAsBytes(),
        );
        expect(device.calls.last.take(3), ['shell', 'rm', '-f']);
      }
    },
  );
}
