"""Flutter fixture CLI: Windows compatibility plus explicit Android device sessions."""
import argparse
import json
import os
from pathlib import Path
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['windows', 'android'], default='windows')
    parser.add_argument('--device', help='Required ADB serial for Android (never auto-select)')
    parser.add_argument('--session', default='default')
    parser.add_argument('--vm-uri', help='Reachable VM Service URL for attach')
    parser.add_argument('--fps', type=int, help='Android app-record/verify PNG sample rate, 1..15 (default 2)')
    parser.add_argument('action', choices=['devices', 'build', 'start', 'attach', 'stop', 'state',
                                         'drive', 'app-shot', 'device-shot', 'window-shot',
                                         'record', 'device-record', 'app-record', 'back',
                                         'background', 'resume', 'rotate', 'verify', 'verify-cold', 'serve'])
    parser.add_argument('arguments', nargs='*')
    args, extras = parser.parse_known_args(argv)
    if extras and (args.action != 'drive' or extras != ['--no-settle']):
        parser.error(f'Unrecognized arguments: {extras}')
    args.arguments += extras
    if args.fps is not None and (not 1 <= args.fps <= 15 or args.action not in ('app-record', 'verify') or args.platform != 'android'):
        parser.error('--fps 1..15 applies to Android app-record/verify only')
    if args.platform == 'windows':
        if os.name != 'nt': parser.error('Windows target requires a Windows host')
        if args.device or args.session != 'default' or args.vm_uri:
            parser.error('Windows compatibility mode uses its existing default session')
        import windows_platform
        action = {'device-shot': 'window-shot', 'device-record': 'record'}.get(args.action, args.action)
        if action == 'app-shot':
            from flutter_client import FlutterClient
            result = FlutterClient(windows_platform.session()['vmUri']).screenshot(args.arguments[0])
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return result
        original = sys.argv
        try:
            sys.argv = [original[0], action, *args.arguments]
            return windows_platform.main()
        finally:
            sys.argv = original
    from android_device import devices
    if args.action == 'devices': result = devices()
    else:
        if not args.device: parser.error('--device ADB_SERIAL is required for Android')
        from android_platform import AndroidPlatform
        platform = AndroidPlatform(args.device, args.session)
        action = args.action
        if action == 'serve': return platform.serve()
        if action == 'build':
            from runtime import APP, program, run
            result = run([program('flutter'), 'build', 'apk', '--debug', '-t',
                          'lib/android_driver_main.dart'], cwd=APP, timeout=600)
            print(result.stdout)
            return
        if action == 'start': result = platform.start()
        elif action == 'attach':
            if not args.vm_uri: parser.error('attach requires --vm-uri')
            result = platform.attach(args.vm_uri)
        elif action == 'stop': result = platform.stop()
        elif action == 'state': result = platform.client().drive('state')
        elif action == 'drive': result = platform.client().drive(*args.arguments)
        elif action == 'app-shot': result = platform.client().screenshot(args.arguments[0])
        elif action == 'device-shot': result = platform.screenshot(args.arguments[0])
        elif action == 'app-record': result = platform.client().record(args.arguments[0], int(args.arguments[1]) if len(args.arguments) > 1 else 8, fps=args.fps or 2)
        elif action in ('record', 'device-record'):
            recording = platform.recording(args.arguments[0], int(args.arguments[1]) if len(args.arguments) > 1 else 8)
            recording.start()
            result = recording.finish()
        elif action in ('back', 'background', 'resume'):
            platform.session()
            getattr(platform.device, action)()
            result = {'action': action, 'deviceId': args.device, 'complete': True}
        elif action == 'rotate': result = platform.rotate(*args.arguments)
        elif action == 'verify':
            from verify_android import verify
            result = verify(platform, app_fps=args.fps or 2)
            if not result['passed']:
                print(json.dumps({'passed': False, 'error': result.get('error'),
                                  'report': str(Path(result['output']) / 'report.json')},
                                 ensure_ascii=False, indent=2))
                raise SystemExit(1)
        else: parser.error(f'{action} is not an Android capability')
    print(result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, indent=2))
    return result
