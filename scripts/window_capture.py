"""Capture a selected Windows HWND without desktop input or window activation."""
from __future__ import annotations
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import queue
import subprocess
import sys
import threading

CREATE_NO_WINDOW = 0x08000000
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HELPER = ROOT / "examples/capture_lab/build/windows/x64/runner/Debug/window_capture.exe"


def program(name):
    binary = shutil.which(name)
    if not binary:
        raise RuntimeError(f"Missing {name}; add it to PATH")
    return binary


def validate_target(hwnd, process_id):
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.IsWindow.argtypes = [wintypes.HWND]
    user32.IsWindow.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    pid = wintypes.DWORD()
    if not user32.IsWindow(hwnd):
        raise ValueError("Invalid window handle")
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if pid.value != process_id:
        raise ValueError(f"HWND belongs to PID {pid.value}, expected {process_id}")


def probe_arguments(probe):
    if probe is None:
        return []
    rect, ratio = probe['rect'], probe['pixelRatio']
    return ['--probe', str(probe['token']),
            *(str(rect[key] * ratio) for key in ('x', 'y', 'width', 'height'))]



class CaptureError(RuntimeError):
    """A native capture failure, retaining structured diagnostics when available."""
    def __init__(self, message, diagnostics=None):
        self.diagnostics = diagnostics or {}
        detail = f"\nNative diagnostics: {json.dumps(diagnostics, ensure_ascii=False)}" if diagnostics else ''
        super().__init__(message + detail)


def parse_probe(values=None, json_path=None):
    """Build a probe from physical client pixels or an app hook's JSON response."""
    if values and json_path:
        raise ValueError("Use either --probe or --probe-json, not both")
    if values:
        token, x, y, width, height = values
        return {'token': int(token), 'pixelRatio': 1.0,
                'rect': {'x': float(x), 'y': float(y), 'width': float(width), 'height': float(height)}}
    if json_path:
        text = sys.stdin.read() if str(json_path) == '-' else Path(json_path).read_text(encoding='utf-8')
        data = json.loads(text)
        if not isinstance(data, dict) or not {'token', 'rect', 'pixelRatio'} <= data.keys():
            raise ValueError("Probe JSON requires token, rect {x, y, width, height} and pixelRatio")
        return data
    return None


def remove_stale(*paths):
    # A failed run must never leave an older image or video that looks current.
    for stale in paths:
        Path(stale).unlink(missing_ok=True)


def capture_png(path, *, hwnd, process_id, helper=DEFAULT_HELPER, backend="printwindow", probe=None):
    validate_target(hwnd, process_id)
    path = Path(path).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    diagnostic = path.with_name(path.stem + '.failed-native.png')
    partial = path.with_name(f'.{path.stem}.{os.getpid()}.partial.png')
    remove_stale(path, diagnostic, partial)
    diagnostic_args = ['--diagnostic-png', str(diagnostic)] if probe else []
    try:
        result = subprocess.run([str(helper), "--hwnd", str(hwnd), "--backend", backend, "--png", str(partial), *probe_arguments(probe), *diagnostic_args],
            capture_output=True, text=True, timeout=20, creationflags=CREATE_NO_WINDOW)
        if not result.returncode:
            partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)
    if result.returncode:
        try:
            details = json.loads(result.stderr)
        except (ValueError, TypeError):
            details = None
        if isinstance(details, dict) and details.get('error'):
            raise CaptureError(details.get('message', 'Native capture failed'), details)
        raise CaptureError(result.stderr.strip())
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Invalid capture metadata: stdout={result.stdout!r}, stderr={result.stderr!r}; path={path}") from error
    return {**metadata, "path": str(path), "hwnd": hwnd, "pid": process_id,
            "presentationVerified": probe is not None}


class Recording:
    def __init__(self, path: Path, *, hwnd: int, process_id: int, helper: Path, seconds=8, fps=12, backend="printwindow", probe=None):
        self.path, self.seconds, self.fps = path, seconds, fps
        self.master_path = path.with_suffix('.lossless.mkv')
        self.source_hashes = path.with_suffix('.source.framemd5')
        self.hwnd, self.process_id, self.helper = hwnd, process_id, helper
        self.backend = backend
        self.probe = probe
        self.capture = None
        self.encoder = None
        self.log = None
        self.ready = {}

    def start(self):
        validate_target(self.hwnd, self.process_id)
        remove_stale(self.path, self.master_path, self.source_hashes,
                     self.path.with_suffix('.failed-native.png'))
        hwnd = self.hwnd
        self.capture = subprocess.Popen([str(self.helper), "--hwnd", str(hwnd),
                                        "--backend", self.backend,
                                        "--stream", "--seconds", str(self.seconds),
                                        "--fps", str(self.fps), *probe_arguments(self.probe),
                                        *(['--diagnostic-png', str(self.path.with_suffix('.failed-native.png'))] if self.probe else [])], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, creationflags=CREATE_NO_WINDOW)
        first_line = queue.Queue(maxsize=1)
        def read_ready():
            first_line.put(self.capture.stderr.readline())
        threading.Thread(target=read_ready, daemon=True).start()
        try:
            first = first_line.get(timeout=15).decode("utf-8", errors="replace")
        except queue.Empty:
            self.capture.kill()
            self.capture.wait()
            raise TimeoutError('Native capture did not supply a first frame within 15 seconds')
        try:
            self.ready = json.loads(first)
            if isinstance(self.ready, dict) and self.ready.get('error'):
                self.capture.kill()
                self.capture.wait()
                raise CaptureError(self.ready.get('message', 'Native capture did not start'), self.ready)
            if not isinstance(self.ready, dict) or not self.ready.get("ready"):
                raise ValueError("Missing ready flag")
        except (ValueError, json.JSONDecodeError):
            self.capture.kill()
            self.capture.wait()
            raise RuntimeError(f"Native capture did not start: {first}")
        width, height = self.ready["width"], self.ready["height"]
        self.log = self.path.with_suffix(".ffmpeg.log").open("wb")
        try:
            self.encoder = subprocess.Popen([
                program("ffmpeg"), "-hide_banner", "-loglevel", "warning", "-y",
                "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", f"{width}x{height}",
                "-framerate", str(self.fps), "-i", "pipe:0", "-an",
                "-map", "0:v:0", "-c:v", "ffv1", "-level", "3", "-pix_fmt", "bgra", str(self.master_path),
                "-map", "0:v:0", "-c:v", "rawvideo", "-pix_fmt", "bgra", "-f", "framemd5", str(self.source_hashes)],
                stdin=self.capture.stdout, stdout=subprocess.DEVNULL, stderr=self.log,
                creationflags=CREATE_NO_WINDOW)
            self.capture.stdout.close()
        except Exception:
            self.capture.kill()
            self.capture.wait()
            self.log.close()
            raise
        self.ready["presentationVerified"] = self.probe is not None
        return self.ready

    def finish(self):
        try:
            # Encoder back-pressure can delay the helper; its lag is reported, not hidden.
            capture_code = self.capture.wait(timeout=self.seconds * 2 + 20)
            encoder_code = self.encoder.wait(timeout=60)
            notes = self.capture.stderr.read().decode("utf-8", errors="replace")
            if capture_code or encoder_code:
                raise RuntimeError(f"Recording failed: capture={capture_code}, FFmpeg={encoder_code}; {notes}")
            lines = notes.strip().splitlines()
            if not lines:
                raise RuntimeError("Native capture exited without completion metadata")
            complete = json.loads(lines[-1])
            from media import finalize_master
            return {**self.ready, **complete, **finalize_master(self.path, self.source_hashes)}
        finally:
            for process in (self.capture, self.encoder):
                if process and process.poll() is None:
                    process.kill()
                    process.wait()
            if self.log:
                self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["screenshot", "record"])
    parser.add_argument("--hwnd", type=int, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    parser.add_argument("--seconds", type=int, default=8)
    parser.add_argument("--fps", type=int, default=12)
    parser.add_argument("--backend", choices=["printwindow", "wgc"], default="printwindow")
    parser.add_argument("--probe", nargs=5, metavar=("TOKEN", "X", "Y", "WIDTH", "HEIGHT"),
        help="presentation marker in physical client pixels; the capture waits for this exact token")
    parser.add_argument("--probe-json", metavar="FILE",
        help="probe JSON from the app's test hook ({token, rect, pixelRatio}); '-' reads stdin")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 120 or not 1 <= args.fps <= 60:
        parser.error("seconds must be 1..120; fps must be 1..60")
    try:
        probe = parse_probe(args.probe, args.probe_json)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    if probe is None:
        print("WARNING: no presentation probe; the image may be blank or a stale earlier page. "
              "Inspect it before accepting it (presentationVerified=false).", file=sys.stderr)
    path = args.output.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    if args.action == "screenshot":
        result = capture_png(path, hwnd=args.hwnd, process_id=args.pid, helper=args.helper,
                             backend=args.backend, probe=probe)
    else:
        recording = Recording(path, hwnd=args.hwnd, process_id=args.pid,
            helper=args.helper, seconds=args.seconds, fps=args.fps, backend=args.backend, probe=probe)
        recording.start()
        result = recording.finish()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
