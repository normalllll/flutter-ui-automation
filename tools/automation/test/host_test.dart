import 'dart:io';

import 'package:flutter_ui_automation/src/host.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/unix_process.dart';
import 'package:test/test.dart';

void main() {
  test(
    'timeout also bounds inherited output pipes after the direct child exits',
    () async {
      final directory = await Directory.systemTemp.createTemp('host-pipes-');
      final childPid = File('${directory.path}/pid');
      final host = Host();
      try {
        await expectLater(
          host.run('sh', [
            '-c',
            'sleep 30 & echo \$! > "\$1"; exit 0',
            'test',
            childPid.path,
          ], timeout: const Duration(milliseconds: 250)),
          throwsA(
            isA<AutomationError>().having(
              (e) => e.code,
              'code',
              'process_timeout',
            ),
          ),
        );
      } finally {
        if (await childPid.exists()) {
          final identity = UnixIdentity.read(
            int.parse((await childPid.readAsString()).trim()),
          );
          await identity?.terminate();
        }
        await host.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );
  test(
    'cancelled helper that ignores SIGTERM is reaped without masking cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'host-cancellation-',
      );
      final ready = File('${directory.path}/ready');
      final host = Host();
      final cancellation = Cancellation();
      final operation = host.run('sh', [
        '-c',
        'trap "" TERM; echo ready > "\$1"; while :; do sleep 1; done',
        'test',
        ready.path,
      ], cancellation: cancellation);
      // Attach the error handler before cancellation can finish the operation.
      final checked = expectLater(
        operation,
        throwsA(
          isA<AutomationError>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      try {
        await until(() => ready.exists(), (exists) => exists);
        cancellation.cancel();
        await checked;
        await host.close().timeout(const Duration(seconds: 2));
      } finally {
        cancellation.cancel();
        await host.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'owned Unix identity termination escalates a resistant process',
    () async {
      final host = Host();
      final child = await host.start('sh', [
        '-c',
        'trap "" TERM; echo ready; while :; do sleep 1; done',
      ]);
      final errors = child.stderr.drain<void>();
      try {
        await child.stdout.first;
        final original = UnixIdentity.read(child.pid)!;
        await original.terminate();
        await child.exitCode.timeout(const Duration(seconds: 2));
        expect(UnixIdentity.read(child.pid), isNull);
      } finally {
        await host.close();
        await errors;
      }
    },
    skip: Platform.isWindows,
  );
}
