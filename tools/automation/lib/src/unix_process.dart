import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'protocol.dart';

/// A PID is only an address. The kernel birth time and executable identify its
/// instance, including after a retained session outlives the MCP process.
class UnixIdentity {
  const UnixIdentity(this.pid, this.birth, this.image);
  factory UnixIdentity.fromJson(Json value) => UnixIdentity(
    value.integer('pid'),
    value.text('birth'),
    value.text('image'),
  );
  final int pid;
  final String birth, image;
  Json toJson() => {'pid': pid, 'birth': birth, 'image': image};
  bool same(UnixIdentity? other) =>
      other != null &&
      pid == other.pid &&
      birth == other.birth &&
      image == other.image;

  static UnixIdentity? read(int pid) {
    if (pid <= 0) return null;
    try {
      if (Platform.isLinux) {
        final stat = File('/proc/$pid/stat').readAsStringSync();
        final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
        if (fields[0] == 'Z' || fields[0] == 'X') return null;
        final boot = File(
          '/proc/sys/kernel/random/boot_id',
        ).readAsStringSync().trim();
        return UnixIdentity(
          pid,
          '$boot:${fields[19]}',
          // Rebuilding the binary under a live process makes the kernel
          // append " (deleted)"; that is the same instance, not a new one.
          imageWithoutDeletedSuffix(Link('/proc/$pid/exe').targetSync()),
        );
      }
      if (Platform.isMacOS) {
        final lib = DynamicLibrary.open('/usr/lib/libproc.dylib');
        final info = lib
            .lookupFunction<
              Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
              int Function(int, int, int, Pointer<Void>, int)
            >('proc_pidinfo');
        final path = lib
            .lookupFunction<
              Int32 Function(Int32, Pointer<Void>, Uint32),
              int Function(int, Pointer<Void>, int)
            >('proc_pidpath');
        final buffer = calloc<Uint64>(17), name = calloc<Uint8>(4096);
        try {
          if (info(pid, 3, 0, buffer.cast(), 136) != 136 ||
              path(pid, name.cast(), 4096) <= 0) {
            return null;
          }
          // PROC_PIDTBSDINFO's final two uint64s are start seconds/useconds.
          return UnixIdentity(
            pid,
            '${buffer[15]}:${buffer[16]}',
            name.cast<Utf8>().toDartString(),
          );
        } finally {
          calloc.free(buffer);
          calloc.free(name);
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  void requireCurrent() {
    if (!same(read(pid))) {
      throw const AutomationError(
        'target_changed',
        'Native process instance changed',
      );
    }
  }

  Future<void> terminate() async {
    final current = read(pid);
    // A missing process or a different birth time means this instance already
    // exited (possibly with its PID reused); never signal the replacement.
    if (current == null || current.birth != birth) return;
    requireCurrent();
    Process.killPid(pid, ProcessSignal.sigterm);
    try {
      await until(
        () async => !same(read(pid)),
        (gone) => gone,
        timeout: const Duration(seconds: 5),
      );
    } on AutomationError catch (error) {
      if (error.code != 'timeout') rethrow;
      // Recheck the birth identity immediately before escalation. Never signal
      // a replacement that happened to acquire the original process's PID.
      if (!same(read(pid))) return;
      Process.killPid(pid, ProcessSignal.sigkill);
      await until(() async => !same(read(pid)), (gone) => gone);
    }
  }
}

String imageWithoutDeletedSuffix(String image) => image.endsWith(' (deleted)')
    ? image.substring(0, image.length - ' (deleted)'.length)
    : image;
