"""Runtime acceptance for modal routes, animation pixels and presentation fences."""
from __future__ import annotations

import json
import os
from pathlib import Path
import statistics
import subprocess
import time

import windows_platform as lab
from window_capture import capture_png, probe_arguments
from windows_evidence import ForegroundEvidence


def pixels(path, filters):
    result = subprocess.run([lab.program('ffmpeg'), '-v', 'error', '-i', str(path),
        '-vf', filters, '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
        capture_output=True, timeout=25, creationflags=lab.CREATE_NO_WINDOW)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return result.stdout


def difference(left, right):
    if not left or len(left) != len(right):
        raise ValueError('Pixel buffers must be nonempty and the same size')
    return sum(abs(a - b) for a, b in zip(left, right)) / len(left)


def compare_capture(app_path, window_path, app, window):
    crop = f"crop={app['width']}:{app['height']}:{window['clientX']}:{window['clientY']},"
    app_pixels = pixels(app_path, 'scale=96:54')
    window_pixels = pixels(window_path, crop + 'scale=96:54')
    return {'meanPixelDifference': difference(app_pixels, window_pixels),
            'windowContentStdDev': statistics.pstdev(window_pixels)}


class AppRecorder:
    def __init__(self, output, seconds=8):
        self.output, self.seconds = output, seconds
        self.frames = output.with_name(output.stem + '-frames')
        self.process = None
        self.log = None

    def start(self):
        self.log = self.output.with_suffix('.driver.log').open('w', encoding='utf-8')
        self.process = subprocess.Popen([lab.dart(), 'run', 'tool/record_app.dart',
            lab.session()['vmUri'], str(self.frames), str(self.seconds), '5'],
            cwd=lab.APP, stdout=subprocess.PIPE, stderr=self.log,
            text=True, encoding='utf-8', creationflags=lab.CREATE_NO_WINDOW)
        # Dart connection and request timeouts bound this producer's startup.
        import queue
        import threading
        ready = queue.Queue(maxsize=1)
        threading.Thread(target=lambda: ready.put(self.process.stdout.readline()), daemon=True).start()
        try:
            message = json.loads(ready.get(timeout=20))
            if not message.get('ready'):
                raise RuntimeError(f'App recorder not ready: {message}')
            return message
        except Exception:
            self.close()
            raise

    def finish(self):
        try:
            stdout = self.process.communicate(timeout=self.seconds * 2 + 20)[0]
            if self.process.returncode:
                raise RuntimeError(f'App recording failed; inspect {self.log.name}')
            notes = json.loads(stdout.strip().splitlines()[-1])
            from media import encode_png_sequence
            return {**notes, **encode_png_sequence(self.output, self.frames)}
        finally:
            self.close()

    def close(self):
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        if self.log:
            self.log.close()


def verify_scenarios(output, check, shots, state, native_step):
    evidence = {}
    foreground = ForegroundEvidence(evidence)
    lab.drive('tap', 'nav-scenarios')
    baseline = state('scenarios-baseline')
    shots('scenarios-idle')
    center = lab.drive('center', 'nav-gallery')
    lab.drive('tap', 'open-dialog')
    opened = lab.drive('wait', 'confirmation-dialog')
    check('dialog route opens through internal click', opened['dialogOpen'])
    shots('dialog-open')
    # Driver injects a pointer at the real navigation control. ModalBarrier must
    # intercept it; mutating page state directly would miss this regression.
    blocked = lab.drive('tap-at', str(center['x']), str(center['y']))
    check('modal barrier blocks underlying navigation', blocked['page'] == 'scenarios' and blocked['dialogOpen'])
    lab.drive('tap', 'dialog-confirm')
    confirmed = lab.drive('wait-absent', 'confirmation-dialog')
    check('dialog confirm invokes callback and dismisses route',
          not confirmed['dialogOpen'] and confirmed['dialogResult'] == 'confirmed'
          and confirmed['dialogConfirmed'] == baseline['dialogConfirmed'] + 1)
    lab.drive('tap', 'open-dialog')
    lab.drive('wait', 'confirmation-dialog')
    lab.drive('tap', 'dialog-cancel')
    cancelled = lab.drive('wait-absent', 'confirmation-dialog')
    check('dialog cancel dismisses without confirm callback',
          not cancelled['dialogOpen'] and cancelled['dialogResult'] == 'cancelled'
          and cancelled['dialogConfirmed'] == confirmed['dialogConfirmed'])
    shots('dialog-dismissed')

    lab.drive('tap', 'animation-reset')
    # The animation repeats, so waiting for the UI to settle would only time out.
    playing = lab.drive('tap', 'animation-play', '--no-settle')
    native = lab.new_recording(output/'animation-window.mp4', seconds=8)
    app = AppRecorder(output/'animation-app.mp4', seconds=8)
    native_notes = None
    try:
        native_ready = native_step('animation native recording started', native.start)
        app_ready = app.start()
        time.sleep(1.1)
        moving = state('animation-playing')
        check('real animation receives ticker frames',
              moving['animationRunning'] and moving['animationFrames'] > playing['animationFrames'] + 10)
        paused = lab.drive('tap', 'animation-pause')
        # Both videos have a moving segment followed by a stable segment.
        time.sleep(.5)
        stopped = state('animation-paused')
        check('pause stops the animation ticker', not stopped['animationRunning']
              and stopped['animationFrames'] == paused['animationFrames']
              and stopped['animationValue'] == paused['animationValue'])
        if native_ready is not None:
            # A simultaneous screenshot advances the probe token. This must not
            # interrupt a running video capture of the same HWND.
            concurrent_shot = native_step('native screenshot can run during recording',
                lambda: lab.window_shot(output/'during-animation-recording.png'))
            if concurrent_shot is not None:
                check('native screenshot can run during recording', concurrent_shot['probeMatched'], group='native')
            native_notes = native_step('animation native recording completed', native.finish)
        app_notes = app.finish()
    finally:
        app.close()
        if native.encoder and native.capture.poll() is None:
            try:
                native.finish()
            except Exception:
                pass
        lab.drive('tap', 'animation-pause')
    check('app animation master preserves original pixels', app_notes['losslessVerified'])
    check('app animation wall-clock pacing matches its timeline', lab.timing_ok(app_notes, 8000, 40),
          {key: app_notes.get(key) for key in ('elapsedMs', 'lateFrames', 'maxLagMs')})
    if native_notes is not None:
        foreground.recording('animation-window', native_notes)
        check('window animation master preserves original pixels', native_notes['losslessVerified'], group='native')
        check('window animation wall-clock pacing matches its timeline', lab.timing_ok(native_notes, 8000, 96),
              {key: native_notes.get(key) for key in ('elapsedMs', 'lateFrames', 'maxLagMs')}, group='native')
    rect = moving['animationRect']
    results = {'window': native_notes, 'app': app_notes,
               'ready': {'window': native_ready, 'app': app_ready}, **evidence}
    for source in ('app', 'window') if native_notes is not None else ('app',):
        group = 'functional' if source == 'app' else 'native'
        scale = native.probe['pixelRatio']
        offset_x = 0 if source == 'app' else native_ready['clientX']
        offset_y = 0 if source == 'app' else native_ready['clientY']
        roi = f"crop={round(rect['width']*scale)}:{round(rect['height']*scale)}:{round(rect['x']*scale)+offset_x}:{round(rect['y']*scale)+offset_y}"
        raw = pixels(output/f'animation-{source}.lossless.mkv', f'fps=2,{roi},scale=96:14')
        size = 96 * 14 * 3
        frames = [raw[i:i+size] for i in range(0, len(raw), size)]
        motion = max(difference(frames[0], frame) for frame in frames[1:5])
        still = max(difference(frames[-1], frame) for frame in frames[-4:-1])
        check(f'{source} animation pixels move then remain still', len(frames) == 16
              and motion > 2 and still < .6,
              {'motionMeanDifference': motion, 'pausedMeanDifference': still, 'samples': len(frames)},
              group=group)
        lab.run([lab.program('ffmpeg'), '-v', 'error', '-y', '-i',
            output/f'animation-{source}.mp4', '-vf', 'fps=1,scale=480:-1,tile=4x2',
            '-frames:v', '1', output/f'animation-{source}-contact-sheet.png'])
        for second in (1, 6):
            lab.run([lab.program('ffmpeg'), '-v', 'error', '-y', '-ss', str(second),
                '-i', output/f'animation-{source}.lossless.mkv', '-frames:v', '1',
                output/f'animation-{source}-original-{second}s.png'])
        results[source]['motionMeanDifference'] = motion
        results[source]['pausedMeanDifference'] = still
    shots('animation-paused')
    reset = lab.drive('tap', 'animation-reset')
    check('animation reset returns to start', not reset['animationRunning'] and reset['animationValue'] == 0)
    foreground.state('scenarios-baseline', baseline)
    foreground.state('scenarios-reset', reset)
    return results


def verify_cold(cycles=3):
    if not 1 <= cycles <= 5:
        raise ValueError('Cold verification cycles must be 1..5')
    output = lab.ARTIFACTS / time.strftime('cold-%Y%m%d-%H%M%S')
    output.mkdir(parents=True)
    report = {'cycles': [], 'passed': False}
    foreground = ForegroundEvidence(report)
    try:
        for cycle in range(cycles):
            lab.stop()
            placement = ('auto', 'primary', 'secondary')[cycle % 3]
            os.environ['CAPTURE_LAB_PLACEMENT'] = placement
            initial = lab.start()
            foreground.state(f'cold-{cycle}-initial', initial)
            assert not initial['native']['topmost']
            bounds, work = initial['native']['windowBounds'], initial['native']['monitorWorkArea']
            assert bounds['left'] >= work['left'] and bounds['top'] >= work['top']
            assert bounds['right'] <= work['right'] and bounds['bottom'] <= work['bottom']
            assert initial['native']['monitorPrimary'] == (placement == 'primary' or initial['native']['monitorCount'] == 1)
            result = {'cycle': cycle, 'placement': placement, 'initial': initial, 'captures': []}
            report['cycles'].append(result)
            for page in ('overview', 'gallery', 'interaction', 'scenarios'):
                if page != 'overview':
                    lab.drive('foreground', 'on')
                    lab.drive('tap', f'nav-{page}')
                prefix = output/f'{cycle}-{page}'
                app = lab.drive('app-shot', str(prefix.with_name(prefix.name+'-app.png')))
                window = lab.window_shot(prefix.with_name(prefix.name+'-window.png'))
                metrics = compare_capture(Path(app['path']), Path(window['path']), app, window)
                current = lab.drive('state')
                item = {'page': page, 'window': window, 'comparison': metrics, 'state': current}
                result['captures'].append(item)
                assert current['page'] == page and window['probeMatched']
                assert metrics['meanPixelDifference'] < 3.5 and metrics['windowContentStdDev'] > 8, item
                foreground.state(f'cold-{cycle}-{page}', current)
                print(f'PASS cold {cycle+1}/{cycles}: {page}, pixel difference {metrics["meanPixelDifference"]:.3f}', flush=True)
            # Deliberately request a token not yet rendered. API success with an
            # old valid frame must not complete the capture. Release the fence by
            # painting that exact token, without any native activation.
            probe = lab.drive('prepare-capture')
            future = {**probe, 'token': (probe['token'] + 1) & 0xffffff}
            pending = output/f'{cycle}-fence.png'
            process = subprocess.Popen([str(lab.capture_binary()), '--hwnd',
                str(probe['native']['hwnd']), '--backend', 'wgc', '--png', str(pending),
                *probe_arguments(future)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, creationflags=lab.CREATE_NO_WINDOW)
            try:
                time.sleep(.3)
                assert process.poll() is None, 'Stale frame was incorrectly accepted'
                released = lab.drive('prepare-capture')
                assert released['token'] == future['token']
                stdout, stderr = process.communicate(timeout=15)
                assert process.returncode == 0, stderr
                fence = json.loads(stdout)
                assert fence['probeMatched'] and fence['firstFrameWaitMs'] >= 250
                assert fence['rejectedFrames'] >= 1, 'Control did not observe a stale native frame'
                result['presentationFence'] = fence
                print(f'PASS cold {cycle+1}/{cycles}: stale frame rejected until token presented', flush=True)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            if cycle == 0:
                missing = {**released, 'token': (released['token'] + 99) & 0xffffff}
                invalid_path = output/'never-presented.png'
                try:
                    capture_png(invalid_path, hwnd=missing['native']['hwnd'],
                        process_id=missing['native']['pid'], backend='wgc', probe=missing)
                except RuntimeError as error:
                    assert 'Timed out waiting for the requested presented frame' in str(error)
                    assert not invalid_path.exists(), 'Timeout saved a false-success image'
                    result['missingFrameTimeout'] = {'passed': True, 'error': str(error)}
                else:
                    raise AssertionError('A never-presented token was incorrectly accepted')
                print('PASS missing frame: bounded timeout, no false-success PNG', flush=True)
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        lab.stop()
        (output/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({'passed': report['passed'], 'report': str(output/'report.json')}), flush=True)
    return report
