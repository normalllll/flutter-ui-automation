import 'dart:io';

import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/unix_process.dart';
import 'package:flutter_ui_automation/src/windows.dart';
import 'package:test/test.dart';

Matcher code(String value) =>
    isA<AutomationError>().having((error) => error.code, 'code', value);

void main() {
  test('an explicit tool override that does not exist is reported', () {
    final tools = Toolchain(
      Directory.systemTemp.path,
      flutterRoot: Directory.systemTemp.path,
      environment: {
        'FFMPEG': '${Directory.systemTemp.path}/missing-ffmpeg-binary',
        'PATH': File(Platform.resolvedExecutable).parent.path,
      },
    );
    expect(
      () => tools.program('ffmpeg', variable: 'FFMPEG'),
      throwsA(code('missing_prerequisite')),
    );
  });

  test('an explicit tool override that exists is used', () {
    final tools = Toolchain(
      Directory.systemTemp.path,
      flutterRoot: Directory.systemTemp.path,
      environment: {'FFMPEG': Platform.resolvedExecutable},
    );
    expect(
      tools.program('ffmpeg', variable: 'FFMPEG'),
      File(Platform.resolvedExecutable).absolute.path,
    );
  });

  test('process timeouts carry an automation error code', () async {
    final host = Host();
    try {
      await expectLater(
        Platform.isWindows
            ? host.run('cmd', [
                '/c',
                'ping -n 6 127.0.0.1 >nul',
              ], timeout: const Duration(milliseconds: 300))
            : host.run('sleep', [
                '5',
              ], timeout: const Duration(milliseconds: 300)),
        throwsA(code('process_timeout')),
      );
    } finally {
      await host.close();
    }
  });

  test('helper stderr JSON is classified from its last object', () {
    final report = helperFailure(
      'WGC warning\n{"error":"capture_not_presented","probeMatched":false}\n',
    );
    expect(report?['error'], 'capture_not_presented');
    expect(helperFailure('plain failure text'), isNull);
    expect(helperFailure('{truncated'), isNull);
  });

  test('a rebuilt Linux binary keeps its process identity', () {
    expect(imageWithoutDeletedSuffix('/app/fixture (deleted)'), '/app/fixture');
    expect(imageWithoutDeletedSuffix('/app/fixture'), '/app/fixture');
  });

  test(
    'terminating an exited or recycled Unix instance never signals',
    () async {
      final self = UnixIdentity.read(pid)!;
      // Same PID, different birth: the original instance is gone.
      await UnixIdentity(pid, '${self.birth}-old', self.image).terminate();
      expect(UnixIdentity.read(pid)?.same(self), true);
    },
    skip: Platform.isWindows,
  );

  test('Windows terminate refuses a recycled PID', () {
    final self = WindowsApi().identity(pid)!;
    expect(
      WindowsApi().terminate(
        WindowsIdentity(pid, self.created + 1, self.image),
      ),
      false,
    );
    expect(self.same(WindowsApi().identity(pid)), true);
  }, skip: !Platform.isWindows);
}
