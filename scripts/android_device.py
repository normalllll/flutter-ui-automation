"""ADB operations scoped to one explicit Android device and application."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time
import uuid

from runtime import NO_WINDOW, program, run, wait_until


def adb_binary():
    explicit = os.environ.get('ADB')
    if explicit:
        if not Path(explicit).is_file():
            raise RuntimeError('ADB must point to an existing executable')
        return explicit
    found = shutil.which('adb')
    if found:
        return found
    for name in ('ANDROID_SDK_ROOT', 'ANDROID_HOME'):
        root = os.environ.get(name)
        if root:
            path = Path(root) / 'platform-tools' / ('adb.exe' if os.name == 'nt' else 'adb')
            if path.is_file():
                return str(path)
    raise RuntimeError('ADB missing; set ADB, ANDROID_SDK_ROOT or ANDROID_HOME')


def devices():
    result = run([adb_binary(), 'devices', '-l'])
    return [{'id': parts[0], 'state': parts[1], 'details': ' '.join(parts[2:])}
            for line in result.stdout.splitlines()[1:]
            if len(parts := line.split()) >= 2 and not line.startswith('*')]


def remove_stale(*paths):
    for stale in paths:
        Path(stale).unlink(missing_ok=True)


def png_size(data):
    if len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        raise ValueError('ADB did not return a PNG')
    width, height = struct.unpack('>II', data[16:24])
    if not width or not height or width * height > 64000000:
        raise ValueError('Invalid screenshot dimensions')
    return width, height


def display_projection(source_width, source_height, video_width, video_height):
    """Android screenrecord's centered, aspect-preserving display projection."""
    if min(source_width, source_height, video_width, video_height) <= 0:
        raise ValueError('Display and video dimensions must be positive')
    if video_height > int(video_width * source_height / source_width):
        width, height = video_width, int(video_width * source_height / source_width)
    else:
        width, height = int(video_height * source_width / source_height), video_height
    return {'x': (video_width - width) // 2, 'y': (video_height - height) // 2,
            'width': width, 'height': height,
            'sourceWidth': source_width, 'sourceHeight': source_height}


def project_region(region, projection):
    sx = projection['width'] / projection['sourceWidth']
    sy = projection['height'] / projection['sourceHeight']
    return {'x': round(projection['x'] + region['x'] * sx),
            'y': round(projection['y'] + region['y'] * sy),
            'width': max(1, round(region['width'] * sx)),
            'height': max(1, round(region['height'] * sy))}


def marker_geometry(probe, width, height, projection=None):
    """Map Flutter logical view coordinates to device display pixels."""
    rect, ratio, native = probe['rect'], probe['pixelRatio'], probe['native']
    bounds = native['viewBounds']
    if not rect or ratio <= 0:
        raise ValueError('Missing marker geometry')
    source_width = projection['sourceWidth'] if projection else width
    source_height = projection['sourceHeight'] if projection else height
    if bounds['x'] < 0 or bounds['y'] < 0 or bounds['x'] + bounds['width'] > source_width + 1 or bounds['y'] + bounds['height'] > source_height + 1:
        raise ValueError('View geometry changed or is outside the captured display')
    points = [(bounds['x'] + (rect['x'] + (i + .5) * rect['width'] / 32) * ratio,
               bounds['y'] + (rect['y'] + rect['height'] / 2) * ratio) for i in range(32)]
    if projection:
        points = [(projection['x'] + x * projection['width'] / source_width,
                   projection['y'] + y * projection['height'] / source_height) for x, y in points]
    return [(round(x), round(y)) for x, y in points]


def marker_matches(path, probe, projection=None):
    data = Path(path).read_bytes()
    width, height = png_size(data)
    points = marker_geometry(probe, width, height, projection)
    result = subprocess.run([program('ffmpeg'), '-v', 'error', '-i', str(path),
                             '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
                            capture_output=True, timeout=20, creationflags=NO_WINDOW)
    if result.returncode or len(result.stdout) != width * height * 3:
        raise RuntimeError('Could not decode the original device PNG')
    word = (0xa << 28) | (int(probe['token']) << 4) | 5
    for i, (x, y) in enumerate(points):
        if not 0 <= x < width or not 0 <= y < height:
            return False
        actual = result.stdout[(y * width + x) * 3:(y * width + x) * 3 + 3]
        expected = (240, 180, 41) if word >> (31 - i) & 1 else (22, 50, 79)
        if max(abs(a - b) for a, b in zip(actual, expected)) > 35:
            return False
    return True


class AndroidDevice:
    def __init__(self, serial, package):
        if not serial or serial.startswith('-') or any(c.isspace() for c in serial):
            raise ValueError('An explicit ADB device ID is required')
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', package):
            raise ValueError('Invalid Android package name')
        self.serial, self.package = serial, package

    def command(self, *arguments, timeout=30, check=True):
        return run([adb_binary(), '-s', self.serial, *arguments], timeout=timeout, check=check)

    def ready(self):
        if self.command('get-state').stdout.strip() != 'device':
            raise RuntimeError(f'Device {self.serial} is not online/authorized')

    def resumed(self):
        lines = self.command('shell', 'dumpsys', 'activity', 'activities').stdout.splitlines()
        return any(re.search(r'\b' + re.escape(self.package) + r'/', line)
                   for line in lines if 'mResumedActivity' in line or 'topResumedActivity' in line)

    def require_target(self):
        self.ready()
        if not self.resumed():
            raise RuntimeError(f'{self.package} is not resumed on {self.serial}; refusing device capture/input')

    def process_identity(self):
        pids = self.command('shell', 'pidof', self.package, check=False).stdout.split()
        if not pids:
            return None
        if len(pids) != 1 or not pids[0].isdigit():
            raise RuntimeError('Application process identity is ambiguous')
        pid = pids[0]
        stat = self.command('shell', 'cat', f'/proc/{pid}/stat', check=False)
        # stat field 22; the parenthesized command may contain spaces.
        fields = stat.stdout.rsplit(')', 1)[-1].split()
        return {'pid': int(pid), 'startTicks': fields[19] if stat.returncode == 0 and len(fields) > 19 else None}

    def screenshot(self, output, probe=None, seconds=10):
        output = Path(output).resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        candidate = output.with_name(f'.{output.stem}-{uuid.uuid4().hex}.png')
        diagnostic = output.with_name(output.stem + '.failed-device.png')
        # A failed attempt must never leave an older image that looks current.
        remove_stale(output, diagnostic)
        started = time.monotonic()
        try:
            while True:
                self.require_target()
                result = subprocess.run([adb_binary(), '-s', self.serial, 'exec-out', 'screencap', '-p'],
                                        capture_output=True, timeout=20, creationflags=NO_WINDOW)
                if result.returncode:
                    raise RuntimeError(result.stderr.decode(errors='replace'))
                width, height = png_size(result.stdout)
                candidate.write_bytes(result.stdout)  # binary, no PowerShell redirection
                self.require_target()
                if probe is None or marker_matches(candidate, probe):
                    candidate.replace(output)
                    return {'path': str(output), 'source': 'Android display', 'deviceId': self.serial,
                            'package': self.package, 'width': width, 'height': height,
                            'presentationVerified': probe is not None, 'probeMatched': probe is not None,
                            'lossless': True, 'elapsedMs': round((time.monotonic() - started) * 1000)}
                if time.monotonic() - started >= seconds:
                    candidate.replace(diagnostic)
                    raise TimeoutError(f'Device never presented marker {probe["token"]}; diagnostic: {diagnostic}')
                time.sleep(.1)
        finally:
            candidate.unlink(missing_ok=True)

    def back(self):
        self.require_target()
        self.command('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    def background(self):
        self.require_target()
        self.command('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        wait_until(self.resumed, lambda value: not value, description='app to leave resumed activity')

    def resume(self):
        self.ready()
        component = self.command('shell', 'cmd', 'package', 'resolve-activity', '--brief', self.package).stdout.strip().splitlines()[-1]
        if not re.fullmatch(re.escape(self.package) + r'/[A-Za-z0-9_.$]+', component):
            raise RuntimeError(f'Unexpected launcher component: {component}')
        self.command('shell', 'am', 'start', '-W', '-n', component)
        wait_until(self.resumed, bool, description='target resumed activity')


class DeviceRecording:
    """Bounded Android screenrecord, retaining its original lossy encoded source."""
    def __init__(self, device, output, seconds=8, probe=None):
        if not 1 <= seconds <= 30:
            raise ValueError('Device recording duration must be 1..30 seconds')
        self.device, self.output, self.seconds = device, Path(output).resolve(), seconds
        self.probe = probe
        self.remote = f'/data/local/tmp/flutter-capture-{uuid.uuid4().hex}.mp4'
        self.process = None

    def start(self):
        self.output.parent.mkdir(parents=True, exist_ok=True)
        remove_stale(self.output, self.output.with_name(self.output.stem + '.failed-device.mp4'),
                     self.output.with_name(self.output.stem + '.presentation.png'))
        self.device.require_target()
        self.source_display = self.device.screenshot(
            self.output.with_name(self.output.stem + '.source-display.png'), self.probe)
        self.started = time.monotonic()
        self.log = self.output.with_suffix('.screenrecord.log').open('wb')
        try:
            self.process = subprocess.Popen([adb_binary(), '-s', self.device.serial, 'shell',
                                            'screenrecord', '--verbose', '--time-limit', str(self.seconds), self.remote],
                                           stdout=self.log, stderr=self.log, creationflags=NO_WINDOW)
            # Wait for this invocation's output, not an unrelated recorder process.
            wait_until(lambda: (self.process.poll(), self.device.command('shell', 'test', '-f', self.remote, check=False).returncode),
                       lambda state: self._started(state), seconds=10, description='screenrecord file')
            return {'started': True, 'sourceIsLossy': True, 'remotePath': self.remote,
                    'sourceDisplay': self.source_display}
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _started(state):
        if state[0] not in (None, 0):
            raise RuntimeError('screenrecord exited before producing a file; inspect screenrecord.log')
        return state[1] == 0

    def finish(self):
        try:
            self.process.wait(timeout=self.seconds + 20)
            if self.process.returncode:
                raise RuntimeError('screenrecord failed; inspect screenrecord.log')
            self.device.require_target()
            temporary = self.output.with_name(f'.{self.output.stem}-{uuid.uuid4().hex}.mp4')
            try:
                self.device.command('pull', self.remote, str(temporary), timeout=40)
                from media import inspect_video
                notes = inspect_video(temporary)
                source = getattr(self, 'source_display', notes)
                projection = display_projection(source['width'], source['height'], notes['width'], notes['height'])
                presentation = False
                if self.probe:
                    frame = self.output.with_name(self.output.stem + '.presentation.png')
                    for offset in (0, .25, .5, 1):
                        if offset >= notes['durationSeconds']:
                            continue
                        run([program('ffmpeg'), '-v', 'error', '-y', '-ss', str(offset),
                             '-i', temporary, '-frames:v', '1', frame])
                        if marker_matches(frame, self.probe, projection):
                            presentation = True
                            break
                    if not presentation:
                        failed = self.output.with_name(self.output.stem + '.failed-device.mp4')
                        temporary.replace(failed)
                        raise RuntimeError(f'Recording never presented requested marker; original retained: {failed}')
                temporary.replace(self.output)
            except BaseException:
                if temporary.exists():
                    temporary.replace(self.output.with_name(self.output.stem + '.failed-device.mp4'))
                raise
            finally:
                temporary.unlink(missing_ok=True)
            return {**notes, 'path': str(self.output), 'source': 'Android screenrecord',
                    'sourceIsLossy': True, 'losslessVerified': False,
                    'presentationVerified': presentation,
                    'displayProjection': projection,
                    'elapsedMs': round((time.monotonic() - self.started) * 1000),
                    'expectedMs': self.seconds * 1000}
        finally:
            self.close()

    def close(self):
        if self.process and self.process.poll() is None:
            # screenrecord itself is time-limited. Killing its ADB client is not
            # evidence that the device encoder stopped; let it finalize first.
            try:
                self.process.wait(timeout=self.seconds + 20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if getattr(self, 'log', None):
            self.log.close()
        if self.process:
            try:
                self.device.command('shell', 'rm', '-f', self.remote, check=False)
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                # A disconnect must not mask the original capture/encode error.
                # The unique remote path is retained in the start metadata/log.
                pass


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['screenshot', 'record'])
    parser.add_argument('--device', required=True)
    parser.add_argument('--package', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--probe-json')
    parser.add_argument('--seconds', type=int, default=8)
    args = parser.parse_args()
    device = AndroidDevice(args.device, args.package)
    if args.action == 'screenshot':
        probe = json.loads(Path(args.probe_json).read_text()) if args.probe_json else None
        result = device.screenshot(args.output, probe)
    else:
        recording = DeviceRecording(device, args.output, args.seconds)
        recording.start()
        result = recording.finish()
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
