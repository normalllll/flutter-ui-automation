import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_ui_automation/src/protocol.dart';
import 'package:flutter_ui_automation/src/unix_process.dart';

void main() {
  test(
    'kernel process identity detects exit and rejects forged birth or image',
    () async {
      final current = UnixIdentity.read(pid);
      expect(current, isNotNull);
      expect(current!.same(UnixIdentity.fromJson(current.toJson())), true);
      expect(
        () => UnixIdentity(
          pid,
          '${current.birth}-different',
          current.image,
        ).requireCurrent(),
        throwsA(isA<AutomationError>()),
      );
      expect(
        () => UnixIdentity(
          pid,
          current.birth,
          '${current.image}-different',
        ).requireCurrent(),
        throwsA(isA<AutomationError>()),
      );
      final child = await Process.start('sh', ['-c', 'echo ready; read value']);
      final errors = child.stderr.drain<void>();
      try {
        await child.stdout.transform(utf8.decoder).first;
        final original = UnixIdentity.read(child.pid);
        expect(original, isNotNull);
        original!.requireCurrent();
        await child.stdin.close();
        await child.exitCode;
        expect(original.same(UnixIdentity.read(child.pid)), false);
      } finally {
        child.kill();
        await child.exitCode;
        await errors;
      }
    },
    skip: Platform.isWindows,
  );
}
