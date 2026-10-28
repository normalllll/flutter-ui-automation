import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'host.dart';
import 'protocol.dart';

class WindowsIdentity {
  const WindowsIdentity(this.pid, this.created, this.image);
  final int pid;
  final int created;
  final String image;
  Json toJson() => {'pid': pid, 'created': created, 'image': image};
  bool same(WindowsIdentity? other) =>
      other != null &&
      pid == other.pid &&
      created == other.created &&
      p.normalize(image).toLowerCase() ==
          p.normalize(other.image).toLowerCase();
}

class WindowsApi {
  late final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _user = DynamicLibrary.open('user32.dll');
  WindowsIdentity? identity(int pid) {
    if (!Platform.isWindows) {
      throw const AutomationError(
        'unsupported_platform',
        'Windows host required',
      );
    }
    final open = _kernel
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenProcess');
    final close = _kernel
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    final times = _kernel
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          ),
          int Function(
            int,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          )
        >('GetProcessTimes');
    final path = _kernel
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>),
          int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)
        >('QueryFullProcessImageNameW');
    final wait = _kernel
        .lookupFunction<
          Uint32 Function(IntPtr, Uint32),
          int Function(int, int)
        >('WaitForSingleObject');
    final handle = open(0x1000 | 0x100000, 0, pid);
    if (handle == 0) return null;
    final fileTimes = calloc<Uint64>(4);
    final buffer = calloc<Uint16>(32768).cast<Utf16>();
    final size = calloc<Uint32>()..value = 32768;
    try {
      // A terminated process can remain queryable while a debugger/parent holds
      // its kernel object. Creation time alone does not establish liveness.
      if (wait(handle, 0) != 258) return null;
      if (times(
                handle,
                fileTimes,
                fileTimes + 1,
                fileTimes + 2,
                fileTimes + 3,
              ) ==
              0 ||
          path(handle, 0, buffer, size) == 0) {
        return null;
      }
      return WindowsIdentity(
        pid,
        fileTimes.value,
        buffer.toDartString(length: size.value),
      );
    } finally {
      close(handle);
      calloc.free(fileTimes);
      calloc.free(buffer);
      calloc.free(size);
    }
  }

  /// Terminates exactly [expected]: the identity is rechecked through the same
  /// handle that is signalled, so a reused PID is never terminated.
  bool terminate(WindowsIdentity expected) {
    final open = _kernel
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenProcess');
    final close = _kernel
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    final times = _kernel
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          ),
          int Function(
            int,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
            Pointer<Uint64>,
          )
        >('GetProcessTimes');
    final kill = _kernel
        .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
          'TerminateProcess',
        );
    // PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION
    final handle = open(0x0001 | 0x1000, 0, expected.pid);
    if (handle == 0) return false;
    final fileTimes = calloc<Uint64>(4);
    try {
      if (times(
                handle,
                fileTimes,
                fileTimes + 1,
                fileTimes + 2,
                fileTimes + 3,
              ) ==
              0 ||
          fileTimes.value != expected.created) {
        return false;
      }
      return kill(handle, 1) != 0;
    } finally {
      close(handle);
      calloc.free(fileTimes);
    }
  }

  void requireWindow(int hwnd, int pid) {
    if (!Platform.isWindows) {
      throw const AutomationError(
        'unsupported_platform',
        'Windows host required',
      );
    }
    final read = _user
        .lookupFunction<
          Uint32 Function(IntPtr, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)
        >('GetWindowThreadProcessId');
    final actual = calloc<Uint32>();
    try {
      if (read(hwnd, actual) == 0 || actual.value != pid) {
        throw const AutomationError(
          'target_changed',
          'HWND no longer belongs to the expected process',
        );
      }
    } finally {
      calloc.free(actual);
    }
  }

  void closeWindow(int hwnd, int pid) {
    requireWindow(hwnd, pid);
    final post = _user
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
          int Function(int, int, int, int)
        >('PostMessageW');
    if (post(hwnd, 0x0010, 0, 0) == 0) {
      throw const AutomationError('close_failed', 'WM_CLOSE failed');
    }
  }
}

class WindowsCapture {
  WindowsCapture(this.host, this.tools);
  final Host host;
  final Toolchain tools;
  final api = WindowsApi();
  Future<Json> environment(Json native, Cancellation cancellation) async {
    api.requireWindow(native.integer('hwnd'), native.integer('pid'));
    return decodeObject(
      (await host.run(tools.helper, [
        '--hwnd',
        '${native.integer('hwnd')}',
        '--environment',
      ], cancellation: cancellation)).text,
    );
  }

  List<String> probeArguments(Json probe) {
    final rect = probe.child('rect');
    final ratio = probe.number('pixelRatio');
    return [
      '--probe',
      '${probe.integer('token')}',
      for (final field in ['x', 'y', 'width', 'height'])
        '${rect.number(field) * ratio}',
    ];
  }

  Future<Json> screenshot(
    String output,
    Json native, {
    Json? probe,
    String backend = 'wgc',
    required Cancellation cancellation,
  }) async {
    final file = File(output).absolute;
    final partial = File('${file.path}.partial.png');
    final diagnostic = File(
      '${p.withoutExtension(file.path)}.failed-native.png',
    );
    await file.parent.create(recursive: true);
    for (final stale in [file, partial, diagnostic]) {
      if (await stale.exists()) await stale.delete();
    }
    try {
      api.requireWindow(native.integer('hwnd'), native.integer('pid'));
      final result = await host.run(
        tools.helper,
        [
          '--hwnd',
          '${native.integer('hwnd')}',
          '--backend',
          backend,
          '--png',
          partial.path,
          if (probe != null) ...probeArguments(probe),
          '--diagnostic-png',
          diagnostic.path,
        ],
        cancellation: cancellation,
        check: false,
      );
      if (result.code != 0) {
        // The helper reports an unpresented probe as structured JSON on
        // stderr; keep that classification and its diagnostics.
        final report = helperFailure(result.error);
        if (report?['error'] == 'capture_not_presented') {
          throw AutomationError(
            'stale_presentation',
            'Native marker was not presented before the helper timeout',
            report!,
          );
        }
        throw AutomationError(
          'capture_failed',
          '${p.basename(tools.helper)} exited ${result.code}',
          {'stderr': result.error, 'helper': ?report},
        );
      }
      api.requireWindow(native.integer('hwnd'), native.integer('pid'));
      final metadata = decodeObject(result.text);
      if (probe != null && metadata['probeMatched'] != true) {
        throw const AutomationError(
          'stale_presentation',
          'Native marker did not match',
        );
      }
      await partial.rename(file.path);
      return {
        ...metadata,
        'path': file.path,
        'pid': native['pid'],
        'hwnd': native['hwnd'],
        'presentationVerified': probe != null,
        'lossless': true,
      };
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}

/// The last JSON object a capture helper wrote to stderr, if any.
Json? helperFailure(String stderrText) {
  for (final line in stderrText.trim().split('\n').reversed) {
    final text = line.trim();
    if (!text.startsWith('{')) continue;
    try {
      return decodeObject(text);
    } on Object {
      continue;
    }
  }
  return null;
}
