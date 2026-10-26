"""Android protocol tests using isolated sessions and synthetic device pixels."""
import json
import shutil
from pathlib import Path
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch
import zlib
import time

from android_device import AndroidDevice, DeviceRecording, default_display_id, marker_matches, png_size
from android_platform import AndroidPlatform, PACKAGE
from lab_cli import main
from sessions import SessionStore, target_key
from runtime import program, run


def write_marker_png(path, word):
    # Device screenshot: view starts at (10, 20), marker logical rect at
    # (8, 8), pixel ratio 2, with 32 physical cells of 8 x 16 pixels.
    width, height = 320, 180
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            if 26 <= x < 282 and 36 <= y < 52:
                bit = (word >> (31 - (x - 26) // 8)) & 1
                row.extend((240, 180, 41) if bit else (22, 50, 79))
            else:
                row.extend((245, 247, 251))
        rows.append(b'\0' + row)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


class SessionTests(unittest.TestCase):
    def test_device_names_cannot_escape_session_root_or_collide(self):
        self.assertNotEqual(target_key('android', 'host:5555'), target_key('android', 'host_5555'))
        self.assertNotEqual(target_key('android', '../other'), target_key('windows', '../other'))
        with self.assertRaises(ValueError): target_key('android', 'serial', '../other')

    def test_named_sessions_share_device_lease_and_release_only_their_own(self):
        with tempfile.TemporaryDirectory() as directory:
            one = SessionStore('android', 'serial', 'one', directory)
            two = SessionStore('android', 'serial', 'two', directory)
            with one.launching(): one.write({'owned': True, 'vmUri': None})
            with self.assertRaises(RuntimeError):
                with two.launching(): pass
            two.release()
            self.assertTrue(one.lease.exists())
            one.release()
            with two.launching(): two.write({'owned': False})
            self.assertEqual(two.read(), {'owned': False})
            two.release()

    def test_detach_never_stops_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            platform = AndroidPlatform('serial')
            platform.store = SessionStore('android', 'serial', root=directory)
            platform.device = MagicMock()
            with platform.store.launching():
                platform.store.write({'owned': False, 'vmUri': 'ws://localhost:1/ws',
                                      'deviceId': 'serial', 'package': PACKAGE})
            self.assertFalse(platform.stop()['appStopped'])
            platform.device.command.assert_not_called()
            platform.device.process_identity.assert_not_called()

    def test_stale_session_cannot_force_stop_restarted_app(self):
        with tempfile.TemporaryDirectory() as directory:
            platform = AndroidPlatform('serial')
            platform.store = SessionStore('android', 'serial', root=directory)
            platform.device = MagicMock()
            platform.device.process_identity.return_value = {'pid': 12, 'startTicks': 'new'}
            with platform.store.launching():
                platform.store.write({'owned': True, 'deviceId': 'serial', 'package': PACKAGE,
                                      'appProcess': {'pid': 12, 'startTicks': 'old'}})
            with self.assertRaisesRegex(RuntimeError, 'identity changed'): platform.stop()
            platform.device.command.assert_not_called()
            self.assertTrue(platform.store.lease.exists())
            platform.store.release()

    def test_attach_rejects_vm_from_another_device(self):
        platform = AndroidPlatform('serial')
        platform.device = MagicMock()
        platform.device.command.return_value.stdout = 'selected-device-token'
        state = {'native': {'package': PACKAGE, 'instanceToken': 'other-device-token'},
                 'capabilities': {'appScreenshot': True}}
        with self.assertRaisesRegex(RuntimeError, 'selected device instance'):
            platform._validate_app(state)


class CaptureTests(unittest.TestCase):
    def test_fold_capture_uses_logical_primary_panel_instead_of_first_physical_panel(self):
        dump = '''Logical Displays: size=2
  Display 0:
    mPrimaryDisplayDevice=Built-in screen(local:4630946872173396372)
    mIsEnabled=true
  Display 1:
    mPrimaryDisplayDevice=Built-in screen(local:4630946449689556883)
    mIsEnabled=false
'''
        self.assertEqual(default_display_id(dump), '4630946872173396372')
        folded = dump.replace('4630946872173396372', 'swap').replace('4630946449689556883', '4630946872173396372').replace('swap', '4630946449689556883')
        self.assertEqual(default_display_id(folded), '4630946449689556883')
        with self.assertRaisesRegex(RuntimeError, 'ambiguous capture'):
            default_display_id('Display 1:\n mPrimaryDisplayDevice=Other(local:12)')

    def test_configured_app_rate_matches_encoded_duration(self):
        from flutter_client import FlutterClient
        from media import inspect_video
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'app.mp4'
            def producer(args, **kwargs):
                frames, seconds, fps = Path(args[4]), int(args[5]), int(args[6])
                for index in range(seconds * fps):
                    write_marker_png(frames/f'{index:04d}.png', 0xa00002a5 + index * 16)
                return SimpleNamespace(stdout=json.dumps({'elapsedMs': seconds * 1000,
                                                         'lateFrames': 0, 'fps': fps,
                                                         'frames': seconds * fps}))
            with patch('flutter_client.dart', return_value='dart'), patch('flutter_client.run', side_effect=producer):
                notes = FlutterClient('ws://localhost:1/ws').record(output, seconds=5, fps=2)
            self.assertTrue(notes['losslessVerified'])
            self.assertTrue(notes['timingVerified'])
            self.assertEqual(notes['verifiedFrames'], 10)
            self.assertAlmostEqual(inspect_video(notes['masterPath'])['durationSeconds'], 5.0, places=2)

    def test_encoded_recording_preserves_original_and_checks_presented_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image, source = root/'source.png', root/'source.mp4'
            write_marker_png(image, 0xa00002a5)
            run([program('ffmpeg'), '-v', 'error', '-loop', '1', '-i', image, '-t', '2',
                 '-vf', 'scale=300:168,pad=300:300:0:66',
                 '-c:v', 'libx264', '-pix_fmt', 'yuv420p', source])
            probe = {'token': 42, 'rect': {'x': 8, 'y': 8, 'width': 128, 'height': 8},
                     'pixelRatio': 2, 'native': {'viewBounds': {'x': 10, 'y': 20, 'width': 300, 'height': 150}}}
            device = MagicMock()
            def command(*args, **kwargs):
                if args[0] == 'pull': shutil.copyfile(source, args[2])
            device.command.side_effect = command
            for token in (42, 43):
                output = root/f'capture-{token}.mp4'
                recording = DeviceRecording(device, output, 2, {**probe, 'token': token})
                recording.process = MagicMock()
                recording.process.poll.return_value = 0
                recording.process.returncode = 0
                recording.started = time.monotonic()
                recording.source_display = {'width': 320, 'height': 180}
                if token == 42:
                    notes = recording.finish()
                    self.assertTrue(notes['presentationVerified'])
                    self.assertTrue(notes['sourceIsLossy'])
                    self.assertFalse(notes['losslessVerified'])
                    self.assertEqual(output.read_bytes(), source.read_bytes())
                    self.assertEqual(notes['displayProjection']['y'], 66)
                    self.assertEqual(notes['displayProjection']['height'], 168)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'never presented'):
                        recording.finish()
                    self.assertFalse(output.exists())
                    self.assertEqual((root/f'capture-{token}.failed-device.mp4').read_bytes(), source.read_bytes())

    def test_actual_marker_decoder_maps_origin_and_dpr_and_rejects_stale_token(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'device.png'
            write_marker_png(path, 0xa00002a5)
            probe = {'token': 42, 'rect': {'x': 8, 'y': 8, 'width': 128, 'height': 8},
                     'pixelRatio': 2, 'native': {'viewBounds': {'x': 10, 'y': 20, 'width': 300, 'height': 150}}}
            self.assertTrue(marker_matches(path, probe))
            self.assertFalse(marker_matches(path, {**probe, 'token': 43}))
            self.assertEqual(png_size(path.read_bytes()), (320, 180))

    def test_binary_png_is_preserved_and_capture_requires_target(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'shot.png'
            write_marker_png(output, 0xa00002a5)
            original = output.read_bytes()
            device = AndroidDevice('serial:5555', PACKAGE)
            with patch.object(device, 'require_target') as scope, patch.object(device, 'display_id', return_value='4630946872173396372'), patch('android_device.adb_binary', return_value='adb'), \
                 patch('android_device.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout=original)) as execute:
                result = device.screenshot(output)
            self.assertEqual(output.read_bytes(), original)
            self.assertFalse(result['presentationVerified'])
            self.assertEqual(scope.call_count, 2)
            self.assertEqual(execute.call_args.args[0][:3], ['adb', '-s', 'serial:5555'])
            self.assertEqual(execute.call_args.args[0][-2:], ['-d', '4630946872173396372'])

    def test_marker_timeout_leaves_no_stale_image(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'shot.png'
            fresh = Path(directory)/'fresh.png'
            write_marker_png(fresh, 0xa00002a5)
            output.write_bytes(b'older success')
            output.with_name('shot.failed-device.png').write_bytes(b'older failure')
            probe = {'token': 43, 'rect': {'x': 8, 'y': 8, 'width': 128, 'height': 8},
                     'pixelRatio': 2, 'native': {'viewBounds': {'x': 10, 'y': 20, 'width': 300, 'height': 150}}}
            device = AndroidDevice('serial', PACKAGE)
            real_run = subprocess.run
            def execute(args, **kwargs):
                # The device returns a frame with an older marker; ffmpeg still decodes it for real.
                if args[:3] == ['adb', '-s', 'serial']:
                    return SimpleNamespace(returncode=0, stdout=fresh.read_bytes())
                return real_run(args, **kwargs)
            with patch.object(device, 'require_target'), patch.object(device, 'display_id', return_value='12'), patch('android_device.adb_binary', return_value='adb'), \
                 patch('android_device.subprocess.run', side_effect=execute):
                with self.assertRaisesRegex(TimeoutError, 'never presented'):
                    device.screenshot(output, probe, seconds=0)
            self.assertFalse(output.exists())
            self.assertEqual(output.with_name('shot.failed-device.png').read_bytes(), fresh.read_bytes())
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ['fresh.png', 'shot.failed-device.png'])

    def test_panel_switch_retains_failed_frame_without_publishing_a_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'shot.png'
            write_marker_png(output, 0xa00002a5)
            original = output.read_bytes()
            device = AndroidDevice('fold', PACKAGE)
            with patch.object(device, 'require_target'), \
                 patch.object(device, 'display_id', side_effect=['12', '34']), \
                 patch('android_device.adb_binary', return_value='adb'), \
                 patch('android_device.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout=original)):
                with self.assertRaisesRegex(RuntimeError, 'panel changed'):
                    device.screenshot(output)
            self.assertFalse(output.exists())
            self.assertEqual(output.with_name('shot.failed-device.png').read_bytes(), original)

    def test_recording_selects_the_same_panel_as_its_source_screenshot(self):
        with tempfile.TemporaryDirectory() as directory:
            device = MagicMock(serial='fold')
            device.screenshot.return_value = {'width': 1080, 'height': 2520, 'displayId': '34'}
            process = MagicMock()
            process.poll.return_value = 0
            device.command.return_value.returncode = 0
            recording = DeviceRecording(device, Path(directory)/'clip.mp4', 2)
            with patch('android_device.adb_binary', return_value='adb'), \
                 patch('android_device.subprocess.Popen', return_value=process) as launch:
                try:
                    recording.start()
                    args = launch.call_args.args[0]
                    self.assertEqual(args[args.index('--display-id') + 1], '34')
                finally:
                    recording.close()

    def test_recording_start_clears_previous_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'clip.mp4'
            stale = [output, output.with_name('clip.failed-device.mp4'), output.with_name('clip.presentation.png')]
            for path in stale:
                path.write_bytes(b'old')
            device = MagicMock()
            device.require_target.side_effect = RuntimeError('not resumed')
            with self.assertRaisesRegex(RuntimeError, 'not resumed'):
                DeviceRecording(device, output, 2).start()
            self.assertFalse(any(path.exists() for path in stale))

    def test_wrong_foreground_app_prevents_capture(self):
        device = AndroidDevice('serial', PACKAGE)
        with patch.object(device, 'ready'), patch.object(device, 'resumed', return_value=False), \
             patch('android_device.subprocess.run') as execute:
            with self.assertRaisesRegex(RuntimeError, 'not resumed'):
                device.screenshot('unused.png')
            execute.assert_not_called()

    def test_recording_rejects_unbounded_duration_and_invalid_targets(self):
        for serial in ('', '-s', 'multiple devices'):
            with self.assertRaises(ValueError): AndroidDevice(serial, PACKAGE)
        with self.assertRaises(ValueError): AndroidDevice('serial', PACKAGE+';other')
        with self.assertRaises(ValueError): DeviceRecording(AndroidDevice('serial', PACKAGE), 'unused.mp4', 0)


class CliTests(unittest.TestCase):
    def test_android_never_auto_selects_a_device(self):
        with self.assertRaises(SystemExit): main(['--platform', 'android', 'state'])

    def test_existing_windows_driver_flag_reaches_adapter(self):
        with patch('windows_platform.main') as legacy:
            main(['drive', 'tap', 'animation-play', '--no-settle'])
            legacy.assert_called_once()


class AcceptanceTests(unittest.TestCase):
    def test_interrupt_after_each_group_has_evidence_cannot_pass(self):
        from verify_android import verify
        with tempfile.TemporaryDirectory() as directory:
            platform = MagicMock()
            platform.serial = 'serial'
            platform.store = SessionStore('android', 'serial', root=directory)
            platform.start.return_value = {'capabilities': {'foregroundSimulation': False}, 'pretendForeground': False}
            client = platform.client.return_value
            current = {'view': {'width': 360, 'height': 800}, 'clicks': 0, 'scrollOffset': 0}
            def drive(action, *arguments):
                if action == 'text': raise KeyboardInterrupt()
                if action == 'tap' and arguments[0] == 'tile-0': current['clicks'] += 1
                if action == 'scroll': current['scrollOffset'] = 350
                return dict(current)
            client.drive.side_effect = drive
            client.screenshot.return_value = {'settled': True, 'path': 'app.png', 'width': 360, 'height': 800,
                                              'contentRect': {'x': 0, 'y': 20, 'width': 360, 'height': 700}}
            platform.screenshot.return_value = {'path': 'device.png', 'presentationVerified': True,
                                                'probe': {'native': {'viewBounds': {'x': 0, 'y': 0}}}}
            with patch('verify_android.image_pixels', return_value=bytes(range(256))*3), \
                 patch('builtins.print'):
                with self.assertRaises(KeyboardInterrupt): verify(platform)
            report = json.loads(next(platform.store.directory.glob('run-*/report.json')).read_text())
            self.assertEqual({c['group'] for c in report['checks']}, {'functional', 'appCapture', 'deviceCapture', 'lifecycle'})
            self.assertFalse(report['completed'])
            self.assertFalse(report['passed'])
            platform.stop.assert_called_once()

    def test_device_capture_failure_does_not_hide_functional_results(self):
        from verify_android import verify
        with tempfile.TemporaryDirectory() as directory:
            platform = MagicMock()
            platform.serial = 'serial'
            platform.store = SessionStore('android', 'serial', root=directory)
            platform.start.return_value = {'capabilities': {'foregroundSimulation': False}, 'pretendForeground': False}
            client = platform.client.return_value
            current = {'view': {'width': 360, 'height': 800}, 'clicks': 0, 'scrollOffset': 0}
            def drive(action, *arguments):
                if action == 'text': raise KeyboardInterrupt()
                if action == 'tap' and arguments[0] == 'tile-0': current['clicks'] += 1
                if action == 'scroll': current['scrollOffset'] = 350
                return dict(current)
            client.drive.side_effect = drive
            client.screenshot.return_value = {'settled': True, 'path': 'app.png', 'width': 360, 'height': 800,
                                              'contentRect': {'x': 0, 'y': 20, 'width': 360, 'height': 700}}
            platform.screenshot.side_effect = TimeoutError('Device never presented marker 7')
            with patch('builtins.print'):
                with self.assertRaises(KeyboardInterrupt): verify(platform)
            report = json.loads(next(platform.store.directory.glob('run-*/report.json')).read_text())
            checks = {c['name']: c for c in report['checks']}
            # The overview device shot failed, yet the gallery interaction still ran.
            self.assertFalse(checks['overview: device screenshot presented']['passed'])
            self.assertEqual(checks['overview: device screenshot presented']['group'], 'deviceCapture')
            self.assertTrue(checks['gallery click and scroll reach handlers']['passed'])
            self.assertFalse(checks['gallery: device screenshot presented']['passed'])
            self.assertFalse(report['deviceCapturePassed'])
            self.assertFalse(report['passed'])


if __name__ == '__main__': unittest.main()
