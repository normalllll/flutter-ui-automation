import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/foreground.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

Json state({bool foreground = false, int activations = 0, int ticks = 10}) => {
  'pretendForeground': false,
  'rawLifecycle': foreground ? 'resumed' : 'inactive',
  'effectiveLifecycle': foreground ? 'resumed' : 'inactive',
  'rawViewFocus': foreground ? 'focused' : 'unfocused',
  'effectiveViewFocus': foreground ? 'focused' : 'unfocused',
  'foregroundTicks': ticks,
  'native': {
    'isForeground': foreground,
    'hasNativeFocus': foreground,
    'activationCount': activations,
  },
};
void main() {
  test('user inspection is not a failed background assertion', () {
    expect(
      backgroundActivity(
        state(),
        state(foreground: true, activations: 1, ticks: 15),
      )['status'],
      'not_assessed',
    );
  });
  test('inspection between observations is also not assessed', () {
    expect(backgroundActivity(state(), state(activations: 1))['passed'], null);
  });
  test('missing activation history cannot establish background coverage', () {
    final before = state();
    before.child('native').remove('activationCount');
    expect(backgroundActivity(before, state())['status'], 'not_assessed');
    expect(backgroundActivity(before, state())['passed'], null);
  });
  test(
    'real and framework state must agree before assessing background work',
    () {
      final after = state();
      after['effectiveLifecycle'] = 'resumed';
      expect(backgroundActivity(state(), after)['status'], 'not_assessed');
    },
  );
  test('counter defect fails only with an established background interval', () {
    expect(backgroundActivity(state(), state(ticks: 11))['status'], 'failed');
    expect(backgroundActivity(state(), state())['passed'], true);
  });
  test('restoration follows latest actual foreground and focus', () {
    expect(foregroundRestoration(state(foreground: true))['passed'], true);
    expect(
      foregroundRestoration({
        ...state(foreground: true),
        'effectiveViewFocus': 'unfocused',
      })['passed'],
      false,
    );
  });
}
