import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

const usage =
    'dart run tool/driver.dart VM_URI '
    'state|tap KEY|text TEXT|scroll KEY DY|tap-at X Y|wait KEY|wait-absent KEY|'
    'settle|app-shot PATH|prepare-capture [HOLD_MS]|foreground on/off|'
    'text-emulation on/off|orientation portrait/landscape/restore|reveal KEY|key F6|tree  [--no-settle]';

/// Agent-facing CLI. Every operation stays within one application connection.
///
/// Interactions wait (bounded) for transient animations to settle before
/// returning, so the next screenshot does not capture a half-finished route
/// transition or ripple. Pass `--no-settle` while recording motion.
Future<void> main(List<String> arguments) async {
  stdout.encoding = utf8;
  stderr.encoding = utf8;
  final settle = !arguments.contains('--no-settle');
  final args = arguments.where((value) => value != '--no-settle').toList();
  if (args.length < 2) {
    stderr.writeln(usage);
    exitCode = 64;
    return;
  }
  final driver = await FlutterDriver.connect(
    dartVmServiceUrl: args[0],
    printCommunication: false,
    logCommunicationToFile: false,
  ).timeout(const Duration(seconds: 15));

  // The app state after an action, annotated with how the UI settled.
  Future<String> finish() async {
    Map settled = {'settled': null};
    if (settle) {
      settled = jsonDecode(await request(driver, 'settle')) as Map;
    } else {
      await request(driver, 'refresh');
    }
    final state = jsonDecode(await request(driver, 'state')) as Map;
    return jsonEncode({...state, ...settled});
  }

  try {
    await driver.runUnsynchronized(() async {
      final action = args[1];
      switch (action) {
        case 'unfocus':
          stdout.writeln(await request(driver, 'unfocus'));
        case 'state':
          stdout.writeln(await request(driver, 'state'));
        case 'settle':
          stdout.writeln(await request(driver, 'settle'));
        case 'prepare-capture':
          stdout.writeln(
            await request(driver, 'prepareCapture', {
              'holdMs': args.length > 2 ? int.parse(args[2]) : 12000,
              'settle': settle,
            }),
          );
        case 'center':
          final center = await driver.getCenter(find.byValueKey(args[2]));
          stdout.writeln(jsonEncode({'x': center.dx, 'y': center.dy}));
        case 'reveal':
          await driver.scrollIntoView(find.byValueKey(args[2]), alignment: 0.5);
          stdout.writeln(await finish());
        case 'orientation':
          stdout.writeln(
            await request(driver, 'orientation', {'value': args[2]}),
          );
        case 'tap-at':
          await request(driver, 'tapAt', {
            'x': double.parse(args[2]),
            'y': double.parse(args[3]),
          });
          stdout.writeln(await finish());
        case 'wait':
          await driver.waitFor(
            find.byValueKey(args[2]),
            timeout: const Duration(seconds: 8),
          );
          stdout.writeln(await finish());
        case 'wait-absent':
          await driver.waitForAbsent(
            find.byValueKey(args[2]),
            timeout: const Duration(seconds: 8),
          );
          stdout.writeln(await finish());
        case 'tap':
          await request(driver, 'refresh');
          await driver.tap(
            find.byValueKey(args[2]),
            timeout: const Duration(seconds: 8),
          );
          stdout.writeln(await finish());
        case 'text':
          await driver.enterText(args[2]);
          stdout.writeln(await finish());
        case 'scroll':
          await request(driver, 'refresh');
          await driver.scroll(
            find.byValueKey(args[2]),
            0,
            double.parse(args[3]),
            const Duration(milliseconds: 400),
          );
          stdout.writeln(await finish());
        case 'app-shot':
          final data = jsonDecode(
            await request(driver, 'appScreenshot', {'settle': settle}),
          ) as Map<String, Object?>;
          await File(args[2])
              .writeAsBytes(base64Decode(data.remove('png') as String));
          stdout.writeln(
            jsonEncode({...data, 'path': File(args[2]).absolute.path}),
          );
        case 'foreground':
          if (!['on', 'off'].contains(args[2])) {
            throw ArgumentError('Use on/off');
          }
          stdout.writeln(
            await request(driver, 'pretendForeground', {
              'enabled': args[2] == 'on',
            }),
          );
        case 'text-emulation':
          // Emulation replaces the platform text input channel, so a person
          // cannot type into this test build while it is on. Turn it on before
          // focusing a field that Driver will type into.
          if (!['on', 'off'].contains(args[2])) {
            throw ArgumentError('Use on/off');
          }
          await driver.setTextEntryEmulation(enabled: args[2] == 'on');
          stdout.writeln(jsonEncode({'textEntryEmulation': args[2] == 'on'}));
        case 'key':
          stdout.writeln(await request(driver, 'key', {'key': args[2]}));
        case 'tree':
          stdout.writeln((await driver.getRenderTree()).tree);
        default:
          throw ArgumentError('Unknown action: $action\n$usage');
      }
    });
  } finally {
    await driver.close();
  }
}

Future<String> request(
  FlutterDriver driver,
  String command, [
  Map<String, Object?> extra = const {},
]) => driver.requestData(
  jsonEncode({'command': command, ...extra}),
  timeout: const Duration(seconds: 15),
);
