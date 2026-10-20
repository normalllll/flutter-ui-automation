"""Atomic, named device sessions with a per-target launch lease."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import time

from runtime import ROOT


def target_key(platform, device, name='default'):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', name):
        raise ValueError('Session name must be 1..64 letters, digits, underscores or hyphens')
    digest = hashlib.sha256(device.encode()).hexdigest()[:16]
    return f'{platform}-{digest}-{name}'


class SessionStore:
    def __init__(self, platform, device, name='default', root=None):
        self.directory = Path(root or ROOT / 'artifacts/sessions') / target_key(platform, device, name)
        self.path = self.directory / 'session.json'
        self.stop_path = self.directory / 'stop.request'
        # All named sessions for one device share a lease: the fixture package is one app.
        self.lease = self.directory.parent / (target_key(platform, device) + '.lock')

    def read(self):
        try:
            return json.loads(self.path.read_text(encoding='utf-8'))
        except FileNotFoundError:
            return {}

    def write(self, data):
        self.directory.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(f'.{os.getpid()}.tmp')
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        for attempt in range(100):
            try:
                temporary.replace(self.path)
                return
            except PermissionError:
                if attempt == 99:
                    raise
                time.sleep(.02)

    @contextmanager
    def launching(self, release_on_error=True):
        self.directory.mkdir(parents=True, exist_ok=True)
        try:
            self.lease.mkdir()
        except FileExistsError:
            raise RuntimeError(f'Device already leased: {self.lease}. Stop its owner session first.') from None
        try:
            (self.lease / 'owner.json').write_text(json.dumps({'session': str(self.path)}), encoding='utf-8')
            yield
        except BaseException:
            if release_on_error:
                self.release()
            raise

    def release(self):
        owner = self.lease / 'owner.json'
        if owner.is_file() and json.loads(owner.read_text(encoding='utf-8')).get('session') == str(self.path):
            owner.unlink()
            self.lease.rmdir()
