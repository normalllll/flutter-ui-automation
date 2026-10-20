"""Low-cost checks for target scoping and recording protocol validation."""
import unittest
import queue
import json
import tempfile
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from pathlib import Path

from window_capture import (Recording, validate_target, capture_png, CaptureError,
                            parse_probe, probe_arguments)


class WindowCaptureTests(unittest.TestCase):
    def test_invalid_handle_is_rejected_before_capture(self):
        with self.assertRaisesRegex(ValueError, "Invalid window handle"):
            validate_target(0, 1234)

    def test_failed_target_validation_does_not_launch_capture(self):
        recording = Recording(Path('unused.mp4'), hwnd=1, process_id=2,
                              helper=Path('unused.exe'))
        with patch('window_capture.validate_target', side_effect=ValueError('wrong PID')):
            with patch('window_capture.subprocess.Popen') as process:
                with self.assertRaisesRegex(ValueError, 'wrong PID'):
                    recording.start()
                process.assert_not_called()

    def test_invalid_first_frame_metadata_stops_owned_capture(self):
        recording = Recording(Path('unused.mp4'), hwnd=1, process_id=2,
                              helper=Path('unused.exe'))
        with patch('window_capture.validate_target'):
            with patch('window_capture.subprocess.Popen') as spawn:
                process = spawn.return_value
                process.stderr.readline.return_value = b'not-json\n'
                with self.assertRaisesRegex(RuntimeError, 'did not start'):
                    recording.start()
                process.kill.assert_called_once()
                process.wait.assert_called_once()
                spawn.assert_called_once()

    def test_first_frame_timeout_stops_owned_capture(self):
        recording = Recording(Path('unused.mp4'), hwnd=1, process_id=2,
                              helper=Path('unused.exe'))
        with patch('window_capture.validate_target'):
            with patch('window_capture.subprocess.Popen') as spawn:
                with patch('window_capture.queue.Queue') as queues:
                    queues.return_value.get.side_effect = queue.Empty
                    with self.assertRaisesRegex(TimeoutError, '15 seconds'):
                        recording.start()
                spawn.return_value.kill.assert_called_once()
                spawn.return_value.wait.assert_called_once()

    def test_strict_capture_retains_failure_diagnostics_without_success(self):
        details = {'error': 'capture_not_presented', 'message': 'Timed out waiting for the requested presented frame',
                   'probeMatched': False, 'diagnosticOnly': True,
                   'frame': {'frameStatus': 'uniform_client'},
                   'environment': {'displayState': 'off'}}
        probe = {'token': 1, 'pixelRatio': 1.5,
                 'rect': {'x': 10, 'y': 20, 'width': 128, 'height': 8}}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'window.png'
            with patch('window_capture.validate_target'):
                with patch('window_capture.subprocess.run') as run:
                    run.return_value.returncode = 1
                    run.return_value.stderr = json.dumps(details)
                    with self.assertRaises(CaptureError) as raised:
                        capture_png(output, hwnd=1, process_id=2, probe=probe)
                    self.assertEqual(raised.exception.diagnostics, details)
                    self.assertFalse(output.exists())
                    args = run.call_args.args[0]
                    self.assertIn('--probe', args)
                    self.assertIn('--diagnostic-png', args)
                    self.assertIn(str(output.with_name('window.failed-native.png')), args)

    def test_recording_retains_structured_start_failure_before_encoding(self):
        details = {'error': 'capture_not_presented', 'message': 'Not presented',
                   'probeMatched': False, 'environment': {'displayState': 'off'}}
        recording = Recording(Path('unused.mp4'), hwnd=1, process_id=2,
                              helper=Path('unused.exe'))
        with patch('window_capture.validate_target'):
            with patch('window_capture.subprocess.Popen') as spawn:
                process = spawn.return_value
                process.stderr.readline.return_value = json.dumps(details).encode() + b'\n'
                with self.assertRaises(CaptureError) as raised:
                    recording.start()
                self.assertEqual(raised.exception.diagnostics, details)
                self.assertIsNone(recording.encoder)
                process.kill.assert_called_once()
                process.wait.assert_called_once()
                spawn.assert_called_once()

    def test_failed_capture_removes_stale_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'window.png'
            diagnostic = output.with_name('window.failed-native.png')
            output.write_bytes(b'old success')
            diagnostic.write_bytes(b'old failure')
            with patch('window_capture.validate_target'):
                with patch('window_capture.subprocess.run') as run:
                    run.return_value.returncode = 1
                    run.return_value.stderr = 'PrintWindow failed'
                    with self.assertRaises(CaptureError):
                        capture_png(output, hwnd=1, process_id=2)
            self.assertFalse(output.exists())
            self.assertFalse(diagnostic.exists())
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_successful_capture_is_published_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'window.png'
            def helper(args, **_):
                Path(args[args.index('--png') + 1]).write_bytes(b'new frame')
                return SimpleNamespace(returncode=0, stdout='{"width": 1}', stderr='')
            with patch('window_capture.validate_target'):
                with patch('window_capture.subprocess.run', side_effect=helper) as run:
                    result = capture_png(output, hwnd=1, process_id=2)
            self.assertNotEqual(run.call_args.args[0][run.call_args.args[0].index('--png') + 1], str(output))
            self.assertEqual(output.read_bytes(), b'new frame')
            self.assertFalse(result['presentationVerified'])
            self.assertEqual(list(Path(directory).iterdir()), [output])

    def test_cli_probe_forms(self):
        self.assertIsNone(parse_probe())
        probe = parse_probe(['7', '10', '20', '192', '12'])
        self.assertEqual(probe_arguments(probe), ['--probe', '7', '10.0', '20.0', '192.0', '12.0'])
        with tempfile.TemporaryDirectory() as directory:
            hook = Path(directory)/'probe.json'
            hook.write_text(json.dumps({'token': 3, 'pixelRatio': 1.5,
                'rect': {'x': 2, 'y': 4, 'width': 128, 'height': 8}}), encoding='utf-8')
            self.assertEqual(probe_arguments(parse_probe(json_path=hook)),
                             ['--probe', '3', '3.0', '6.0', '192.0', '12.0'])
            hook.write_text('{"token": 3}', encoding='utf-8')
            with self.assertRaises(ValueError):
                parse_probe(json_path=hook)
        with self.assertRaises(ValueError):
            parse_probe(['1', '0', '0', '1', '1'], 'probe.json')

    def test_recording_without_completion_metadata_fails_clearly(self):
        recording = Recording(Path('unused.mp4'), hwnd=1, process_id=2, helper=Path('unused.exe'))
        recording.capture = MagicMock(**{'wait.return_value': 0, 'poll.return_value': 0})
        recording.capture.stderr.read.return_value = b''
        recording.encoder = MagicMock(**{'wait.return_value': 0, 'poll.return_value': 0})
        with self.assertRaisesRegex(RuntimeError, 'without completion metadata'):
            recording.finish()

    def test_legacy_helper_error_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch('window_capture.validate_target'):
                with patch('window_capture.subprocess.run') as run:
                    run.return_value.returncode = 1
                    run.return_value.stderr = 'WGC error: target unavailable'
                    with self.assertRaisesRegex(CaptureError, 'target unavailable') as raised:
                        capture_png(Path(directory)/'window.png', hwnd=1, process_id=2)
                    self.assertEqual(raised.exception.diagnostics, {})


if __name__ == '__main__':
    unittest.main()
