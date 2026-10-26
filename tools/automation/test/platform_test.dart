import 'dart:convert';

import 'package:image/image.dart' as image;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/android.dart';
import 'package:flutter_ui_automation/src/flutter_connection.dart';
import 'package:flutter_ui_automation/src/media.dart';
import 'package:flutter_ui_automation/src/pixels.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

void main() {
  test(
    'logical display zero selects its panel, not the first physical display',
    () {
      const dump = '''Display Devices: external local:111
Logical Displays:
  Display 0:
    mPrimaryDisplayDevice=Internal Screen (local:222)
    mBaseDisplayInfo=stuff
  Display 1:
    mPrimaryDisplayDevice=Other (local:333)
''';
      expect(physicalDisplay(dump), '222');
      expect(
        physicalDisplay(dump.substring(0, dump.indexOf('  Display 1:'))),
        '222',
      );
      expect(
        () => physicalDisplay('Display 0:\n no local panel\n'),
        throwsA(isA<AutomationError>()),
      );
    },
  );
  test('finder uses standard recursive Driver serialization', () {
    final value = finder({
      'kind': 'descendant',
      'of': {'kind': 'key', 'value': 'root'},
      'matching': {'kind': 'text', 'value': '中文'},
    });
    expect(decodeObject(value.text('of'))['finderType'], 'ByValueKey');
    expect(decodeObject(value.text('matching'))['text'], '中文');
    expect(finder({'kind': 'key', 'value': 3})['keyValueType'], 'int');
    expect(() => finder({'kind': 'unknown'}), throwsA(isA<AutomationError>()));
  });
  test('marker requires exact token and maps native view bounds', () {
    const token = 0xabc123;
    final pixels = image.Image(width: 400, height: 100);
    final probe = <String, Object?>{
      'token': token,
      'rect': {'x': 0, 'y': 0, 'width': 320, 'height': 10},
      'pixelRatio': 1,
      'native': {
        'viewBounds': {'x': 20, 'y': 30, 'width': 320, 'height': 50},
      },
    };
    final word = (0xa << 28) | (token << 4) | 5;
    for (var i = 0; i < 32; i++) {
      final color = word >> (31 - i) & 1 == 1 ? [240, 180, 41] : [22, 50, 79];
      pixels.setPixelRgb(20 + i * 10 + 5, 35, color[0], color[1], color[2]);
    }
    expect(markerMatches(pixels, probe), true);
    expect(markerMatches(pixels, {...probe, 'token': token + 1}), false);
    expect(
      () => markerMatches(pixels, {
        ...probe,
        'native': {
          'viewBounds': {'x': 399, 'y': 0, 'width': 320, 'height': 50},
        },
      }),
      throwsA(isA<AutomationError>()),
    );
  });
  test('letterbox projection preserves device geometry', () {
    expect(projection(100, 200, 200, 200), {
      'x': 50,
      'y': 0,
      'width': 100,
      'height': 200,
      'sourceWidth': 100,
      'sourceHeight': 200,
    });
  });
  test('frame hash parsing compares actual frames', () {
    expect(
      frameHashes(
        '#dimensions 0: 10x10\n0, 0, 0, 1, 400, abc\n0, 1, 1, 1, 400, def\n',
      ),
      ['abc', 'def'],
    );
  });
  test(
    'cancellation interrupts waiting without touching external apps',
    () async {
      final c = Cancellation();
      final pending = c.wait(Future<void>.delayed(const Duration(seconds: 5)));
      c.cancel();
      await expectLater(pending, throwsA(isA<AutomationError>()));
    },
  );
  test('invalid PNG is rejected before evidence publication', () {
    expect(
      () => pngSize(utf8.encode('not a screenshot')),
      throwsA(isA<AutomationError>()),
    );
  });
}
