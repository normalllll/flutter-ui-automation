# Public validation summary

This is a source-controlled summary of recorded results, not a replacement for
original screenshots or a claim that the current checkout passed a new device
run. Raw artifacts are local, ignored and not distributed with this repository.
The repository preparation on 2026-10-20 does not rerun GUI/device acceptance.

| Area | Recorded evidence | Scope and limits |
| --- | --- | --- |
| Repository checks | Passed on 2026-10-20 using the Python entrypoint, including an isolated source-copy check | Candidate source, metadata, Python syntax, local Markdown file links and limited secret patterns; existing ignored evidence links and a missing license were correctly rejected |
| Python contracts | 33 tests passed on Windows via Python unittest, 2026-10-20 | Session ownership, process identity, CLI routing, stale output rejection, marker decoding and small real FFmpeg encodes; no app/device runtime |
| Flutter analysis / headless tests | Analysis clean and 9 tests passed again during repository preparation, 2026-10-20 | Flutter 3.47.6 / Dart 3.13.5 on Windows; framework/widget behavior, not native presentation |
| Workflow configuration | actionlint 1.7.7 passed on 2026-10-20 | Local GitHub Actions syntax/expression checks; not remote job execution |
| Windows runtime | Latest documented regression: `verify`, 77 checks passed; 2026-10-20 Android review notes record the rerun | Fixture on the recorded local Windows environment; no guarantee for another app, host or display-off desktop |
| Windows cold launches | 2026-10-19: three launches, 12 page capture pairs, stale-token rejection and never-presented timeout passed | Historical scoped placement and presentation checks |
| Android runtime / visual review | 2026-10-19: 28 assertions across all four required groups plus sampled visual inspection | Pixel_10_Pro_XL emulator, Android 17/API 37, SwiftShader, default Flutter Impeller OpenGLES; no physical phone coverage |
| Android latest corrections | Unit-covered changes on 2026-10-20 | Output cleanup and capture-failure isolation have **not** been rerun on a device |
| GitHub Actions | Workflow added for repository, unit, Flutter headless and native compilation checks | Remote execution status is unknown until the workflow runs after a push |

The Android content recording retained 10 original 1344×2992 PNGs, sampled at
2 fps, with a 5.000 s encoded duration and 5.011 s capture wall time. All ten
decoded FFV1/BGRA frame hashes matched the source. The display recording was
original lossy H.264 at 720×1280 for 11.919 s, with a centered 574×1280 content
rectangle at x=73. Reduced video resolution and lossy fidelity are explicit.

## Known limits

- Display-off Windows capture reliability has not been established by a
  controlled comparison. Blank/stale native frames fail strict acceptance.
- Android's latest capture error-handling changes need an authorized device run
  before claiming current mobile runtime acceptance.
- Physical phones, native permission dialogs, WebView automation and IME
  composition/candidate selection are not established by the fixture results.
- Sampled visual inspection does not establish per-frame rendering fidelity or
  60 fps performance. CI and unit tests do not establish visual acceptance.
- Claude Code discovery/runtime compatibility has only been inspected statically.

See [Windows history](validation.md), [Android history](android-validation.md) and
[Claude compatibility](claude-compatibility.md). To reproduce runtime evidence,
follow the [Windows](../references/usage.md) or
[Android](../references/android.md) commands with appropriate authorization.
Inspect retained original media before recording a visual acceptance result.
