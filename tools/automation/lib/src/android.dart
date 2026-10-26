import 'dart:io';

import 'package:path/path.dart' as p;

import 'host.dart';
import 'pixels.dart';
import 'protocol.dart';

String physicalDisplay(String dump) {
  final section = RegExp(
    r'^\s*Display 0:[^\n]*\n(.*?)(?=^\s*Display \d+:|(?![\s\S]))',
    multiLine: true,
    dotAll: true,
  ).firstMatch(dump);
  final match = section == null
      ? null
      : RegExp(r'mPrimaryDisplayDevice=.*?\(local:(\d+)\)')
            .firstMatch(section[1]!);
  if (match == null) {
    throw const AutomationError(
      'display_unresolved',
      'Cannot resolve Android logical display 0 to a physical panel',
    );
  }
  return match[1]!;
}

class AndroidDevice {
  AndroidDevice(this.host, this.tools, this.serial, this.package) {
    if (serial.isEmpty ||
        serial.startsWith('-') ||
        RegExp(r'\s').hasMatch(serial)) {
      throw const AutomationError(
        'invalid_device',
        'Explicit device ID required',
      );
    }
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$')
        .hasMatch(package)) {
      throw const AutomationError(
        'invalid_package',
        'Valid Android package required',
      );
    }
  }
  final Host host;
  final Toolchain tools;
  final String serial, package;
  Future<HostResult> command(
    List<String> args, {
    Cancellation? cancellation,
    bool check = true,
    Duration timeout = const Duration(seconds: 30),
  }) => host.run(
    tools.program('adb', variable: 'ADB'),
    ['-s', serial, ...args],
    cancellation: cancellation,
    check: check,
    timeout: timeout,
  );
  Future<void> ready(Cancellation cancellation) async {
    if ((await command([
          'get-state',
        ], cancellation: cancellation)).text.trim() !=
        'device') {
      throw const AutomationError(
        'device_offline',
        'Selected Android device is offline or unauthorized',
      );
    }
  }

  Future<bool> resumed() async {
    final dump = (await command(['shell', 'dumpsys', 'activity', 'activities']))
        .text;
    return dump
        .split('\n')
        .any(
          (line) =>
              (line.contains('mResumedActivity') ||
                  line.contains('topResumedActivity')) &&
              line.contains('$package/'),
        );
  }

  Future<void> requireTarget(Cancellation cancellation) async {
    await ready(cancellation);
    if (!await resumed()) {
      throw AutomationError(
        'target_not_resumed',
        '$package is not resumed on $serial',
      );
    }
  }

  Future<String> display() async =>
      physicalDisplay((await command(['shell', 'dumpsys', 'display'])).text);
  Future<Json?> identity() async {
    final output = (await command([
      'shell',
      'pidof',
      package,
    ], check: false)).text.trim().split(RegExp(r'\s+'));
    if (output.length != 1 || int.tryParse(output.first) == null) return null;
    final pid = int.parse(output.single);
    final stat = await command([
      'shell',
      'cat',
      '/proc/$pid/stat',
    ], check: false);
    final fields = stat.text.split(')').last.trim().split(RegExp(r'\s+'));
    return {
      'pid': pid,
      'startTicks': stat.code == 0 && fields.length > 19 ? fields[19] : null,
    };
  }

  Future<void> validateInstance(Json native, Cancellation cancellation) async {
    await ready(cancellation);
    if (native['package'] != package) {
      throw const AutomationError(
        'wrong_instance',
        'VM package does not match selected device package',
      );
    }
    final token = (await command([
      'shell',
      'run-as',
      package,
      'cat',
      'files/capture-instance',
    ], cancellation: cancellation)).text.trim();
    if (token.isEmpty || token != native['instanceToken']) {
      throw const AutomationError(
        'wrong_instance',
        'VM identity does not match the selected device instance',
      );
    }
    final current = await identity();
    if (current?['pid'] != native['pid']) {
      throw const AutomationError(
        'wrong_instance',
        'VM PID does not match selected device',
      );
    }
  }

  Future<Json> screenshot(
    String output, {
    Json? probe,
    required Cancellation cancellation,
  }) async {
    final file = File(output).absolute;
    final candidate = File('${file.path}.partial.png');
    final diagnostic = File(
      '${p.withoutExtension(file.path)}.failed-device.png',
    );
    await file.parent.create(recursive: true);
    for (final stale in [file, candidate, diagnostic]) {
      if (await stale.exists()) await stale.delete();
    }
    final clock = Stopwatch()..start();
    try {
      while (true) {
        await requireTarget(cancellation);
        final selected = await display();
        final result = await command([
          'exec-out',
          'screencap',
          '-p',
          '-d',
          selected,
        ], cancellation: cancellation);
        final size = pngSize(result.output);
        await candidate.writeAsBytes(result.output);
        await requireTarget(cancellation);
        if (await display() != selected) {
          await candidate.rename(diagnostic.path);
          throw const AutomationError(
            'display_changed',
            'Physical panel changed during screenshot',
          );
        }
        if (probe == null || await markerInFile(candidate.path, probe)) {
          await candidate.rename(file.path);
          return {
            'path': file.path,
            'source': 'Android display',
            'deviceId': serial,
            'package': package,
            'width': size.width,
            'height': size.height,
            'displayId': selected,
            'presentationVerified': probe != null,
            'probeMatched': probe != null,
            'lossless': true,
            'elapsedMs': clock.elapsedMilliseconds,
          };
        }
        if (clock.elapsed > const Duration(seconds: 10)) {
          await candidate.rename(diagnostic.path);
          throw AutomationError(
            'stale_presentation',
            'Device did not present the requested marker',
            {'diagnostic': diagnostic.path},
          );
        }
      }
    } finally {
      if (await candidate.exists()) await candidate.delete();
    }
  }

  Future<void> back(Cancellation c) async {
    await requireTarget(c);
    await command([
      'shell',
      'input',
      'keyevent',
      'KEYCODE_BACK',
    ], cancellation: c);
  }

  Future<void> background(Cancellation c) async {
    await requireTarget(c);
    await command([
      'shell',
      'input',
      'keyevent',
      'KEYCODE_HOME',
    ], cancellation: c);
    await until(resumed, (v) => !v, cancellation: c);
  }

  Future<void> resume(Cancellation c) async {
    await ready(c);
    final component = (await command([
      'shell',
      'cmd',
      'package',
      'resolve-activity',
      '--brief',
      package,
    ], cancellation: c)).text.trim().split('\n').last.trim();
    if (!RegExp('^${RegExp.escape(package)}/[A-Za-z0-9_.\u0024]+\u0024')
        .hasMatch(component)) {
      throw const AutomationError(
        'invalid_component',
        'Unexpected launcher component',
      );
    }
    await command([
      'shell',
      'am',
      'start',
      '-W',
      '-n',
      component,
    ], cancellation: c);
    await until(resumed, (v) => v, cancellation: c);
  }
}
