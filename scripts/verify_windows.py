"""Windows acceptance; platform lifecycle/capture lives in windows_platform."""
import json
from pathlib import Path
import statistics
import subprocess
import time
import traceback
import windows_platform as lab

def verify():
    lab.start()
    output = lab.ARTIFACTS / time.strftime("run-%Y%m%d-%H%M%S")
    output.mkdir()
    report = {"output": str(output), "renderer": lab.session().get("renderer", "default"), "checks": [], "snapshots": {}, "captures": {}}

    def check(name, passed, detail=None, *, group="functional"):
        # Functional failures stop the run; native capture failures are recorded
        # and the app-level checks continue.
        report["checks"].append({"name": name, "passed": bool(passed), "detail": detail,
                                 "group": group, "required": group == "functional"})
        print(f"{'PASS' if passed else 'FAIL'}: {name}", flush=True)
        if not passed and group == "functional":
            raise AssertionError(f"Verification failed: {name}: {detail}")

    def native_step(name, action):
        try:
            return action()
        except lab.NATIVE_ERRORS as error:
            check(name, False, {"error": str(error),
                                "diagnostics": getattr(error, "diagnostics", None)}, group="native")
            return None

    def state(label):
        current = lab.drive("state")
        report["snapshots"][label] = current
        return current

    def shots(label):
        app = lab.drive("app-shot", str(output / f"{label}-app.png"))
        report["captures"][label] = {"app": app}
        check(f"{label} app capture taken after UI settled", app.get("settled"),
              {key: app.get(key) for key in ("settleMs", "settleFrames", "pendingTransientCallbacks")})
        probe = lab.prepare_capture()
        window = native_step(f"{label} native screenshot presented",
                             lambda: lab.window_shot(output / f"{label}-window.png", probe))
        if window is None:
            return
        report["captures"][label]["window"] = window
        check(f"{label} native screenshot presented", window["probeMatched"], group="native")
        # Ignore the title bar: it can make an otherwise blank window look valid.
        pixels = subprocess.run([lab.program("ffmpeg"), "-v", "error", "-i",
            str(output / f"{label}-window.png"), "-vf", "crop=iw*0.8:ih*0.7:iw*0.1:ih*0.2,scale=64:36",
            "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], capture_output=True,
            timeout=15, creationflags=lab.CREATE_NO_WINDOW)
        if pixels.returncode:
            raise RuntimeError(pixels.stderr.decode(errors='replace'))
        spread = statistics.pstdev(pixels.stdout)
        check(f"{label} window contains rendered content", spread > 8, {"contentStdDev": spread}, group="native")
        from verify_scenarios import compare_capture
        comparison = compare_capture(Path(app['path']), Path(window['path']), app, window)
        check(f'{label} native client matches app content', comparison['meanPixelDifference'] < 3.5,
              comparison, group="native")

    recorder = None
    error = None
    try:
        lab.drive("foreground", "off")
        lab.drive("tap", "nav-overview")
        before = state("background-mode-off")
        check("visible background HWND", before["native"]["visible"] and not before["native"]["isForeground"], before["native"])
        native = before['native']
        bounds, work = native['windowBounds'], native['monitorWorkArea']
        check('initial window is below foreground and not topmost', native['isBelowForeground'] and not native['topmost'])
        check('initial window fits selected monitor work area', bounds['left'] >= work['left']
              and bounds['top'] >= work['top'] and bounds['right'] <= work['right']
              and bounds['bottom'] <= work['bottom'])
        time.sleep(1.2)
        idle = state("background-idle")
        check("foreground-only activity stops with simulation off", idle["foregroundTicks"] == before["foregroundTicks"])
        lab.drive("tap", "foreground-switch")
        enabled = state("simulation-on")
        check("switch enables simulation", enabled["pretendForeground"])
        check("framework sees resumed and focused", enabled["effectiveLifecycle"] == "resumed" and enabled["effectiveViewFocus"] == "focused")
        check("Windows still sees background", not enabled["native"]["isForeground"] and not enabled["native"]["hasNativeFocus"])
        time.sleep(1.2)
        active = state("simulated-activity")
        check("foreground-only activity advances in background", active["foregroundTicks"] > enabled["foregroundTicks"] + 5)
        shots("overview")
        lab.drive("tap", "nav-gallery")
        lab.drive("tap", "tile-0")
        gallery = state("gallery-click")
        check("gallery click reaches handler", gallery["page"] == "gallery" and gallery["clicks"] == before["clicks"] + 1)
        lab.drive("scroll", "gallery-scroll", "-450")
        check("internal scroll works", state("gallery-scroll")["scrollOffset"] > 100)
        shots("gallery")
        lab.drive("tap", "nav-interaction")
        lab.drive("tap", "input-field")
        lab.drive("text", "Agent input / 测试输入")
        lab.drive("tap", "increment-button")
        interaction = state("interaction")
        check("internal text input works", interaction["text"] == "Agent input / 测试输入")
        check("button click works", interaction["clicks"] == before["clicks"] + 2)
        lab.drive("tap", "focus-key-button")
        lab.drive("key", "F6")
        check("framework keyboard event works", state("keyboard")["shortcutCount"] == before["shortcutCount"] + 1)
        shots("interaction")
        from verify_scenarios import verify_scenarios
        report['scenarios'] = verify_scenarios(output, check, shots, state, native_step)
        app_frames = output / "app-frames"
        with (output / "app-recording-driver.log").open('w', encoding='utf-8') as app_log:
            app_recorder = subprocess.Popen([lab.dart(), "run", "tool/record_app.dart", lab.session()['vmUri'],
                str(app_frames), "8", "5"], cwd=lab.APP, stdout=subprocess.PIPE, stderr=app_log,
                text=True, encoding='utf-8', creationflags=lab.CREATE_NO_WINDOW)
            try:
                ready = json.loads(app_recorder.stdout.readline())
                check("app recorder started", ready.get('ready'))
                for page in ('nav-overview', 'nav-gallery', 'nav-interaction', 'nav-overview'):
                    lab.drive('tap', page, '--no-settle')
                    time.sleep(.5)
                app_notes = app_recorder.communicate(timeout=40)[0]
                check("app recorder completed", app_recorder.returncode == 0, app_notes)
                report['appRecording'] = json.loads(app_notes.strip().splitlines()[-1])
            finally:
                if app_recorder.poll() is None:
                    app_recorder.kill()
                    app_recorder.wait()
        from media import encode_png_sequence
        report['appRecording'].update(encode_png_sequence(output/'app-recording.mp4', app_frames))
        check('app recording master preserves original pixels', report['appRecording']['losslessVerified'])
        check('app recording wall-clock pacing matches its timeline',
              lab.timing_ok(report['appRecording'], 8000, 40),
              {key: report['appRecording'].get(key) for key in ('elapsedMs', 'lateFrames', 'maxLagMs')})
        app_probe = json.loads(lab.run([lab.program('ffprobe'), '-v', 'error', '-show_streams',
             '-show_format', '-of', 'json', output / 'app-recording.mp4']).stdout)
        report['appVideoProbe'] = app_probe
        check('app video duration and frames', float(app_probe['format']['duration']) >= 7.8
              and int(app_probe['streams'][0]['nb_frames']) == 40)
        sample = subprocess.run([lab.program('ffmpeg'), '-v', 'error', '-i', str(output/'app-recording.mp4'),
             '-vf', 'fps=1,crop=iw*0.8:ih*0.7:iw*0.1:ih*0.2,scale=32:18',
             '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], capture_output=True,
             timeout=20, creationflags=lab.CREATE_NO_WINDOW)
        frame_size = 32 * 18 * 3
        samples = [sample.stdout[i:i+frame_size] for i in range(0, len(sample.stdout), frame_size)]
        differences = [sum(abs(a-b) for a,b in zip(samples[0], item))/frame_size for item in samples[1:]]
        check('app video has rendered changing pages', sample.returncode == 0 and len(samples) >= 6
              and statistics.pstdev(samples[0]) > 8 and max(differences, default=0) > 3,
              {'maxMeanPixelDifference': max(differences, default=0)})
        lab.run([lab.program('ffmpeg'), '-v', 'error', '-y', '-i', output/'app-recording.mp4',
             '-vf', 'fps=1/2,scale=480:-1,tile=2x2', '-frames:v', '1', output/'app-video-contact-sheet.png'])
        recorder = lab.new_recording(output / "window-recording.mp4", seconds=12)
        report["recordingStart"] = native_step("native recording started", recorder.start)
        if report["recordingStart"] is not None:
            for key in ("nav-gallery", "nav-interaction", "nav-scenarios", "open-dialog", "dialog-confirm", "nav-overview"):
                lab.drive("tap", key, "--no-settle")
                time.sleep(0.4)
            report["recording"] = native_step("native recording completed", recorder.finish)
        recorder = None
        if report.get("recording"):
            recording = report["recording"]
            check("recording stays in background", recording["foregroundSamples"] == 0, group="native")
            check('native recording master preserves original pixels', recording['losslessVerified'], group="native")
            check("capture backend supplied fresh frames", recording["freshFrames"] >= 4, recording, group="native")
            check("native recording wall-clock pacing matches its timeline", lab.timing_ok(recording, 12000, 144),
                  {key: recording.get(key) for key in ('elapsedMs', 'lateFrames', 'maxLagMs')}, group="native")
            probe = json.loads(lab.run([lab.program("ffprobe"), "-v", "error", "-show_streams", "-show_format", "-of", "json", output / "window-recording.mp4"]).stdout)
            report["videoProbe"] = probe
            check("video duration and frame count", float(probe["format"]["duration"]) >= 11.5 and int(probe["streams"][0]["nb_frames"]) >= 140, group="native")
            hashes = lab.run([lab.program("ffmpeg"), "-v", "error", "-i", output / "window-recording.mp4", "-f", "framemd5", "-"]).stdout
            unique = {line.split(",")[-1].strip() for line in hashes.splitlines() if not line.startswith("#") and line.strip()}
            check("video contains changing frames", len(unique) >= 4, {"uniqueFrameHashes": len(unique)}, group="native")
            native_pixels = subprocess.run([lab.program('ffmpeg'), '-v', 'error', '-i', str(output/'window-recording.mp4'),
                 '-vf', 'fps=1,crop=iw*0.8:ih*0.7:iw*0.1:ih*0.2,scale=32:18',
                 '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], capture_output=True,
                 timeout=20, creationflags=lab.CREATE_NO_WINDOW)
            native_samples = [native_pixels.stdout[i:i+frame_size] for i in range(0,len(native_pixels.stdout),frame_size)]
            native_diff = [sum(abs(a-b) for a,b in zip(native_samples[0],item))/frame_size for item in native_samples[1:]]
            check('native video has rendered changing pages', native_pixels.returncode == 0
                  and len(native_samples) >= 10 and statistics.pstdev(native_samples[0]) > 8
                  and max(native_diff,default=0) > 3,
                  {'maxMeanPixelDifference':max(native_diff,default=0)}, group="native")
            lab.run([lab.program("ffmpeg"), "-v", "error", "-y", "-i", output / "window-recording.mp4", "-vf", "fps=1/3,scale=480:-1,tile=2x2", "-frames:v", "1", output / "video-contact-sheet.png"])
        lab.drive("tap", "nav-overview")
        lab.drive("tap", "foreground-switch")
        restored = state("simulation-off-restored")
        check("switch restores actual framework state", not restored["pretendForeground"] and restored["effectiveLifecycle"] == restored["rawLifecycle"] and restored["effectiveViewFocus"] == "unfocused")
        time.sleep(1)
        final = state("final")
        check("foreground-only activity stops again", final["foregroundTicks"] == restored["foregroundTicks"])
        check("no native activation during run", final["native"]["activationCount"] == before["native"]["activationCount"] == 0)
        shots("restored")
    except Exception as caught:
        error = caught
        report["error"] = str(caught)
        report["traceback"] = traceback.format_exc()
        raise
    finally:
        if recorder and recorder.encoder:
            try: recorder.finish()
            except Exception as cleanup: report["recordingCleanupError"] = str(cleanup)
        try: lab.drive("foreground", "off")
        except Exception as restore: report["restoreError"] = str(restore)
        checks = report["checks"]
        report['functionalPassed'] = error is None and all(
            c['passed'] for c in checks if c['group'] == 'functional')
        # An interrupted run has not established native capture either.
        report['nativeCapturePassed'] = error is None and any(c['group'] == 'native' for c in checks) and all(
            c['passed'] for c in checks if c['group'] == 'native')
        report['passed'] = report['functionalPassed'] and report['nativeCapturePassed']
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"passed": report['passed'], "functionalPassed": report['functionalPassed'],
                          "nativeCapturePassed": report['nativeCapturePassed'],
                          "report": str(output / "report.json")}, ensure_ascii=False))
    return report
