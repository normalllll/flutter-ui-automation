# Resident Dart MCP validation — 2026-10-26–27

The resident Windows/Android route is implemented under `tools/automation/`.
These are local results on Windows with Flutter **3.47.8 / Dart 3.13.7**, the
official `dart_mcp_server` **1.2.1**, and a physical USB Galaxy Fold (SM-F9660,
Android 16). macOS/iOS and SSH were not exercised. Raw evidence stays under
ignored `artifacts/`; this summary contains no service tokens or device serial.

## Accepted paths

| Path | Evidence | Result |
| --- | --- | --- |
| Embedded MCP | Actual compiled executable over JSON-RPC; merged official/local tools; resources/prompts; invalid requests; cancellation; EOF | Passed; one resident MCP implementation through the official public channel API |
| CLI reuse | Authenticated loopback requests and three separately started compiled clients | Same server PID; no new Driver/MCP process per call |
| Service lifetime | Duplicate start, graceful stop, forced service-only crash and incomplete descriptor | Passed; OS file lock releases after a crash and a replacement service starts |
| Windows fixture | Navigation, gallery click/scroll, Unicode, callback counts, F6, modal barrier/confirm/cancel, framework simulation/restoration | Passed; actual HWND stayed in the background during the recorded runs |
| Android fixture | Explicit USB/package/instance verification, Unicode, real IME/insets, Back, gallery/scroll, modal barrier/confirm/dismiss | Passed; actual native lifecycle/focus preserved |
| Android rotation/lifecycle | Portrait/landscape pairs, background/resume with retained content and PID | Passed; outer display 1080×2520 and landscape 2520×1080 |
| Native freshness | Exact visual marker on WGC and selected Android physical panel | Passed; panel IDs are resolved rather than hardcoded |
| Screenshot comparison | App content compared with native client/display content, excluding system insets and IME | Windows and Android passed |
| App/native video | Concurrent 3-second recordings, full master hash comparison, motion measured in the animation stage | Passed; original PNGs/FFV1 masters and Android original lossy MP4 retained |
| Source editing | Temporarily add a real snapshot field, hot reload and read it in the same app, restore source and reload | Passed; original source fully restored |
| Hot restart | Rebind new main isolate, await extension and native identity, retain native PID | Windows and Android passed |
| Concurrent control/cancel | Drive another page while app recording runs; cancel only that recording | Passed; successful screenshots retained |
| Failure isolation | App PNG succeeds, native target and final state observation fail, then native-only retry | Regression passed; app PNG bytes unchanged and screenshot called once |
| Cold boundaries | Four page pairs; future token waits for rendering; never-presented token times out without a success PNG | Android complete cycle passed; Windows capture/fence steps passed, followed by separately accepted cleanup correction |
| Recovery | Retained stale session after terminated service, PID/creation identity checks and lease release | Passed for Windows hosts; attached-app ownership is preserved |
| Original BooruFlow Windows | Dedicated existing Debug bundle, fresh isolated profile, tree, hot reload, app/native PNGs and stop | Passed; live content rendered; no business refresh loop |
| Original BooruFlow Android | Dedicated staged Debug entrypoint/native bridge, separate package/profile; actual search Unicode, native IME, screenshots and app/native recording | Passed on USB Fold; normal application and data preserved |
| BooruFlow Android restart/source edit | Readiness through business bootstrap, same native PID; temporarily add/remove a real search-header key in original `lib/` through the staging junction | Passed; source fully restored; earlier successful images/videos were not repeated |

All GUI launches used the verified nonactivating runners. No host pointer/keyboard
input, foreground activation or forced window repositioning was used. Viewing a
window/device is allowed. Focus observations cannot identify their initiator;
interrupted background-only conditions are `not_assessed`, not capture failures.
That policy is also covered by dedicated foreground regression tests.

## Measured costs

These are measurements from retained individual runs, not throughput guarantees:

| Operation | Measurement |
| --- | --- |
| Warm loopback status request | About 1 ms after first call; status only, no app/network refresh |
| Start thin compiled CLI client and call existing service | About 20–25 ms in the initial three-call run |
| Actual source hot reload in Windows fixture | 175 ms to add source field, 164 ms to restore |
| Windows fixture hot restart | 597 ms in the same run; native PID unchanged |
| BooruFlow Windows hot reload | 333 ms; same native PID |
| App/native PNG pair plus comparison, Windows fixture | 378 ms in source-edit acceptance run |
| BooruFlow app/native PNG pair | 900 ms; comparison explicitly disabled for changing live content |
| Android 3-second app acquisition, 2 fps | 3.004516 s; six original frames and verified FFV1 master |
| Android original system video | 2.967378 s encoded duration; about 8.848 s including recording finalization, pulling and verification |
| BooruFlow Android source hot reload | 2.109 s to add real header key; 1.829 s to restore; same native PID |
| BooruFlow Android hot restart | 3.233 s including business bootstrap; same native PID |
| BooruFlow Android app/native PNG pair | 1.194 s; native-IME pair 1.559 s |
| BooruFlow Android 3-second recording | App acquisition 3.007642 s at 2 fps; native original 3.306389 s; native end-to-end about 8.842 s |

App defaults remain 5 fps on Windows and 2 fps on Android; Windows native defaults
to 12 fps. The paired verification deliberately uses 2 fps app sampling. Actual
acquisition/timing is reported separately from the fixed-rate video timeline.
Android screenrecord is lossy and can have startup/finalization costs and device
specific duration behavior. A converted video is not presented as a lossless
display master, and no trim hides timing errors.

## Evidence boundaries

The first Windows cold run retained four successful PNG pairs/comparisons,
`fence.png`, and a rejected never-presented diagnostic, then exposed the exit
race. Those successful captures were reused. Only launch/stop was repeated to
validate the correction; the failed run was not relabeled as a wholly passing
end-to-end run. Android's complete cold cycle subsequently passed with the fixed
lifetime path.

## Reproduction and boundaries

From `tools/automation/`, after resolving dependencies and compiling:

```powershell
dart analyze
dart test
dart run bin/check_startup.dart
dart run bin/check.dart
dart run bin/check_broker.dart
# Explicitly authorized GUI/device acceptance only:
dart run bin/check.dart windows
dart run bin/check.dart android ACTUAL_SERIAL
dart run bin/check.dart windows --quick
dart run bin/check.dart windows --expanded
dart run bin/check.dart android ACTUAL_SERIAL --expanded
dart run bin/check.dart android ACTUAL_SERIAL --cold
dart run bin/check.dart booruflow PROJECT ISOLATED_DEBUG_EXE
dart run bin/check.dart booruflow-android STAGED_PROJECT ACTUAL_SERIAL
dart run bin/check.dart booruflow-android STAGED_PROJECT ACTUAL_SERIAL --restart-only
dart run bin/check.dart booruflow-android STAGED_PROJECT ACTUAL_SERIAL --source-proof
```

`--quick` covers real source editing and restoration, restart, capture, recording
control/cancellation and CLI reuse. `--expanded` covers the additional callback,
pixel, timing and lifecycle rules without repeating unrelated groups. Runtime
tools additionally accept a `checks` subset and native-only capture retries.

After the 2026-10-27 review fixes, the Dart package analysis is clean and
**35 tests passed** on Windows. The retained Python migration suite also passed **46 tests**. The compiled distribution
and repository/link checks passed locally. The added CI steps have not run on
GitHub yet.

The review follow-up compiled the current executable and ran
`check_startup.dart` without inherited `DART_ROOT` / `DART_SDK`. Initialization,
merged tools, fractional native-fps rejection, integer-fps dispatch, compiled
CLI reuse and EOF descriptor cleanup passed. An invalid SDK also closes the
gateway with a nonzero result instead of leaving initialization pending.
Session regressions cover replacement lease owners before recovery side effects
and at release, matching-owner cleanup, and explicit attach target conflicts.
The keyboard-only verifier group passes from overview, gallery and scenarios
using a simulated Driver/device boundary; this establishes independent setup,
not new physical-device IME acceptance. CI now runs the headless checks on both
Linux and Windows so Windows-only owner tests are exercised, and starts the
compiled executable after compilation.

There is one resident MCP server, with normal Flutter compiler/app processes per
session and operation-specific native helper/ADB/FFmpeg processes. Native plugin
or runner changes still require a rebuild. Display-off Windows reliability,
native OS-dialog automation and 60 fps acceptance remain outside this evidence.

Android acceptance includes both the offline reference fixture and the real
BooruFlow app in an isolated Debug package. The original HTTP/AOT harness remains
unchanged; the new Debug entrypoint is the MCP route. The original application
data and production entrypoint were preserved. The BooruFlow test performed no
submitted search or repeated business refresh. Its first complete run exposed
the post-restart bootstrap wait; only restart was repeated after that fix.
Source-edit acceptance was then checked independently without retaking the
accepted screenshots or recordings. See [the current workflow](../references/mcp.md).
