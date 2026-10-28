# Validation status

Updated 2026-10-27, Asia/Taipei. This page separates current local checks,
recorded runtime acceptance and remaining limits. Raw images, recordings,
service tokens and device identifiers remain in ignored local artifacts.

## Current local checks

| Check | Result | Scope |
| --- | --- | --- |
| Resident Dart MCP | 86 cases: Windows 73 passed / 13 platform skips; Linux and macOS each 75 passed / 11 platform skips | Protocol, cancellation, evidence isolation, readiness, session/lease/process identity, simulator binding before Driver mutation, retryable cleanup, failed-launch rollback, bounded process/pipe cleanup, raw simulator rotation and real FFmpeg fidelity/timing |
| Compiled distribution | Passed without inherited `DART_ROOT` / `DART_SDK` | MCP initialization, merged tools, native-fps validation, compiled CLI reuse, EOF cleanup |
| Broker lifetime | Passed | Authentication, shared service PID, duplicate rejection, shutdown and recovery after a forced service-only crash |
| Independent Python capture | 11 tests passed on Windows | HWND/PID scope, diagnostic retention, atomic publication and helper cleanup; no Flutter/Android runtime remains |
| Flutter fixture | Analysis clean; 10 headless tests passed | Binding restoration, focus guard, layout, dialogs and widget behavior |
| Repository | Source/metadata/document links and `git diff --check` passed | Excludes ignored build, media, session and lock files from published source |
| CI configuration | Actionlint passed; Linux/Windows/macOS matrix, native/Apple builds and isolated Linux runtime checks configured | Remote execution of the uncommitted platform changes is pending |

Local runtime measurements used Flutter 3.47.8 / Dart 3.13.7. Minimum supported
toolchains are Flutter 3.44.0 / Dart 3.12.0, based on the embedded server's Dart
requirement and the corresponding Flutter release. SDK constraints declare lower
bounds, and no custom version-number gate blocks startup. CI tracks the current
stable branch without a fixed SDK tag or commit.

The Windows job in [the previous run](https://github.com/normalllll/flutter-ui-automation/actions/runs/40369301566/job/121735465281)
failed during Flutter checkout because an engine golden-image path exceeded the
Windows Git default path limit. The workflow now enables `core.longpaths` before
that checkout and prepares FFmpeg for the migrated Dart media tests. A local
323-character checkout path failed with Git long paths disabled and succeeded
with them enabled.

The [next remote run](https://github.com/normalllll/flutter-ui-automation/actions/runs/40376724830)
passed the Python and native-build jobs. Windows then failed at fixture dependency
resolution; Linux reached the 20-minute job limit while preparing FFmpeg, before
the Dart tests. The SDK checkout omitted release tags. An isolated shallow-clone
reproduction using Flutter's unmodified version-detection code returned
`0.0.0-unknown` without tags and the release version after fetching tags at depth
one. CI now includes those tags while continuing to follow `stable`. FFmpeg setup
has a five-minute step limit and noninteractive Linux installation with bounded
network retries/timeouts and lock waits. Remote results must be checked for the
current commit; the failed run does not establish acceptance of these corrections.

The subsequent [run for commit 801eaf2](https://github.com/normalllll/flutter-ui-automation/actions/runs/40383644877)
passed all five jobs. It predates the current uncommitted Linux/Apple expansion.
No new commit or push was made for the platform implementation. Detailed current
host/runtime scope is in [Linux and Apple validation](unix-validation.md).

## Linux and Apple runtime expansion

Linux X11 passed the fixture walkthrough and both capture channels on an isolated
WSL/Xvfb display. macOS passed app-only interaction/capture, actual source hot
reload and recording cancellation over SSH; native ScreenCaptureKit capture is
compiled but remains unverified because the host has not granted Screen Recording
permission. iOS Simulator passed native keyboard, rotation, lifecycle, both capture
channels, portrait/landscape recordings, source hot reload, cancellation and cold
presentation fences. All owned test apps stopped with empty cleanup-error lists.

Windows-to-Mac SSH stdio also passed tool discovery, remote environment inspection,
inline PNG delivery and owned stop with the fixture observed inactive. Linux
Wayland, physical Linux desktop/GPU behavior and physical iOS devices have no new
runtime acceptance.

## Regression coverage after Python retirement

| Behavior retained from the old runtime | Current coverage |
| --- | --- |
| Lease/path isolation, attach ownership, stale PID rejection and atomic metadata writes | `sessions_test.dart`, `session_storage_test.dart`, `windows_identity_test.dart` |
| Explicit Android device/package/token, binary PNGs, selected panel, stale markers and failed originals | `android_capture_test.dart`, `platform_test.dart` |
| Real encoded duration, PNG retention, full-frame FFV1/BGRA hashes, lossy Android source/projection | `media_test.dart` |
| Foreground observations, background assertions and temporary-mode cleanup | `foreground_test.dart`, `test_modes_test.dart`, fixture binding tests |
| Native failure isolation, successful app evidence, later interactions and interruption never passing | `capture_isolation_test.dart`, `acceptance_test.dart` |
| Independent native capture CLI publication/diagnostics and helper lifetime | `scripts/test_window_capture.py` |

Submission review added regressions for failed session-metadata saves, lost enable
replies, failed mode restoration and cancellation during final report persistence.
Live sessions are published only after metadata is durable; cleanup responsibility
is persisted before enabling a temporary mode and retained until disabling is
acknowledged. Ordinary and cold verification share cancellation-aware final-report
publication. All 69 Dart tests passed locally after these changes.

CLI-routing compatibility tests for the deleted Python runtime were retired with
that interface. Headless migrations exercise the resident implementation; they
do not claim new GUI/device acceptance.

## Recorded resident-runtime acceptance

Windows and a physical USB Galaxy Fold were exercised on 2026-10-26–27 with the
resident MCP. The retained evidence covers navigation, callbacks, Unicode,
Android native IME/insets, lifecycle/rotation, app/native PNG comparison, exact
presentation tokens, lossless app/Windows masters, source hot reload, restart,
cancellation, service recovery and per-channel failure isolation.

BooruFlow was exercised through its dedicated Windows Debug harness and isolated
Android Debug package. Its production app/data remained separate; source hot
reload through the staging junction and restart preserved the native PID.
The tests did not submit searches or repeatedly refresh network content.

Windows cold-start PNG pairs and presentation fences passed, followed by a
separately accepted launch/stop correction. That earlier run is not relabeled as
an entirely passing cold cycle. Android completed its full cold cycle. The later
review changes have headless/compiled regression coverage; no new device or GUI
run was performed for those changes. Full measurements and reproduction commands
are in [resident MCP validation](mcp-validation.md).

## Historical evidence retained in summary

Older implementation journals have been consolidated here; their complete text
remains in Git history. They are not instructions for the current runtime.

| Date | Recorded result | Limit that remains relevant |
| --- | --- | --- |
| 2026-10-17 | An early Windows run passed app interactions/media but rejected blank or stale native captures; a later run passed 56 checks | API success and a title bar do not establish native content freshness. Early raw artifacts were subsequently removed |
| 2026-10-19–20 | Legacy Windows `verify` passed 77 checks; three cold launches passed 12 page pairs and stale-token tests | Recorded host/fixture evidence, not a guarantee for another app or display-off desktop |
| 2026-10-19 | Pixel emulator passed 28 Android runtime assertions and sampled visual inspection | Native encoder reduced a 1344×2992 display to 720×1280 with letterboxing; original screenrecord was lossy. These results predate later Python capture changes |
| 2026-10-20 | [Previous remote CI](https://github.com/normalllll/flutter-ui-automation/actions/runs/39453400835) passed all four jobs | Predates the resident MCP and current foreground policy; it does not establish current CI status |

Distinct historical measurements remain useful as bounded evidence:

- Early native white frames and a 5-second Android capture encoded as 2 seconds
  were incorrectly accepted by older automatic checks and rejected during visual
  review. Those attempts are not counted as final acceptance.
- Windows negative tests rejected 101 candidate frames for a never-presented
  token without publishing a success PNG; a recording-start failure produced
  diagnostics without an encoder/master. A 330-second display observation saw
  only display-on samples and did not establish display-off behavior.
- One Windows run verified all 320 source/master BGRA frame hashes: app page and
  animation videos were 1898×1024, 8 s at 5 fps (40 frames each); native page and
  animation videos were 1902×1071, 12 s / 144 frames and 8 s / 96 frames at 12 fps.
- The emulator app capture retained 10 frames, 5.000 s encoded / 5.011 s acquired.
  Its original native video was 11.919 s at 720×1280, with a centered 574×1280
  content projection at x=73. Resolution reduction and lossy fidelity were explicit.

## Acceptance boundaries

- Windows foreground/focus and activation counts are observations with unknown
  initiator. User inspection does not invalidate pixels. Background-only checks
  are `not_assessed` if their uninterrupted background interval was not established.
- Display-off Windows reliability remains unresolved. Both an integrated app and
  the fixture produced blank native frames while displays were reportedly off;
  later display-on captures passed. No controlled comparison established cause.
  Strict tokens and original diagnostic frames remain required; automation does
  not wake displays or change power policy.
- CI and headless tests do not establish visual acceptance. Sampled video review
  does not establish per-frame fidelity or 60 fps performance.
- Native permission/OS dialogs, WebView automation and IME composition/candidate
  selection require separate coverage. Android original screenrecord is lossy.
- Claude Code discovery/runtime, macOS/iOS and SSH execution were not exercised.
- Fixture evidence is not verification of an arbitrary application. Fresh
  acceptance requires the actual authorized target and retained artifacts.
