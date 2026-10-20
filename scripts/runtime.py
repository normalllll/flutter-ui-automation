"""Host commands shared by platform adapters; never use desktop input."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'examples/capture_lab'
NO_WINDOW = 0x08000000 if os.name == 'nt' else 0


def program(name):
    binary = shutil.which(name)
    if not binary:
        raise RuntimeError(f'Missing {name}; add it to PATH')
    return binary


def dart():
    binary = Path(program('flutter')).resolve().parent / 'cache/dart-sdk/bin' / (
        'dart.exe' if os.name == 'nt' else 'dart')
    if not binary.is_file():
        raise RuntimeError(f'Flutter Dart executable not found: {binary}')
    return str(binary)


def run(args, *, cwd=ROOT, timeout=60, check=True):
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True,
                            text=True, encoding='utf-8', errors='replace',
                            timeout=timeout, creationflags=NO_WINDOW)
    if check and result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {args[0]}\n'
                           f'{result.stdout[-4000:]}\n{result.stderr[-4000:]}')
    return result


def last_json(output):
    for line in reversed(output.splitlines()):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    raise RuntimeError(f'No JSON response: {output[-2000:]}')


def timing_ok(notes, expected_ms, frames):
    return (abs(notes.get('elapsedMs', -1) - expected_ms) <= max(500, expected_ms * .05)
            and notes.get('lateFrames', frames) <= max(1, frames * .05))


def wait_until(observe, accepts, *, seconds=10, description='condition'):
    deadline = time.monotonic() + seconds
    while True:
        value = observe()
        if accepts(value):
            return value
        if time.monotonic() >= deadline:
            raise TimeoutError(f'Timed out waiting for {description}: {value}')
        time.sleep(.15)
