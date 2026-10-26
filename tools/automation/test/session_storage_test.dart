import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';

void main() {
  test(
    'atomic session metadata waits for a Windows reader to release it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'automation-storage-',
      );
      final session = File(p.join(directory.path, 'session.json'));
      final original = <String, Object?>{'vmUri': 'ws://old/', 'owned': true};
      await writeJson(session, original);

      final kernel = DynamicLibrary.open('kernel32.dll');
      final open = kernel
          .lookupFunction<
            IntPtr Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Void>,
              Uint32,
              Uint32,
              IntPtr,
            ),
            int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
          >('CreateFileW');
      final close = kernel
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      final path = session.path.toNativeUtf16();
      // Share reads but not deletion, matching an external session-file reader.
      var handle = open(path, 0x80000000, 1, nullptr, 3, 0x80, 0);
      calloc.free(path);
      final observedBeforeRelease = Completer<Json>();
      Timer? release;
      try {
        expect(handle, isNot(-1));
        release = Timer(const Duration(milliseconds: 200), () {
          try {
            observedBeforeRelease.complete(
              decodeObject(session.readAsStringSync()),
            );
          } catch (error, stack) {
            observedBeforeRelease.completeError(error, stack);
          } finally {
            close(handle);
            handle = -1;
          }
        });
        final replacement = <String, Object?>{'vmUri': null, 'exitCode': 0};
        await writeJson(session, replacement);
        expect(
          handle,
          -1,
          reason:
              'The destination cannot be replaced while the reader holds it',
        );
        expect(await observedBeforeRelease.future, original);
        expect(decodeObject(await session.readAsString()), replacement);
        expect(
          (await directory.list().toList()).map(
            (file) => p.basename(file.path),
          ),
          ['session.json'],
        );
      } finally {
        release?.cancel();
        if (handle != -1) close(handle);
        final resolved = await directory.resolveSymbolicLinks();
        if (!p.isWithin(
          await Directory.systemTemp.resolveSymbolicLinks(),
          resolved,
        )) {
          throw StateError('Unexpected test cleanup path');
        }
        await Directory(resolved).delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
