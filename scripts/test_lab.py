"""Low-cost checks for session durability, stale-session recovery and timing checks."""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import windows_platform as lab


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.patches = [patch.object(lab, 'SESSION', root/'session.json'),
                        patch.object(lab, 'APP_INSTANCE', root/'app-instance.json'),
                        patch.object(lab, 'STOP', root/'stop.request')]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in self.patches:
            item.stop()
        self.directory.cleanup()

    def test_save_waits_for_a_reader_holding_the_session(self):
        lab.save_session({'vmUri': 'old'})
        reader = lab.SESSION.open('r', encoding='utf-8')
        threading.Timer(0.2, reader.close).start()
        lab.save_session({'vmUri': None, 'exitCode': 0})
        self.assertEqual(lab.read_session(), {'vmUri': None, 'exitCode': 0})

    def test_identity_matches_only_the_same_live_process(self):
        identity = lab.process_identity(os.getpid())
        self.assertTrue(lab.same_process(identity))
        self.assertFalse(lab.same_process({**identity, 'created': identity['created'] + 1}))
        self.assertIsNone(lab.process_identity(0))

    def test_stop_recovers_when_supervisor_is_gone(self):
        lab.save_session({'vmUri': 'ws://127.0.0.1:1/ws', 'supervisor': {'pid': 1, 'image': 'x', 'created': 1}})
        lab.APP_INSTANCE.write_text(json.dumps({'pid': 1, 'image': 'x', 'created': 1}), encoding='utf-8')
        started = time.monotonic()
        result = lab.stop()
        self.assertLess(time.monotonic() - started, 5)
        self.assertTrue(result['staleSession'])
        self.assertFalse(result['closedApp'])
        self.assertIsNone(lab.read_session()['vmUri'])
        self.assertFalse(lab.APP_INSTANCE.exists())

    def test_stale_recovery_never_closes_an_unrelated_process(self):
        identity = lab.process_identity(os.getpid())  # this Python, not the fixture executable
        lab.APP_INSTANCE.write_text(json.dumps({**identity, 'hwnd': 0}), encoding='utf-8')
        result = lab.recover_stale({'vmUri': 'ws://stale'})
        # Reaching this line means this live process was neither closed nor terminated.
        self.assertFalse(result['closedApp'])
        self.assertNotIn('terminatedApp', result)
        self.assertTrue(lab.same_process(identity))


class TimingTests(unittest.TestCase):
    def test_wall_clock_pacing(self):
        self.assertTrue(lab.timing_ok({'elapsedMs': 8040, 'lateFrames': 1}, 8000, 40))
        self.assertFalse(lab.timing_ok({'elapsedMs': 16000, 'lateFrames': 0}, 8000, 40))
        self.assertFalse(lab.timing_ok({'elapsedMs': 8000, 'lateFrames': 12}, 8000, 40))
        self.assertFalse(lab.timing_ok({}, 8000, 40))


if __name__ == '__main__':
    unittest.main()
