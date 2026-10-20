"""Own-window Flutter verification. Standard library only; no desktop input."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import threading
import time
import traceback

from host_process import _kernel32, process_identity, same_process
from window_capture import CaptureError, Recording, capture_png

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "examples" / "capture_lab"
ARTIFACTS = ROOT / "artifacts"
SESSION = ARTIFACTS / "session.json"
APP_INSTANCE = ARTIFACTS / "app-instance.json"
STOP = ARTIFACTS / "stop.request"
APP_EXECUTABLE = APP / "build/windows/x64/runner/Debug/flutter_capture_lab.exe"
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
# Native capture steps can fail for environmental reasons (display off, no
# presented frame). They are recorded as native evidence, not app failures.
NATIVE_ERRORS = (CaptureError, RuntimeError, TimeoutError, OSError, ValueError,
                 subprocess.TimeoutExpired)


def _retry(action, attempts=100, delay=0.02):
    # Windows refuses to replace or open a file another process holds without
    # FILE_SHARE_DELETE. Session readers and the supervisor poll concurrently.
    for _ in range(attempts - 1):
        try:
            return action()
        except PermissionError:
            time.sleep(delay)
    return action()


def save_session(data):
    temporary = SESSION.with_suffix(f'.{os.getpid()}.tmp')
    temporary.write_text(json.dumps(data, indent=2), encoding='utf-8')
    _retry(lambda: temporary.replace(SESSION))


def read_session():
    return _retry(lambda: json.loads(SESSION.read_text(encoding="utf-8")))








def supervisor_alive(data):
    return same_process(data.get("supervisor"))


def program(name):
    from runtime import program as resolve
    return resolve(name)


def dart():
    from runtime import dart as resolve
    return resolve()


def run(args, *, cwd=ROOT, timeout=60, check=True):
    from runtime import run as execute
    return execute(args, cwd=cwd, timeout=timeout, check=check)


def session():
    if not SESSION.is_file():
        raise RuntimeError("No session. Run scripts/lab.py start first")
    data = read_session()
    if not data.get("vmUri"):
        raise RuntimeError(f"Session is not ready: {data}")
    return data


def drive(action, *args):
    from flutter_client import FlutterClient
    return FlutterClient(session()['vmUri'], APP).drive(action, *args)


def serve():
    ARTIFACTS.mkdir(exist_ok=True)
    STOP.unlink(missing_ok=True)
    # No console window, shell UI, foreground activation or system input.
    renderer = os.environ.get("CAPTURE_LAB_RENDERER", "default")
    placement = os.environ.get('CAPTURE_LAB_PLACEMENT', 'auto')
    render_flags = {"software": ["--enable-software-rendering", "--no-enable-impeller"],
                    "skia": ["--no-enable-impeller"], "default": []}[renderer]
    process = subprocess.Popen([program("flutter"), "run", "--machine", "-d", "windows",
                                "-t", "lib/driver_main.dart", "--no-pub", *render_flags],
                               cwd=APP, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                               errors="replace", creationflags=CREATE_NO_WINDOW)
    data = {"supervisorPid": os.getpid(), "supervisor": process_identity(os.getpid()),
            "flutterPid": process.pid, "vmUri": None, "renderer": renderer, 'placement': placement}

    def publish():
        # A failed write must not kill the supervisor: that would orphan the app
        # and leave a session that can never acknowledge stop.
        try:
            save_session(data)
        except OSError as error:
            print(f"Session write failed: {error}", file=sys.stderr, flush=True)

    publish()

    def watch_stop():
        while process.poll() is None:
            if STOP.exists():
                try:
                    if data.get("appId"):
                        process.stdin.write(json.dumps([{"id": 1, "method": "app.stop",
                                             "params": {"appId": data["appId"]}}]) + "\n")
                        process.stdin.flush()
                    else:
                        process.terminate()
                except (OSError, ValueError):
                    pass
                return
            time.sleep(0.2)
    threading.Thread(target=watch_stop, daemon=True).start()
    try:
        with (ARTIFACTS / "flutter-run.log").open("w", encoding="utf-8") as log:
            for line in process.stdout:
                log.write(line)
                log.flush()
                try:
                    events = json.loads(line)
                    for event in events if isinstance(events, list) else []:
                        params = event.get("params", {})
                        if event.get("event") == "app.start":
                            data["appId"] = params["appId"]
                            publish()
                        elif event.get("event") == "app.debugPort":
                            # baseUri is the app's filesystem root, not the VM service.
                            data["vmUri"] = params["wsUri"]
                            publish()
                except (json.JSONDecodeError, TypeError, KeyError, AttributeError):
                    pass
        code = process.wait()
    finally:
        data.update({"vmUri": None, "exitCode": process.poll()})
        publish()
    return code


def record_app_instance():
    # The supervisor owns session.json; app identity lives beside it so the
    # two writers never overwrite each other's fields.
    state = drive("state")
    native = state.get("native", {})
    identity = process_identity(native.get("pid"))
    if identity:
        APP_INSTANCE.write_text(json.dumps({**identity, "hwnd": native.get("hwnd")}, indent=2),
                                encoding="utf-8")
    return state


def recover_stale(data):
    """The supervisor is gone. Close only the recorded fixture instance, then clear the session."""
    result = {"stopped": True, "staleSession": True, "closedApp": False}
    recorded = None
    if APP_INSTANCE.is_file():
        try:
            recorded = json.loads(APP_INSTANCE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            recorded = None
    if recorded and same_process(recorded) and \
            Path(recorded["image"]).resolve() == APP_EXECUTABLE.resolve():
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        # WM_CLOSE to the fixture's own HWND: no activation or global input.
        user32.PostMessageW(recorded.get("hwnd"), 0x0010, 0, 0)
        for _ in range(50):
            if not same_process(recorded):
                break
            time.sleep(0.2)
        if same_process(recorded):
            kernel32 = _kernel32()
            kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
            handle = kernel32.OpenProcess(0x0001, False, recorded["pid"])  # PROCESS_TERMINATE
            if handle:
                kernel32.TerminateProcess(handle, 1)
                kernel32.CloseHandle(handle)
            result["terminatedApp"] = True
        result["closedApp"] = not same_process(recorded)
    APP_INSTANCE.unlink(missing_ok=True)
    STOP.unlink(missing_ok=True)
    save_session({**data, "vmUri": None, "starting": False, "staleRecovered": result})
    return result


def start():
    ARTIFACTS.mkdir(exist_ok=True)
    if SESSION.exists():
        previous = read_session()
        if previous.get("vmUri") or previous.get("starting"):
            if not supervisor_alive(previous):
                recover_stale(previous)
            elif previous.get("vmUri"):
                try:
                    return record_app_instance()
                except (RuntimeError, subprocess.TimeoutExpired):
                    raise RuntimeError("Existing session is not responding; run stop and inspect flutter-run.log")
    APP_INSTANCE.unlink(missing_ok=True)
    save_session({"vmUri": None, "starting": True})
    with (ARTIFACTS / "supervisor.log").open("w", encoding="utf-8") as log:
        supervisor = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "serve"],
                         cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                         creationflags=CREATE_NO_WINDOW)
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        current = read_session()
        if current.get("vmUri"):
            return record_app_instance()
        if "exitCode" in current:
            raise RuntimeError("Flutter failed to launch; inspect artifacts/flutter-run.log")
        if supervisor.poll() is not None:
            save_session({"vmUri": None, "exitCode": None, "supervisorExitCode": supervisor.returncode})
            raise RuntimeError("Launch supervisor exited; inspect artifacts/supervisor.log")
        time.sleep(0.5)
    raise TimeoutError("App launch timed out; inspect artifacts/flutter-run.log")


def stop():
    if not SESSION.exists():
        return {"stopped": True}
    current = read_session()
    if not current.get("vmUri") and not current.get("starting"):
        return {"stopped": True, "exitCode": current.get("exitCode")}
    if not supervisor_alive(current):
        return recover_stale(current)
    STOP.touch()
    for _ in range(100):
        time.sleep(0.2)
        current = read_session()
        if not current.get("vmUri") and "exitCode" in current:
            APP_INSTANCE.unlink(missing_ok=True)
            return {"stopped": True, "exitCode": current.get("exitCode")}
        if not supervisor_alive(current):
            return recover_stale(current)
    raise TimeoutError("App did not acknowledge stop; no unrelated process was terminated")


def capture_binary():
    path = APP / "build/windows/x64/runner/Debug/window_capture.exe"
    if not path.is_file():
        raise RuntimeError("Capture helper missing; build the example Windows app first")
    return path


def prepare_capture(hold_ms=12000, settle=True):
    # The marker is shown only for this capture window (helper waits at most 10 s).
    return drive("prepare-capture", str(hold_ms), *([] if settle else ["--no-settle"]))


def window_shot(path: Path, probe=None):
    probe = probe or prepare_capture()
    native = probe["native"]
    return {**capture_png(path, hwnd=native["hwnd"], process_id=native["pid"],
                       helper=capture_binary(), backend="wgc", probe=probe), 'probe': probe}


def new_recording(path: Path, seconds=8):
    probe = prepare_capture(seconds * 1000 + 15000, settle=False)
    native = probe["native"]
    return Recording(path, hwnd=native["hwnd"], process_id=native["pid"],
                     helper=capture_binary(), seconds=seconds, backend="wgc", probe=probe)


def timing_ok(notes, expected_ms, frames):
    # Frame count alone fixes the container duration; check wall-clock pacing.
    elapsed = notes.get("elapsedMs", -1)
    return (abs(elapsed - expected_ms) <= max(500, expected_ms * 0.05)
            and notes.get("lateFrames", frames) <= max(1, frames * 0.05))


def record_app(path, seconds=8):
    from flutter_client import FlutterClient
    return FlutterClient(session()['vmUri'], APP).record(path, seconds)


def verify():
    from verify_windows import verify as verify_impl
    return verify_impl()



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "start", "stop", "state", "drive", "window-shot", "record", "app-record", "verify", "verify-cold", "serve"])
    parser.add_argument("arguments", nargs="*")
    args, extra = parser.parse_known_args()
    if extra and (args.action != 'drive' or extra != ['--no-settle']):
        parser.error(f'Unrecognized arguments: {extra}')
    args.arguments += extra
    if os.name != "nt":
        parser.error("Windows is required")
    if args.action == "serve": return serve()
    if args.action == "start":
        for value in args.arguments:
            if value in ('software', 'skia', 'default'):
                os.environ['CAPTURE_LAB_RENDERER'] = value
            elif value in ('auto', 'primary', 'secondary'):
                os.environ['CAPTURE_LAB_PLACEMENT'] = value
            else:
                parser.error('start accepts renderer default|software|skia and placement auto|primary|secondary')
    if args.action == "build":
        result = run([program("flutter"), "build", "windows", "--debug", "-t", "lib/driver_main.dart"], cwd=APP, timeout=300)
        print(result.stdout)
        return
    if args.action == "verify":
        result = verify()
        if not result['passed']: raise SystemExit(1)
        return result
    if args.action == "verify-cold":
        from verify_scenarios import verify_cold
        return verify_cold(int(args.arguments[0]) if args.arguments else 3)
    if args.action == "start": result = start()
    elif args.action == "stop": result = stop()
    elif args.action == "state": result = drive("state")
    elif args.action == "drive": result = drive(*args.arguments)
    elif args.action == "window-shot":
        path = Path(args.arguments[0]).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        result = window_shot(path)
    elif args.action == "app-record":
        path = Path(args.arguments[0]).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        result = record_app(path, seconds=int(args.arguments[1]) if len(args.arguments) > 1 else 8)
    elif args.action == "record":
        path = Path(args.arguments[0]).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        recording = new_recording(path, seconds=int(args.arguments[1]) if len(args.arguments) > 1 else 8)
        recording.start()
        result = recording.finish()
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
