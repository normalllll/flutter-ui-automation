"""Focus changes are observations; actual capture and restoration faults still fail."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from windows_evidence import ForegroundEvidence, finish_report
import verify_scenarios


def snapshot(*, focused=False, activations=0, ticks=10):
    lifecycle = 'resumed' if focused else 'inactive'
    focus = 'focused' if focused else 'unfocused'
    return {
        'pretendForeground': False, 'rawLifecycle': lifecycle,
        'effectiveLifecycle': lifecycle, 'rawViewFocus': focus,
        'effectiveViewFocus': focus, 'foregroundTicks': ticks,
        'native': {'isForeground': focused, 'hasNativeFocus': focused,
                   'activationCount': activations, 'isBelowForeground': not focused,
                   'topmost': False},
    }


class ForegroundEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.report = {'checks': []}
        self.evidence = ForegroundEvidence(self.report)

    def check(self, name, passed, detail=None, *, group='functional'):
        self.report['checks'].append({'name': name, 'passed': bool(passed), 'group': group})
        if not passed and group == 'functional':
            raise AssertionError(name)

    def test_foreground_state_and_video_samples_do_not_reject_valid_captures(self):
        self.evidence.state('user-inspection', snapshot(focused=True, activations=3))
        self.evidence.recording('video', {'foregroundSamples': 24})
        self.check('functional result', True)
        self.check('fresh lossless capture', True, group='native')
        finish_report(self.report, None)
        self.assertTrue(self.report['passed'])
        self.assertEqual(self.report['foregroundObservations'][0]['activationCount'], 3)
        self.assertEqual(self.report['foregroundObservations'][1]['foregroundSamples'], 24)
        self.assertEqual(self.report['foregroundPolicy']['activationAttribution'], 'unknown')

    def test_foreground_interval_is_not_claimed_as_background_coverage(self):
        before = snapshot()
        after = snapshot(focused=True, activations=1, ticks=20)
        self.evidence.background_activity('background counter', before, after, self.check)
        self.assertEqual(self.report['checks'], [])
        self.assertEqual(self.report['foregroundChecks'][0]['status'], 'not_assessed')
        self.assertIsNone(self.report['foregroundChecks'][0]['passed'])

    def test_activation_and_return_between_samples_is_not_background_coverage(self):
        self.evidence.background_activity(
            'background counter', snapshot(), snapshot(activations=1, ticks=15), self.check)
        self.assertEqual(self.report['checks'], [])
        self.assertEqual(self.report['foregroundChecks'][0]['status'], 'not_assessed')

    def test_unknown_activation_history_is_not_background_coverage(self):
        before = snapshot()
        del before['native']['activationCount']
        self.evidence.background_activity('background counter', before, snapshot(), self.check)
        self.assertEqual(self.report['foregroundChecks'][0]['status'], 'not_assessed')

    def test_uninterrupted_background_counter_is_still_checked(self):
        self.evidence.background_activity('background counter', snapshot(), snapshot(), self.check)
        self.assertTrue(self.report['checks'][0]['passed'])
        with self.assertRaisesRegex(AssertionError, 'background regression'):
            self.evidence.background_activity(
                'background regression', snapshot(), snapshot(ticks=11), self.check)

    def test_restoration_accepts_latest_real_focused_state(self):
        self.evidence.restoration(snapshot(focused=True, activations=1), self.check)
        self.assertEqual(len(self.report['checks']), 2)
        self.assertTrue(all(item['passed'] for item in self.report['checks']))

    def test_restoration_rejects_wrong_focus_instead_of_always_accepting_it(self):
        wrong = snapshot(focused=True)
        wrong['effectiveViewFocus'] = 'unfocused'
        with self.assertRaisesRegex(AssertionError, 'latest real view focus'):
            self.evidence.restoration(wrong, self.check)

    def test_old_fixture_focus_restoration_is_explicitly_unassessed(self):
        old = snapshot(focused=True)
        del old['rawViewFocus']
        self.evidence.restoration(old, self.check)
        self.assertEqual(len(self.report['checks']), 1)
        self.assertEqual(self.report['foregroundChecks'][0]['status'], 'not_assessed')

    def test_focus_observations_do_not_hide_native_failure_or_interruption(self):
        self.evidence.recording('video', {'foregroundSamples': 20})
        self.check('functional', True)
        self.check('stale frame', False, group='native')
        finish_report(self.report, None)
        self.assertTrue(self.report['functionalPassed'])
        self.assertFalse(self.report['nativeCapturePassed'])
        self.assertFalse(self.report['passed'])
        self.report['checks'][-1]['passed'] = True
        finish_report(self.report, RuntimeError('interrupted'))
        self.assertFalse(self.report['functionalPassed'])
        self.assertFalse(self.report['nativeCapturePassed'])


class ColdVerificationTests(unittest.TestCase):
    def test_cold_capture_batch_allows_inspection_and_retains_focus_evidence(self):
        initial = snapshot(focused=True, activations=2)
        initial['native'].update({
            'hwnd': 1, 'pid': 2, 'monitorPrimary': True, 'monitorCount': 1,
            'windowBounds': {'left': 0, 'top': 0, 'right': 100, 'bottom': 100},
            'monitorWorkArea': {'left': 0, 'top': 0, 'right': 200, 'bottom': 200},
        })
        page = 'overview'
        token = 0

        def drive(action, *arguments):
            nonlocal page, token
            if action == 'tap':
                page = arguments[0].removeprefix('nav-')
            if action == 'app-shot':
                return {'path': arguments[0]}
            if action == 'prepare-capture':
                token += 1
                return {'token': token, 'native': initial['native'], 'pixelRatio': 1,
                        'rect': {'x': 0, 'y': 0, 'width': 128, 'height': 8}}
            return {**deepcopy(initial), 'page': page}

        process = MagicMock()
        process.poll.side_effect = [None, 0]
        process.returncode = 0
        process.communicate.return_value = (json.dumps({
            'probeMatched': True, 'firstFrameWaitMs': 300, 'rejectedFrames': 1}), '')
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(verify_scenarios.lab, 'ARTIFACTS', Path(directory)), \
                 patch.object(verify_scenarios.lab, 'start', return_value=initial), \
                 patch.object(verify_scenarios.lab, 'stop'), \
                 patch.object(verify_scenarios.lab, 'drive', side_effect=drive), \
                 patch.object(verify_scenarios.lab, 'capture_binary', return_value='capture.exe'), \
                 patch.object(verify_scenarios.lab, 'window_shot', side_effect=lambda path: {
                     'path': str(path), 'probeMatched': True}), \
                 patch.object(verify_scenarios, 'compare_capture', return_value={
                     'meanPixelDifference': 0, 'windowContentStdDev': 30}), \
                 patch.object(verify_scenarios, 'capture_png', side_effect=RuntimeError(
                     'Timed out waiting for the requested presented frame')), \
                 patch.object(verify_scenarios.subprocess, 'Popen', return_value=process), \
                 patch.object(verify_scenarios.time, 'sleep'), \
                 patch.dict(verify_scenarios.os.environ):
                report = verify_scenarios.verify_cold(1)
        self.assertTrue(report['passed'])
        self.assertEqual(len(report['cycles'][0]['captures']), 4)
        self.assertTrue(all(item['isForeground'] for item in report['foregroundObservations']))
        self.assertTrue(report['cycles'][0]['presentationFence']['probeMatched'])
        self.assertTrue(report['cycles'][0]['missingFrameTimeout']['passed'])


if __name__ == '__main__':
    unittest.main()
