import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:image/image.dart' as image;

import 'host.dart';
import 'pixels.dart';
import 'protocol.dart';
import 'target_platform.dart';
import 'unix_process.dart';

int? simulatorAppPid(String listing, String bundleId) {
  for (final line in listing.split('\n')) {
    final columns = line.trim().split(RegExp(r'\s+'));
    if (columns.length < 3) continue;
    final pid = int.tryParse(columns[0]);
    if (pid != null &&
        pid > 0 &&
        columns[2].startsWith('UIKitApplication:$bundleId[')) {
      return pid;
    }
  }
  return null;
}

/// Native-host operations. iOS currently selects an explicit CoreSimulator;
/// physical devices require a separate, verified capture/identity backend.
class UnixTarget {
  UnixTarget(
    this.host,
    this.tools,
    this.platform, {
    this.deviceId,
    this.bundleId,
  });
  final Host host;
  final Toolchain tools;
  final TargetPlatform platform;
  final String? deviceId, bundleId;
  UnixIdentity? expectedIdentity;

  /// CoreSimulator processes share the Mac PID namespace. A valid PID alone
  /// does not establish that a VM endpoint belongs to the selected simulator.
  Future<void> validateInstance({
    Json? native,
    Cancellation? cancellation,
  }) async {
    final identity = expectedIdentity;
    if (identity == null) {
      throw const AutomationError('target_unavailable', 'No native identity');
    }
    identity.requireCurrent();
    if (native != null &&
        (native['pid'] != identity.pid ||
            native['platform'] != platform.name ||
            platform == TargetPlatform.ios && native['bundleId'] != bundleId)) {
      throw const AutomationError('target_changed', 'App identity differs');
    }
    if (platform == TargetPlatform.ios) {
      final listing = await simctl([
        'spawn',
        deviceId!,
        'launchctl',
        'list',
      ], cancellation: cancellation);
      if (simulatorAppPid(listing.text, bundleId!) != identity.pid) {
        throw const AutomationError(
          'target_changed',
          'App process does not belong to the selected simulator and bundle',
        );
      }
      identity.requireCurrent();
    }
  }

  Future<HostResult> simctl(
    List<String> args, {
    Cancellation? cancellation,
    bool check = true,
  }) => host.run(
    'xcrun',
    ['simctl', ...args],
    cancellation: cancellation,
    check: check,
  );

  Future<void> ready(Cancellation cancellation) async {
    platform.requireHost();
    if (platform == TargetPlatform.ios) {
      if (bundleId == null ||
          !RegExp(
            r'^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$',
          ).hasMatch(bundleId!)) {
        throw const AutomationError(
          'invalid_package',
          'An explicit valid iOS bundle identifier is required',
        );
      }
      if (deviceId == null ||
          !RegExp(r'^[A-Fa-f0-9-]{36}$').hasMatch(deviceId!)) {
        throw const AutomationError(
          'invalid_device',
          'Select an explicit iOS Simulator UDID',
        );
      }
      final devices = decodeObject(
        (await simctl([
          'list',
          'devices',
          '-j',
        ], cancellation: cancellation)).text,
      );
      final selected = devices
          .child('devices')
          .values
          .whereType<List<Object?>>()
          .expand((items) => items)
          .map(object)
          .where((device) => device['udid'] == deviceId)
          .firstOrNull;
      if (selected == null ||
          selected['state'] != 'Booted' ||
          selected['isAvailable'] != true) {
        throw const AutomationError(
          'device_unavailable',
          'Selected simulator must already be booted and available',
        );
      }
    }
    if (platform == TargetPlatform.linux &&
        (host.environment['DISPLAY'] ?? '').isEmpty &&
        (host.environment['WAYLAND_DISPLAY'] ?? '').isEmpty) {
      throw const AutomationError(
        'missing_display',
        'Linux needs an explicit display session; native capture requires X11, preferably a dedicated Xvfb',
      );
    }
  }

  Future<void> requireStopped(Cancellation cancellation) async {
    if (platform != TargetPlatform.ios) return;
    final listing = await simctl([
      'spawn',
      deviceId!,
      'launchctl',
      'list',
    ], cancellation: cancellation);
    if (simulatorAppPid(listing.text, bundleId!) != null) {
      throw const AutomationError(
        'app_already_running',
        'Simulator app already runs; attach explicitly rather than replacing it',
      );
    }
  }

  String get captureHelper {
    final key = platform == TargetPlatform.linux
        ? 'LINUX_CAPTURE'
        : 'MACOS_CAPTURE';
    final explicit = host.environment[key];
    final helper =
        explicit ??
        (platform == TargetPlatform.linux
            ? p.join(tools.root, 'tools', 'linux_capture', 'build', 'capture')
            : p.join(
                tools.root,
                'tools',
                'macos_capture',
                'build',
                'FlutterUICapture.app',
                'Contents',
                'MacOS',
                'capture',
              ));
    if (!File(helper).existsSync()) {
      throw AutomationError('missing_prerequisite', 'Build $key helper', {
        'path': helper,
      });
    }
    return helper;
  }

  Future<Json> screenshot(
    String output,
    Json native, {
    Json? probe,
    required Cancellation cancellation,
  }) async {
    final identity = expectedIdentity;
    if (identity == null || identity.pid != native.integer('pid')) {
      throw const AutomationError(
        'target_unavailable',
        'Target has no verified process identity',
      );
    }
    await validateInstance(native: native, cancellation: cancellation);
    if (platform == TargetPlatform.linux && native['displayServer'] != 'x11') {
      throw const AutomationError(
        'unsupported_capture_backend',
        'Linux native capture currently requires X11; Wayland Portal is not implemented',
      );
    }
    final file = File(output).absolute;
    await file.parent.create(recursive: true);
    final partial = '${file.path}.partial.png';
    final rejected = '${p.withoutExtension(file.path)}.failed-native.png';
    // A previous run's diagnostic must not sit beside a new success.
    for (final stale in [file.path, partial, rejected]) {
      if (await File(stale).exists()) await File(stale).delete();
    }
    final watch = Stopwatch()..start();
    Json metadata = {};
    try {
      do {
        cancellation.check();
        identity.requireCurrent();
        if (platform == TargetPlatform.ios) {
          await simctl([
            'io',
            deviceId!,
            'screenshot',
            '--type=png',
            partial,
          ], cancellation: cancellation);
          metadata = {'source': 'iOS Simulator display', 'deviceId': deviceId};
        } else {
          final result = await host.run(
            captureHelper,
            [
              '--pid',
              '${identity.pid}',
              '--window',
              '${native.integer('windowId')}',
              '--output',
              partial,
            ],
            cancellation: cancellation,
            check: false,
          );
          if (result.code != 0) {
            throw AutomationError(
              result.error.contains('screen_recording_permission_required')
                  ? 'screen_recording_permission_required'
                  : 'capture_failed',
              result.error,
            );
          }
          metadata = decodeObject(result.text);
        }
        final bytes = await File(partial).readAsBytes();
        final size = pngSize(bytes);
        final bounds = native.child('viewBounds');
        final sideways =
            platform == TargetPlatform.ios &&
            bounds.number('width') > size.width + 1 &&
            bounds.number('width') <= size.height + 1;
        var rotation =
            platform == TargetPlatform.ios &&
                native['interfaceOrientation'] == 2
            ? CaptureRotation.upsideDown
            : CaptureRotation.none;
        if (sideways && probe == null) {
          rotation = switch (native['interfaceOrientation']) {
            3 => CaptureRotation.counterclockwise,
            4 => CaptureRotation.clockwise,
            _ => throw const AutomationError(
              'orientation_unresolved',
              'Simulator display orientation requires a presentation probe or interface orientation metadata',
            ),
          };
        }
        var presented = probe == null;
        if (probe != null) {
          try {
            if (platform == TargetPlatform.ios) {
              final pixels = image.decodePng(bytes);
              if (pixels == null) {
                throw const AutomationError(
                  'invalid_png',
                  'Cannot decode display PNG',
                );
              }
              // CoreSimulator's raw framebuffer can stay portrait while UIKit
              // rotates its scene. Keep the PNG unchanged and resolve only the
              // coordinate transform using the exact presentation token.
              for (final candidate in [
                CaptureRotation.none,
                CaptureRotation.clockwise,
                CaptureRotation.counterclockwise,
                CaptureRotation.upsideDown,
              ]) {
                try {
                  if (markerMatches(pixels, probe, rotation: candidate)) {
                    rotation = candidate;
                    presented = true;
                    break;
                  }
                } on AutomationError catch (error) {
                  if (error.code != 'geometry_changed') rethrow;
                }
              }
            } else {
              presented = await markerInFile(partial, probe);
            }
          } on AutomationError catch (error) {
            // UIKit/GTK geometry may reach the app before the compositor's next
            // display frame. Reject and retain this candidate, then keep waiting
            // for the exact marker; a layout change is not a successful capture.
            if (error.code != 'geometry_changed') rethrow;
          }
        }
        if (presented) {
          await validateInstance(native: native, cancellation: cancellation);
          await File(partial).rename(file.path);
          return {
            ...metadata,
            'path': file.path,
            'width': size.width,
            'height': size.height,
            'rotationToAppDegrees': rotation.degrees,
            'clientX': native.child('viewBounds')['x'],
            'clientY': native.child('viewBounds')['y'],
            'lossless': true,
            'presentationVerified': probe != null,
          };
        }
        await File(partial).copy(rejected);
        await cancellation.wait(
          Future<void>.delayed(const Duration(milliseconds: 80)),
        );
      } while (watch.elapsed < const Duration(seconds: 10));
      throw AutomationError(
        'stale_presentation',
        'Expected presentation token was not observed',
        {'diagnosticPath': rejected},
      );
    } finally {
      if (await File(partial).exists()) {
        if (!await file.exists()) await File(partial).copy(rejected);
        await File(partial).delete();
      }
    }
  }

  Future<void> lifecycle(String action, Cancellation cancellation) async {
    if (platform != TargetPlatform.ios || bundleId == null) {
      throw const AutomationError(
        'unsupported_action',
        'Native lifecycle actions require an iOS Simulator target',
      );
    }
    if (action == 'back') {
      throw const AutomationError(
        'unsupported_action',
        'iOS has no Android back key',
      );
    }
    await validateInstance(cancellation: cancellation);
    // simctl launch does not activate the host Simulator/Device Hub window.
    if (action == 'resume') {
      await simctl([
        'launch',
        deviceId!,
        bundleId!,
      ], cancellation: cancellation);
    } else {
      if (action != 'background') {
        throw const AutomationError(
          'unsupported_action',
          'Unknown lifecycle action',
        );
      }
      // Launching the simulator's Settings app backgrounds the fixture without
      // terminating it, faking lifecycle events, or injecting host input.
      await simctl([
        'launch',
        deviceId!,
        'com.apple.Preferences',
      ], cancellation: cancellation);
    }
  }
}
