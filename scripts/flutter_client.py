"""Flutter control and app-content capture, independent of the target platform."""
from pathlib import Path
import time

from runtime import APP, dart, last_json, run, timing_ok


class FlutterClient:
    def __init__(self, vm_uri, app=APP):
        if not vm_uri or not vm_uri.startswith(('ws://', 'wss://', 'http://', 'https://')):
            raise ValueError('A reachable VM Service URI is required')
        self.vm_uri, self.app = vm_uri, Path(app)

    def drive(self, action, *arguments):
        result = run([dart(), 'run', 'tool/driver.dart', self.vm_uri, action, *arguments],
                     cwd=self.app, timeout=40)
        return result.stdout if action == 'tree' else last_json(result.stdout)

    def screenshot(self, path):
        path = Path(path).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        return self.drive('app-shot', str(path))

    def prepare_capture(self, hold_ms=12000, settle=True):
        return self.drive('prepare-capture', str(hold_ms), *([] if settle else ['--no-settle']))

    def record(self, path, seconds=8, fps=5):
        if not 1 <= seconds <= 30:
            raise ValueError('App recording duration must be 1..30 seconds')
        if not 1 <= fps <= 15:
            raise ValueError('App recording rate must be 1..15 fps')
        path = Path(path).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        frames = path.with_name(f'{path.stem}-frames-{time.time_ns()}')
        frames.mkdir()
        result = run([dart(), 'run', 'tool/record_app.dart', self.vm_uri,
                      frames, str(seconds), str(fps)], cwd=self.app, timeout=seconds * 3 + 40)
        notes = last_json(result.stdout)
        from media import encode_png_sequence
        return {**notes, **encode_png_sequence(path, frames, fps=fps),
                'source': 'Flutter RepaintBoundary',
                'timingVerified': timing_ok(notes, seconds * 1000, seconds * fps)}
