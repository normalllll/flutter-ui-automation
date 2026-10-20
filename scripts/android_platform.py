"""Fixture device sessions. Flutter owns launch/port forwarding and app.stop."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import threading
import time

from android_device import AndroidDevice, DeviceRecording
from flutter_client import FlutterClient
from host_process import process_identity, same_process
from runtime import APP, ROOT, NO_WINDOW, program, run, wait_until
from sessions import SessionStore

PACKAGE = 'dev.flutter.flutter_capture_lab'


class AndroidPlatform:
    def __init__(self, serial, name='default'):
        self.serial, self.name = serial, name
        self.store = SessionStore('android', serial, name)
        self.device = AndroidDevice(serial, PACKAGE)

    def session(self):
        data = self.store.read()
        if data.get('deviceId') != self.serial or data.get('package') != PACKAGE:
            raise RuntimeError('Session does not belong to this device/package')
        if not data.get('vmUri'):
            raise RuntimeError('Session is not connected; run start or attach first')
        if data.get('owned') and not same_process(data.get('supervisor')):
            raise RuntimeError('Session supervisor exited; run stop for scoped recovery')
        self.device.ready()
        return data

    def client(self):
        return FlutterClient(self.session()['vmUri'])

    def _validate_app(self, state):
        if state.get('native', {}).get('package') != PACKAGE:
            raise RuntimeError('VM connection is not the Android fixture package')
        if not state.get('capabilities', {}).get('appScreenshot'):
            raise RuntimeError('Fixture capture hooks are missing from this test entrypoint')
        token = self.device.command('shell', 'run-as', PACKAGE, 'cat', 'files/capture-instance').stdout.strip()
        if not token or token != state['native'].get('instanceToken'):
            raise RuntimeError('VM connection does not belong to the selected device instance')
        return state

    def start(self):
        previous = self.store.read()
        if previous.get('vmUri'):
            return self._validate_app(self.client().drive('state'))
        self.device.ready()
        if self.device.process_identity():
            raise RuntimeError('Fixture already runs on this device. Attach using its VM URI, or stop that instance explicitly.')
        with self.store.launching(release_on_error=False):
            self.store.stop_path.unlink(missing_ok=True)
            self.store.write({'platform': 'android', 'deviceId': self.serial, 'package': PACKAGE,
                              'owned': True, 'starting': True, 'vmUri': None})
            with (self.store.directory / 'supervisor.log').open('w', encoding='utf-8') as log:
                supervisor = subprocess.Popen([sys.executable, str(ROOT/'scripts/lab.py'),
                                               '--platform', 'android', '--device', self.serial,
                                               '--session', self.name, 'serve'],
                                              stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                              cwd=ROOT, creationflags=NO_WINDOW)
            try:
                def observe():
                    data = self.store.read()
                    if 'exitCode' in data or supervisor.poll() is not None:
                        raise RuntimeError(f'Android launch failed; inspect {self.store.directory}')
                    return data
                wait_until(observe, lambda d: bool(d.get('vmUri')), seconds=180,
                           description='Flutter Android VM service')
                state = wait_until(lambda: self.client().drive('state'),
                                   lambda s: s.get('native', {}).get('package') == PACKAGE,
                                   seconds=20, description='Android fixture initialization')
                return self._validate_app(state)
            except BaseException:
                self.store.stop_path.touch()
                # Preserve the lease until the supervisor has stopped its app.
                try:
                    supervisor.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f'Launch cleanup pending; inspect {self.store.directory}') from None
                raise

    def serve(self):
        data = self.store.read()
        if not data.get('starting') or data.get('deviceId') != self.serial:
            raise RuntimeError('No owned launch reservation')
        data.update({'supervisor': process_identity(__import__('os').getpid()), 'owned': True})
        self.store.write(data)
        process = None
        try:
            process = subprocess.Popen([program('flutter'), 'run', '--machine', '-d', self.serial,
                                        '-t', 'lib/android_driver_main.dart', '--no-pub'],
                                       cwd=APP, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                       errors='replace', creationflags=NO_WINDOW)
            data['flutterProcess'] = process_identity(process.pid)
            self.store.write(data)

            def watch_stop():
                while process.poll() is None:
                    if self.store.stop_path.exists():
                        try:
                            request = ({'id': 1, 'method': 'app.stop', 'params': {'appId': data['appId']}}
                                       if data.get('appId') else {'id': 1, 'method': 'daemon.shutdown'})
                            process.stdin.write(json.dumps([request])+'\n')
                            process.stdin.flush()
                        except (OSError, ValueError):
                            pass
                        return
                    time.sleep(.15)
            threading.Thread(target=watch_stop, daemon=True).start()
            with (self.store.directory/'flutter-run.log').open('w', encoding='utf-8') as log:
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    try:
                        events = json.loads(line)
                        for event in events if isinstance(events, list) else []:
                            params = event.get('params', {})
                            if event.get('event') == 'app.start':
                                data['appId'] = params['appId']
                            elif event.get('event') == 'app.debugPort':
                                data.update({'vmUri': params['wsUri'], 'starting': False})
                                data['appProcess'] = self.device.process_identity()
                            self.store.write(data)
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue
            return process.wait()
        finally:
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            data.update({'vmUri': None, 'starting': False,
                         'exitCode': process.poll() if process else -1})
            self.store.write(data)
            # Keep the device leased if an owned app survived the supervisor.
            try:
                if not self.device.process_identity():
                    self.store.release()
            except Exception as error:
                data['cleanupError'] = str(error)
                self.store.write(data)

    def attach(self, vm_uri):
        self.device.require_target()
        client = FlutterClient(vm_uri)
        state = self._validate_app(client.drive('state'))
        with self.store.launching():
            self.store.write({'platform': 'android', 'deviceId': self.serial, 'package': PACKAGE,
                              'owned': False, 'vmUri': vm_uri, 'starting': False})
        return state

    def stop(self):
        data = self.store.read()
        if not data:
            self.store.release()
            return {'stopped': True}
        if data.get('deviceId') != self.serial or data.get('package') != PACKAGE:
            raise RuntimeError('Refusing to stop a mismatched session')
        if not data.get('owned'):
            self.store.write({**data, 'vmUri': None, 'starting': False})
            self.store.release()
            return {'stopped': True, 'detached': True, 'appStopped': False}
        if same_process(data.get('supervisor')):
            self.store.stop_path.touch()
            wait_until(self.store.read, lambda s: 'exitCode' in s and not s.get('vmUri'),
                       seconds=35, description='owned Flutter session shutdown')
        self.device.ready()
        current = self.device.process_identity()
        if current:
            recorded = data.get('appProcess')
            if not recorded or not recorded.get('startTicks') or recorded != current:
                raise RuntimeError('App identity changed or cannot be proven; session retained for explicit cleanup')
            self.device.command('shell', 'am', 'force-stop', PACKAGE)
            wait_until(self.device.process_identity, lambda p: p is None, description='owned app process exit')
        self.store.write({**self.store.read(), 'vmUri': None, 'starting': False, 'stopped': True})
        self.store.release()
        return {'stopped': True, 'appStopped': bool(current)}

    def screenshot(self, path):
        client = self.client()
        self.device.require_target()
        probe = client.prepare_capture()
        return {**self.device.screenshot(path, probe), 'probe': probe}

    def recording(self, path, seconds=8):
        self.session()
        probe = self.client().prepare_capture(seconds * 1000 + 15000, settle=False)
        return DeviceRecording(self.device, path, seconds, probe=probe)

    def rotate(self, orientation):
        if orientation not in ('portrait', 'landscape', 'restore'):
            raise ValueError('Use portrait, landscape or restore')
        self.device.require_target()
        return self.client().drive('orientation', orientation)
