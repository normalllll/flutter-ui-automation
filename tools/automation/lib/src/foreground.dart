import 'protocol.dart';

/// Observation does not identify who activated a window and does not invalidate
/// pixels. Only assertions whose own background precondition was lost are NA.
Json backgroundActivity(Json before, Json after) {
  final natives = [before.child('native'), after.child('native')];
  final states = [before, after];
  final background = List.generate(
    2,
    (i) =>
        !states[i].flag('pretendForeground') &&
        [
          'inactive',
          'hidden',
          'paused',
          'detached',
        ].contains(states[i]['rawLifecycle']) &&
        states[i]['effectiveLifecycle'] == states[i]['rawLifecycle'] &&
        natives[i]['isForeground'] == false &&
        natives[i]['hasNativeFocus'] == false,
  ).every((v) => v);
  if (!background ||
      natives.first['activationCount'] is! int ||
      natives.first['activationCount'] != natives.last['activationCount']) {
    return {
      'status': 'not_assessed',
      'passed': null,
      'reason':
          'Uninterrupted background interval was not established; captures remain independently valid',
    };
  }
  final passed = before['foregroundTicks'] == after['foregroundTicks'];
  return {
    'status': passed ? 'passed' : 'failed',
    'passed': passed,
    'before': before,
    'after': after,
  };
}

Json foregroundRestoration(Json state) => {
  'passed':
      !state.flag('pretendForeground') &&
      state['effectiveLifecycle'] == state['rawLifecycle'] &&
      state['effectiveViewFocus'] == (state['rawViewFocus'] ?? 'unfocused'),
  'rawLifecycle': state['rawLifecycle'],
  'effectiveLifecycle': state['effectiveLifecycle'],
  'rawViewFocus': state['rawViewFocus'],
  'effectiveViewFocus': state['effectiveViewFocus'],
};
