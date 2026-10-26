import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/windows.dart';

void main() {
  test('terminated kernel object is not a live process identity', () async {
    final directory = await Directory.systemTemp.createTemp(
      'automation-identity-',
    );
    final script = File('${directory.path}/child.dart');
    await script.writeAsString(
      "import 'dart:io'; Future<void> main()async{stdout.writeln('ready');await stdin.drain<void>();}",
    );
    final child = await Process.start(Platform.resolvedExecutable, [
      script.path,
    ]);
    final stdoutDone = child.stdout.drain<void>(),
        stderrDone = child.stderr.drain<void>();
    final kernel = DynamicLibrary.open('kernel32.dll');
    final open = kernel
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenProcess');
    final close = kernel
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    final retained = open(0x1000 | 0x100000, 0, child.pid);
    try {
      expect(retained, isNot(0));
      expect(WindowsApi().identity(child.pid), isNotNull);
      await child.stdin.close();
      await child.exitCode;
      expect(WindowsApi().identity(child.pid), isNull);
    } finally {
      if (retained != 0) close(retained);
      child.kill();
      await child.exitCode;
      await stdoutDone;
      await stderrDone;
      await script.delete();
      await directory.delete();
    }
  }, skip: !Platform.isWindows);
}
