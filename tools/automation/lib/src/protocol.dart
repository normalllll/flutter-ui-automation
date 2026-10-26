import 'dart:async';
import 'dart:convert';

typedef Json = Map<String, Object?>;

Json object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw AutomationError('invalid_data', 'Expected a JSON object');
  }
  return value;
}

extension Fields on Json {
  String text(String key, {String? fallback}) => switch (this[key]) {
    final String value => value,
    null when fallback != null => fallback,
    _ => throw AutomationError('invalid_argument', '$key must be a string'),
  };
  int integer(String key, {int? fallback}) => switch (this[key]) {
    final int value => value,
    null when fallback != null => fallback,
    _ => throw AutomationError('invalid_argument', '$key must be an integer'),
  };
  double number(String key, {double? fallback}) => switch (this[key]) {
    final num value when value.isFinite => value.toDouble(),
    null when fallback != null => fallback,
    _ => throw AutomationError(
      'invalid_argument',
      '$key must be a finite number',
    ),
  };
  bool flag(String key, {bool fallback = false}) => switch (this[key]) {
    final bool value => value,
    null => fallback,
    _ => throw AutomationError('invalid_argument', '$key must be a boolean'),
  };
  Json child(String key) => object(this[key]);
  List<Object?> items(String key) => switch (this[key]) {
    final List<Object?> values => values,
    _ => throw AutomationError('invalid_argument', '$key must be an array'),
  };
}

class AutomationError implements Exception {
  const AutomationError(this.code, this.message, [this.detail = const {}]);
  final String code;
  final String message;
  final Json detail;
  Json toJson() => {'code': code, 'message': message, ...detail};
  @override
  String toString() => '$code: $message';
}

class Cancellation {
  final _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  void check() {
    if (cancelled) {
      throw const AutomationError('cancelled', 'Operation cancelled');
    }
  }

  Future<T> wait<T>(Future<T> value) => Future.any([
    value,
    whenCancelled.then<T>(
      (_) => throw const AutomationError('cancelled', 'Operation cancelled'),
    ),
  ]);
}

Future<T> until<T>(
  Future<T> Function() observe,
  bool Function(T) accepts, {
  Duration timeout = const Duration(seconds: 10),
  Cancellation? cancellation,
  String description = 'target state',
}) async {
  final clock = Stopwatch()..start();
  while (true) {
    cancellation?.check();
    final value = await observe();
    if (accepts(value)) return value;
    if (clock.elapsed >= timeout) {
      throw AutomationError('timeout', 'Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

Json decodeObject(String text) => object(jsonDecode(text));
Json toolResult(Json value, {List<Json> content = const []}) => {
  'content': [
    {'type': 'text', 'text': jsonEncode(value)},
    ...content,
  ],
  'structuredContent': value,
};
Json toolFailure(Object error) => {
  'isError': true,
  ...toolResult(
    error is AutomationError
        ? error.toJson()
        : {'code': 'operation_failed', 'message': '$error'},
  ),
};
