# Validation status

Updated 2026-10-27, Asia/Taipei. This page separates current local checks,
recorded runtime acceptance and remaining limits. Raw images, recordings,
service tokens and device identifiers remain in ignored local artifacts.

## Current local checks

| Check | Result | Scope |
| --- | --- | --- |
| Resident Dart MCP | Analysis clean; 35 tests passed on Windows | Protocol, cancellation, evidence isolation, readiness, lease ownership, attach conflicts and independent keyboard-group setup |
| Compiled distribution | Passed without inherited `DART_ROOT` / `DART_SDK` | MCP initialization, merged tools, native-fps validation, compiled CLI reuse, EOF cleanup |
| Broker lifetime | Passed | Authentication, shared service PID, duplicate rejection, shutdown and recovery after a forced service-only crash |
| Python regression tools | 46 tests passed on Windows | Session/capture contracts, display-panel selection, foreground evidence and small real FFmpeg encodes; no app/device launch |
| Flutter fixture | Analysis clean; 10 headless tests passed | Binding restoration, focus guard, layout, dialogs and widget behavior |
| Repository | Source/metadata/document links and `git diff --check` passed | Excludes ignored build, media, session and lock files from published source |
| CI configuration | YAML parsed; Linux/Windows matrix and compiled startup check configured | Remote execution of the current change is pending |

The runtime checks used Flutter 3.47.8 / Dart 3.13.7. CI pins Flutter 3.47.6 /
Dart 3.13.5 and now exercises the compiled startup check and Windows-only lease
tests. These local results do not claim that the new remote jobs have run.

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
