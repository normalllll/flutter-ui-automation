import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'protocol.dart';

class HostResult {
  HostResult(this.code, this.output, this.error);
  final int code;
  final Uint8List output;
  final String error;
  String get text => utf8.decode(output, allowMalformed: true);
}

class Host {
  Host({Map<String, String>? environment})
    : environment = environment ?? Platform.environment;
  final Map<String, String> environment;
  final _children = <Process>{};

  /// Reap owned children even when they ignore SIGTERM. Keeping this bounded
  /// also lets an SSH stdio disconnect finish without stranding the service.
  Future<void> terminate(Process process) async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Cleanup runs from finally blocks; do not replace the original error.
        stderr.writeln('Process ${process.pid} survived SIGKILL for 5 s');
      }
    }
  }

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? directory,
    Map<String, String> extraEnvironment = const {},
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: directory,
      environment: {...environment, ...extraEnvironment},
      mode: ProcessStartMode.normal,
    );
    _children.add(process);
    unawaited(
      process.exitCode.then((_) {
        _children.remove(process);
      }),
    );
    return process;
  }

  Future<HostResult> run(
    String executable,
    List<String> arguments, {
    String? directory,
    Duration timeout = const Duration(seconds: 30),
    Cancellation? cancellation,
    bool check = true,
  }) async {
    cancellation?.check();
    final process = await start(executable, arguments, directory: directory);
    final bytes = BytesBuilder(copy: false);
    final errors = StringBuffer();
    final outputStream = process.stdout.listen(bytes.add);
    final errorStream = process.stderr
        .transform(utf8.decoder)
        .listen(errors.write);
    try {
      // A subprocess can exit while its descendants still hold stdout/stderr.
      // Apply cancellation and timeout to pipe draining as well as exitCode.
      final completed =
          Future.wait<Object?>([
            process.exitCode,
            outputStream.asFuture<void>(),
            errorStream.asFuture<void>(),
          ]).timeout(
            timeout,
            onTimeout: () => throw AutomationError(
              'process_timeout',
              '${p.basename(executable)} did not finish within ${timeout.inSeconds} s',
              {'stderr': errors.toString()},
            ),
          );
      final values = await (cancellation?.wait(completed) ?? completed);
      final code = values[0] as int;
      final result = HostResult(code, bytes.takeBytes(), errors.toString());
      if (check && code != 0) {
        throw AutomationError(
          'process_failed',
          '${p.basename(executable)} exited $code',
          {
            'stderr': result.error,
            'stdout': result.text.length > 4000
                ? result.text.substring(result.text.length - 4000)
                : result.text,
          },
        );
      }
      return result;
    } finally {
      await Future.wait([outputStream.cancel(), errorStream.cancel()]);
      if (_children.contains(process)) {
        await terminate(process);
      }
    }
  }

  Future<void> close() async {
    await Future.wait(_children.toList().map(terminate));
  }
}

class Toolchain {
  Toolchain(
    String root, {
    String? flutterRoot,
    String? artifacts,
    Map<String, String>? environment,
  }) : root = p.normalize(Directory(root).absolute.path),
       environment = environment ?? Platform.environment {
    this.flutterRoot =
        flutterRoot ?? this.environment['FLUTTER_ROOT'] ?? _findFlutter();
    this.artifacts = p.normalize(
      Directory(
        artifacts ?? p.join(root, 'artifacts', 'service'),
      ).absolute.path,
    );
  }
  final String root;
  final Map<String, String> environment;
  late final String flutterRoot;
  late final String artifacts;
  String get dart => p.join(
    flutterRoot,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  );
  List<String> flutter(List<String> args) => [
    p.join(flutterRoot, 'bin', 'cache', 'flutter_tools.snapshot'),
    ...args,
  ];
  String get fixture => p.join(root, 'examples', 'capture_lab');
  String program(String name, {String? variable}) {
    final explicit = variable == null ? null : environment[variable];
    if (explicit != null && explicit.isNotEmpty) {
      // An explicit override is a user choice; never substitute another tool.
      if (File(explicit).existsSync()) return File(explicit).absolute.path;
      throw AutomationError(
        'missing_prerequisite',
        '$variable points to a missing $name executable',
        {'environmentVariable': variable, 'path': explicit},
      );
    }
    final extensions = Platform.isWindows ? ['', '.exe', '.bat', '.cmd'] : [''];
    for (final directory in (environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      for (final extension in extensions) {
        final file = File(p.join(directory, '$name$extension'));
        if (file.existsSync()) return file.absolute.path;
      }
    }
    if (name == 'adb') {
      for (final key in ['ANDROID_SDK_ROOT', 'ANDROID_HOME']) {
        final sdk = environment[key];
        if (sdk != null) {
          final file = File(
            p.join(
              sdk,
              'platform-tools',
              Platform.isWindows ? 'adb.exe' : 'adb',
            ),
          );
          if (file.existsSync()) return file.absolute.path;
        }
      }
    }
    throw AutomationError('missing_prerequisite', '$name is missing', {
      'environmentVariable': variable,
    });
  }

  String get helper {
    final explicit = environment['WINDOW_CAPTURE'];
    final candidates = [
      ?explicit,
      p.join(
        root,
        'tools',
        'window_capture',
        'build',
        'Release',
        'window_capture.exe',
      ),
      p.join(
        fixture,
        'build',
        'windows',
        'x64',
        'runner',
        'Debug',
        'window_capture.exe',
      ),
      p.join(root, 'bin', 'window_capture.exe'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return File(candidate).absolute.path;
    }
    throw const AutomationError(
      'missing_prerequisite',
      'Build the Windows capture helper or set WINDOW_CAPTURE',
    );
  }

  String _findFlutter() {
    final executable = File(Platform.resolvedExecutable).absolute.path;
    final candidate = p.normalize(
      p.join(p.dirname(executable), '..', '..', '..', '..'),
    );
    if (File(
      p.join(candidate, 'bin', 'cache', 'flutter_tools.snapshot'),
    ).existsSync()) {
      return candidate;
    }
    for (final directory in (environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      final launcher = File(
        p.join(directory, Platform.isWindows ? 'flutter.bat' : 'flutter'),
      );
      if (launcher.existsSync()) {
        return p.dirname(p.dirname(launcher.resolveSymbolicLinksSync()));
      }
    }
    throw const AutomationError(
      'missing_prerequisite',
      'Set FLUTTER_ROOT to an installed Flutter SDK',
    );
  }
}

Future<void> writeJson(File file, Json value) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.$pid.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
  );
  for (var attempt = 0; ; attempt++) {
    try {
      await temporary.rename(file.path);
      return;
    } on FileSystemException {
      if (attempt >= 49) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
