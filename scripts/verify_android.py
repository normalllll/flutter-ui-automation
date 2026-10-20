"""Android acceptance through Flutter controls and independent device pixels."""
from __future__ import annotations

import json
from pathlib import Path
import statistics
import subprocess
import time
import traceback

from media import inspect_video
from android_device import project_region
from runtime import NO_WINDOW, program, wait_until

# Device-channel failures that are recorded as deviceCapture evidence.
DEVICE_ERRORS = (RuntimeError, TimeoutError, OSError, ValueError, subprocess.TimeoutExpired)


def image_pixels(path, region=None):
    crop = 'crop={width}:{height}:{x}:{y},'.format(**region) if region else ''
    result = subprocess.run([program('ffmpeg'), '-v', 'error', '-i', str(path),
                             '-vf', crop + 'scale=96:54', '-frames:v', '1',
                             '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
                            capture_output=True, timeout=20, creationflags=NO_WINDOW)
    if result.returncode or len(result.stdout) != 96 * 54 * 3:
        raise RuntimeError('Image decode/crop failed: ' + result.stderr.decode(errors='replace'))
    return result.stdout


def physical_region(rect, ratio, origin=None):
    origin = origin or {'x': 0, 'y': 0}
    return {'x': round(rect['x'] * ratio + origin['x']),
            'y': round(rect['y'] * ratio + origin['y']),
            'width': round(rect['width'] * ratio), 'height': round(rect['height'] * ratio)}


def verify(platform, app_fps=2):
    previous = platform.store.read()
    started_here = not previous.get('vmUri')
    output = platform.store.directory / f'run-{time.time_ns()}'
    output.mkdir(parents=True)
    report = {'platform': 'android', 'deviceId': platform.serial, 'output': str(output),
              'checks': [], 'captures': {}, 'recordings': {}, 'snapshots': {},
              'nativeUi': {'supported': False, 'reason': 'Permission dialogs and native views require a separate native automation backend'},
              'imeCompositionVerified': False, 'completed': False, 'appRecordingFps': app_fps}
    client = None
    recording = None

    def check(name, passed, detail=None, group='functional'):
        report['checks'].append({'name': name, 'passed': bool(passed), 'detail': detail, 'group': group})
        print(f'{"PASS" if passed else "FAIL"}: {name}', flush=True)
        # A device-capture failure (no presented marker, screencap/screenrecord
        # error) is recorded and the Flutter and lifecycle checks continue, so
        # one channel's failure does not hide the others' results. Acceptance
        # still requires every group.
        if not passed and group != 'deviceCapture':
            raise AssertionError(name)

    def device_step(name, action):
        try:
            return action()
        except DEVICE_ERRORS as error:
            check(name, False, {'error': str(error)}, 'deviceCapture')
            return None

    def state(label=None):
        value = client.drive('state')
        if label: report['snapshots'][label] = value
        return value

    def tap(key):
        if not key.startswith('nav-'):
            client.drive('reveal', key)
        return client.drive('tap', key)

    def shots(label):
        app = client.screenshot(output/f'{label}-app.png')
        check(f'{label}: Flutter screenshot settled', app.get('settled'), app, 'appCapture')
        report['captures'][label] = {'app': app}
        device = device_step(f'{label}: device screenshot presented',
                             lambda: platform.screenshot(output/f'{label}-device.png'))
        if device is None:
            return
        origin = device['probe']['native']['viewBounds']
        content = app['contentRect']
        region = {**content, 'x': origin['x'] + content['x'], 'y': origin['y'] + content['y']}
        left, right = image_pixels(app['path'], content), image_pixels(device['path'], region)
        difference = sum(abs(a-b) for a, b in zip(left, right)) / len(left)
        report['captures'][label] = {'app': app, 'device': device, 'deviceContentRect': region,
                                    'meanPixelDifference': difference}
        check(f'{label}: device displays current Flutter content',
              device['presentationVerified'] and statistics.pstdev(right) > 8 and difference < 8,
              {'meanPixelDifference': difference}, 'deviceCapture')

    try:
        initial = platform.start()
        client = platform.client()
        check('mobile uses real lifecycle and focus', not initial['capabilities']['foregroundSimulation']
              and not initial['pretendForeground'], initial['capabilities'], 'lifecycle')
        platform.device.require_target()
        platform.rotate('portrait')
        wait_until(state, lambda s: s['view']['height'] > s['view']['width'], description='portrait Flutter metrics')
        tap('nav-overview')
        shots('overview')
        baseline = state()['clicks']
        tap('nav-gallery')
        tap('tile-0')
        client.drive('scroll', 'gallery-scroll', '-350')
        gallery = state('gallery')
        check('gallery click and scroll reach handlers', gallery['clicks'] == baseline + 1 and gallery['scrollOffset'] > 50)
        shots('gallery')
        tap('nav-interaction')
        client.drive('text-emulation', 'on')
        tap('input-field')
        client.drive('text', 'Android / 测试输入')
        check('Flutter text handling preserves Unicode', state()['text'] == 'Android / 测试输入')
        tap('increment-button')
        check('button callback increments counter', state()['clicks'] == baseline + 2)
        shots('interaction')

        # Switch back to the platform text channel before testing a real IME.
        client.drive('unfocus')
        client.drive('text-emulation', 'off')
        tap('input-field')
        keyboard = wait_until(state, lambda s: s['native'].get('keyboardVisible') and s['view']['keyboardInset'] > 0,
                              description='real Android keyboard and Flutter inset')
        report['snapshots']['keyboard'] = keyboard
        shots('keyboard')
        platform.device.back()
        wait_until(state, lambda s: not s['native'].get('keyboardVisible') and s['view']['keyboardInset'] == 0,
                   description='keyboard dismissal')

        tap('nav-scenarios')
        tap('open-dialog')
        opened = client.drive('wait', 'confirmation-dialog')
        check('Flutter modal opens', opened['dialogOpen'])
        shots('dialog')
        tap('dialog-confirm')
        closed = client.drive('wait-absent', 'confirmation-dialog')
        check('dialog confirmation reaches callback', closed['dialogConfirmed'] == opened['dialogConfirmed'] + 1)
        tap('open-dialog')
        platform.device.back()
        dismissed = client.drive('wait-absent', 'confirmation-dialog')
        check('system Back dismisses modal without confirmation', not dismissed['dialogOpen']
              and dismissed['dialogConfirmed'] == closed['dialogConfirmed'])

        # Move controls into view first; retain the animation stage in the viewport.
        client.drive('reveal', 'animation-play')
        client.drive('tap', 'animation-play', '--no-settle')
        active = state('animation-start')
        wait_until(state, lambda s: s['animationFrames'] > active['animationFrames'], description='animation frames')
        rect, ratio = active['animationRect'], active['view']['pixelRatio']
        check('animation stage is visible', rect is not None and rect['y'] >= 0
              and rect['y'] + rect['height'] <= active['view']['height'])
        # The recordings overlap. Changes are measured only in the animation stage,
        # excluding heartbeats, status bars, clocks and the presentation marker.
        device_step('device screenshot before recording presented',
                    lambda: platform.screenshot(output/'before-recording-device.png'))
        recording = platform.recording(output/'animation-device.mp4', seconds=12)
        report['recordings']['deviceStart'] = device_step('device recording started', recording.start)
        if report['recordings']['deviceStart'] is None:
            recording = None
        app_recording = client.record(output/'animation-app.mp4', seconds=5, fps=app_fps)
        report['recordings']['app'] = app_recording
        device_recording = device_step('device recording completed', recording.finish) if recording else None
        report['recordings']['device'] = device_recording
        recording = None
        app_video = inspect_video(app_recording['masterPath'], physical_region(rect, ratio))
        report['recordings']['appAnimation'] = app_video
        check('Flutter recording preserves pixels and wall-clock pacing',
              app_recording['losslessVerified'] and app_recording['timingVerified']
              and abs(app_video['durationSeconds'] - 5) <= .25
              and app_video['uniqueSampleFrames'] > 2, app_video, 'appCapture')
        if device_recording is not None:
            device_region = project_region(physical_region(rect, ratio, active['native']['viewBounds']),
                                           device_recording['displayProjection'])
            device_video = device_step('device recording decodes',
                                       lambda: inspect_video(device_recording['path'], device_region))
            report['recordings']['deviceAnimation'] = device_video
            if device_video is not None:
                check('device recording decodes with expected duration and animation',
                      device_recording['presentationVerified'] and 11 <= device_video['durationSeconds'] <= 13
                      and device_video['uniqueSampleFrames'] > 2,
                      device_video, 'deviceCapture')
        tap('animation-pause')
        paused = state()
        # Pixel comparison excludes unrelated heartbeat updates.
        first = client.screenshot(output/'paused-before-app.png')
        later = client.screenshot(output/'paused-after-app.png')
        paused_rect = physical_region(paused['animationRect'], ratio)
        check('paused animation pixels stay still', image_pixels(first['path'], paused_rect) == image_pixels(later['path'], paused_rect))
        tap('animation-reset')
        check('animation reset reaches initial value', state()['animationValue'] == 0)

        tap('nav-interaction')
        platform.rotate('landscape')
        wait_until(state, lambda s: s['view']['width'] > s['view']['height'], description='landscape Flutter metrics')
        shots('landscape')
        platform.rotate('portrait')
        wait_until(state, lambda s: s['view']['height'] > s['view']['width'], description='restored portrait metrics')
        before = state('before-background')
        identity = platform.device.process_identity()
        platform.device.background()
        background = wait_until(state, lambda s: s['effectiveLifecycle'] in ('hidden', 'paused'), description='real background lifecycle')
        report['snapshots']['background'] = background
        check('background does not use simulated foreground', not background['pretendForeground'], group='lifecycle')
        platform.device.resume()
        restored = wait_until(state, lambda s: s['effectiveLifecycle'] == 'resumed' and s['native']['isForeground'], description='resumed Flutter lifecycle')
        check('resume preserves state and process identity', restored['text'] == before['text']
              and restored['clicks'] == before['clicks'] and platform.device.process_identity() == identity,
              restored['lifecycleEvents'], 'lifecycle')
        shots('resumed')
        report['completed'] = True
    except Exception as error:
        report['error'] = str(error)
        report['traceback'] = traceback.format_exc()
    finally:
        if recording:
            try: recording.close()
            except Exception as error: report['recordingCleanupError'] = str(error)
        if client:
            for action, arguments in [('orientation', ('restore',)), ('text-emulation', ('off',))]:
                try: client.drive(action, *arguments)
                except Exception as error: report.setdefault('cleanupErrors', []).append(str(error))
        if started_here:
            try: platform.stop()
            except Exception as error: report.setdefault('cleanupErrors', []).append(str(error))
        for group in ('functional', 'appCapture', 'deviceCapture', 'lifecycle'):
            checks = [c for c in report['checks'] if c['group'] == group]
            report[group+'Passed'] = report['completed'] and bool(checks) and all(c['passed'] for c in checks) and 'error' not in report
        report['passed'] = all(report[g+'Passed'] for g in ('functional', 'appCapture', 'deviceCapture', 'lifecycle')) and not report.get('cleanupErrors')
        report['visualInspection'] = 'pending: inspect original PNGs and videos before visual acceptance'
        (output/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return report
