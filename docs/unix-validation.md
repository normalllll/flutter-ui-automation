# Linux and Apple runtime validation

Recorded 2026-10-27, Asia/Taipei. This report describes the uncommitted platform
implementation and retained local evidence. Raw media, process/device identities,
VM addresses and service descriptors remain in ignored `artifacts/` directories.

## Hosts and scope

| Target | Execution environment | Result and boundary |
| --- | --- | --- |
| Linux | Ubuntu in WSL, Linux Flutter SDK, dedicated 1600×1000 Xvfb display, software GL | Full fixture runtime passed; independent X11 PNGs and PNG-sampled native recordings verified |
| macOS | Apple Silicon, macOS 26.5.2, Xcode 26.6, SSH into the logged-in user session | App-only walkthrough/capture, source reload and cancellation passed; independent window capture awaits Screen Recording permission |
| iOS Simulator | Dedicated iPhone 16, iOS 26.5, explicitly selected on the Mac | Full fixture runtime passed, including native keyboard, landscape/portrait and real background/resume |
| Remote transport | Windows client to the compiled Mac MCP over SSH stdio | 25 tools discovered; paths with spaces/quotes, inline PNG, nonactivation, owned stop on EOF and recovery after service-only crash passed |

Flutter 3.47.8 / Dart 3.13.7 were used for this evidence. Declared minima remain
Flutter 3.44.0 / Dart 3.12.0. Those bounds are not exact toolchain pins or custom
version-number startup checks. ScreenCaptureKit's screenshot API requires macOS
14+; scene orientation requests require iOS 16+.

## Checks that passed

- Dart suite: 86 registered cases. Windows passed 73 with 13 platform skips;
  Linux and macOS each passed 75 with 11 platform skips.
- Fixture analysis and 10 headless tests passed. Linux, macOS and iOS Simulator
  fixture builds and the native capture helper builds succeeded.
- Runtime walkthroughs covered navigation, callback counts, scrolling, Unicode,
  modal barriers and animation pixels. App-only macOS results explicitly exclude
  independent system capture.
- Source hot reload was verified by editing the dedicated fixture source,
  observing its changed title in the running widget tree, restoring the source
  and reloading again. Native process identity remained stable.
- Recording cancellation left an incomplete/cancelled job and allowed subsequent
  session operations. Linux/iOS cold checks rejected never-presented tokens and
  waited for future tokens until the matching pixels appeared.
- iOS real soft keyboard show/hide, both orientations and background/resume via
  the simulator's Settings app passed. Content and native PID survived resume.
- An already running iOS bundle was rejected before reinstall/launch. A stopped
  bundle permitted a fresh start, including after launchd retained a cached job.
- Owned runtime test apps stopped with no cleanup errors. The dedicated iPhone
  simulator was shut down afterward; the pre-existing iPad simulator was shut down
  at the user's request.

## Defects found and corrected during runtime testing

WSLg's shared X11 socket directory could not accept another X server. The WSL
validation isolated `/tmp` in a private mount namespace for its own process tree;
it did not replace shared sockets or change WSLg permissions.

Flutter's macOS launch implementation intentionally foregrounds the app. The
macOS fixture path now builds, directly launches its nonactivating Debug panel,
and attaches Flutter. The Flutter SDK is unmodified. The remote fixture reported
`isForeground: false` while interactions and app capture succeeded.

CoreSimulator retained a portrait 1179×2556 raw framebuffer while UIKit rendered
a 2556×1179 landscape scene. Initial native captures were rejected for geometry.
The fix preserves original PNGs and records a 270-degree transform to app
coordinates for the exercised landscape direction. Exact marker checks and pair
comparison apply that transform in memory. Landscape recording retained the raw
orientation, verified all FFV1/BGRA source-frame hashes, and decoded its requested
region after the declared rotation. No lossy re-encode or resized proxy replaced
the original evidence.

Geometry-transition candidates and failed originals are retained. Tests cover
unrotated/rotated token matching, image-pair comparison and exact byte retention.

## Follow-up implementation review

- Unix VM PIDs are verified before configuring Driver, then matched against
  native state without replacing the verified identity. iOS also checks the
  selected simulator's exact running bundle job before capture, lifecycle and
  cleanup. Retained recovery rejects a reused VM endpoint before changing modes.
- Failed attached-mode restoration retains the session and lease for retry.
  Exited attached apps can release their modes and leases. Failed lease removal
  preserves retry authority; incomplete initial ownership writes are rolled back.
- A controller that has exited cannot hide an owned native app when session
  publication fails. Rollback stops the verified native instance. Owned Unix
  process cleanup escalates resistant processes, and command timeouts also bound
  inherited output pipes after the direct child exits.
- iOS restores the original interface orientation and supported mask; explicit
  restore, normal close and retained recovery wait for observed restoration.
  Native recording checks each frame's viewport, preserves raw rotation and
  samples token coordinates without allocating a rotated display copy.
- Simulator native acquisition defaults to 1 fps. The reviewed 2 fps recording
  overran a 3-second acquisition budget; its original media was retained as a
  failed timing result. Timing failures now fail the recording channel as well
  as the fixture verifier, while preserving lossless fidelity results.
- The SSH example quotes one remote shell command, including paths with spaces
  or literal quotes, and uses `exec` for direct stdio lifetime management.

The final simulator recording acquired three native frames at 1 fps in 3003 ms
for a 3000 ms request, with timing and decoded FFV1/BGRA hashes both passing.
The final targeted run also passed real landscape captures/video, explicit
orientation restoration and cleanup. The complete iOS walkthrough, macOS app-only
walkthrough and Linux Xvfb walkthrough passed. Mac package resolution was retried
against existing cached dependencies after a transient TLS download failure.

SSH acceptance used an artifact path containing both spaces and a single quote.
Closing stdio stopped the owned app. A second check killed only the owned MCP,
confirmed its app remained alive, reconnected, required explicit `stopOwned`,
and recovered/stopped the original process with no cleanup errors. Final process
and lease inspection found no owned apps/controllers/services or remaining lease
owners. The dedicated iPhone and the previously selected iPad were both shut down.

## Inspection and remaining limits

Retained app/device PNGs were inspected for Linux layout, macOS Unicode input,
iOS dialogs/keyboard and landscape rendering. Videos were decoded and inspected
using retained original/lossless frames; timing and motion checks use content
regions, excluding presentation markers and device clocks.

The Mac provides a 1920×1080 graphical display despite having no physical monitor.
The capture helper's permission preflight remained false after the authorized
request. No screen-sharing service was configured and no TCC database was edited.
Full macOS independent capture acceptance remains pending user-granted permission.

Linux Wayland capture, physical-desktop compositor/IME/GPU behavior, physical iOS
devices and arbitrary production apps are outside this evidence. CI has been
expanded locally and passed workflow validation; it has not run remotely because
these changes have not been committed or pushed.
