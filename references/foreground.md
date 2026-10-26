# Background foreground simulation

This is a Flutter framework test mode, not a fake Windows foreground process.

## Mechanism

`examples/capture_lab/lib/src/automation_binding.dart` installs a custom test
binding before `runApp`. Its Driver extension uses the same SDK implementation
as `enableFlutterDriverExtension`, with a binding that can intercept lifecycle
and view-focus notifications before framework observers receive them.

- Off: deliver real lifecycle/view-focus notifications.
- On: remember real notifications but deliver `resumed`/`focused` to Flutter.
- Disable: replay the most recent real notifications, including events received
  while enabled. Never restore a hardcoded `inactive` if real state is `hidden`.
- A never-activated window may initially have no lifecycle message. The fixture
  seeds that missing state once from native visibility/foreground observations,
  only after the host is visible, avoiding an artificial `hidden` state during
  startup. Incoming actual lifecycle events retain priority over that fallback.
- The test binding guards `FocusManager.rootScope.canRequestFocus` while
  the actual view is unfocused and simulation is off. Actual user activation
  still restores ordinary framework focus. When enabling, it delivers simulated view focus before
  allowing traversal. This prevents the root focus scope from asking Windows
  for native focus at startup. Changing only `ShowWindow` was insufficient.
- Internal interaction explicitly requests a bounded refresh before a command
  and, after it, pumps forced frames (at most 3 s) until transient animations
  finish, so navigation remains hittable and route transitions complete when
  ordinary frames are disabled by `hidden`. This does not globally replace
  normal frame scheduling or change the reported lifecycle. Foreground-gated
  logic still pauses with simulation off.
- The Windows runner's first show sets `HWND_BOTTOM` with `SWP_NOACTIVATE`,
  prefers a DPI-aware secondary-monitor location, avoids unconditional child focus
  at attachment, and focuses the child on real user activation only.

Both protections are useful: non-activating show avoids normal startup
activation; guarding framework traversal prevents unwanted native focus
requests. Neither replaces actual HWND evidence.

The fixture reports Windows `isForeground`, native focus and activation count,
raw platform lifecycle, effective lifecycle and effective view focus separately.
The independent recording helper also samples actual foreground status per
output video frame. Capture does not move windows or raise their Z-order.

The user may activate the window to inspect it at any time. A nonzero activation
count, focused state or foreground recording sample does not invalidate a PNG,
video or batch, and does not by itself establish that automation stole focus.
The verifiers retain these observations with unknown activation attribution.
They do not send the window back or manipulate user focus. An observed focus
change makes background-only counter checks `not_assessed`; it is not counted
as a passing background test. The activation counter also catches an activation
and return between the two endpoint snapshots. This is sampled evidence, not a
continuous audit of every platform event.

After simulation is disabled, the expected state is the latest actual lifecycle
and view-focus event, including `resumed`/`focused` after user inspection. State
snapshots expose `rawViewFocus` for the current view. With an older fixture that
does not expose this field, focus restoration is explicitly not assessed until
the test entrypoint is rebuilt; lifecycle restoration is still checked.

## What this establishes

The verification counter advances only if `WidgetsBinding.lifecycleState` is
`resumed`. When uninterrupted background intervals are established, the test
checks that the counter stops in real background state and stops again after
disabling simulation. It checks that it advances with simulation enabled.
It separately verifies
widget interactions, Unicode text input and a framework F6 key event.

This is useful for lifecycle-gated widgets, focus-dependent Flutter paths and
visual walkthroughs. It does not test real IME composition, native text entry,
global shortcuts, system dialogs, real pointer capture, OS activation, or native
plugin branches that directly query Windows focus. Do not use API hooking to
hide those limitations.

## Capture boundaries

When the platform reports `hidden`, ordinary `scheduleFrame` can be disabled;
app capture requests one
`scheduleForcedFrame` with a bounded wait. This refreshes capture without keeping
the foreground simulation enabled or changing Windows focus.

Both native capture backends require an existing visible, non-minimized target. Hidden,
minimized, destroyed or resized targets return an error instead of silently
changing focus, showing the window, or returning a claimed fresh capture.
Desktop lock, protected content, secure desktop and other GPU/driver combinations
are not established by this fixture's passing run.

## Native capture backend selection

The fixture defaults to WGC with a per-request presentation probe. PrintWindow
remains available in the independent helper and generic CLI. Earlier runs
recorded white/old client content from both APIs; backend success was insufficient.
The current capture path waits for the requested token in actual captured pixels,
compares native client content with app capture, and fails if the frame is never
presented. See [capture details](capture.md) for the synchronization contract,
historical-diagnosis limits, physical-resolution PNGs and lossless video masters.

Keep native failures explicit. Do not synthesize a window frame around an app
screenshot or activate the window as a fallback. PrintWindow can block or fail
for other apps, so it runs in a separate helper with a caller timeout. Re-evaluate
compatibility in the deployment environment. The fixture's latest measured
results are recorded separately in [MCP validation](../docs/mcp-validation.md).
