# Presentation synchronization and original pixels

This guide describes the Windows fixture/native-helper capture contract shared
by the resident MCP and independent Python window-capture tool. Android original screenrecord is
lossy; its projection and media contract are described in [the MCP workflow](mcp.md).

## Separate rendering from presentation

The old path saved the first successful native capture. That is not a
presentation barrier: Flutter's framework can finish a frame before the matching
surface reaches Windows capture, and a backend can return an old or empty client
area with a valid title bar. Waiting for Driver connection, requesting a frame,
or checking the PNG file exists does not establish the requested content.

The fixture now exposes `prepareCapture` through its test entrypoint:

1. Wait (bounded, 3 s by default) for transient animations to settle, then
   advance a 24-bit sequence and paint it in a small 32-cell color strip above
   the Navigator, at the bottom right. The strip is explicit test instrumentation,
   absent from the normal entrypoint, painted only for the requested hold
   (`holdMs`, 12 s by default for a screenshot, extended by the recording caller),
   and outside the app-capture boundary, so app PNGs never contain
   it. Native captures do; their metadata reports `probeRect` in image pixels.
2. Return the strip's logical bounds, device pixel ratio, and actual HWND/PID.
3. The native helper converts the bounds to physical client coordinates and
   samples the real HWND capture. WGC's frame origin uses DWM extended frame
   bounds; PrintWindow's uses GetWindowRect. Mixing these origins causes offsets.
4. Reject available frames whose marker does not match the requested token.
   Wait at most ten seconds. Return attempts, rejected frames and wait time.
   On timeout, fail instead of saving a claimed fresh PNG.

Window recording checks the exact token at startup, then continues checking the
strip's framing and color palette. The token may advance during a concurrent
screenshot. Recording does not stop just because a legitimate screenshot asks
for a newer frame. Neither capture path inserts app pixels into a native image.

`verify-cold` deliberately asks for a token not yet painted. It checks the helper
stays pending while native frames with an old token are available, then completes
only after the app paints the requested token. It also compares four pages from
each cold launch against app captures, excluding the native window decoration.

This fixes the missing synchronization contract. Historical white captures did
not retain enough compositor/driver evidence to establish the underlying OS/GPU
trigger. Cold-start and controlled-occlusion observations must not be rewritten
as proof of a particular Flutter engine or GPU bug. If the marker never appears,
the operation remains failed; the skill never activates the window as a fallback.

## Native failure diagnostics and display state

A visible, non-minimized HWND is not sufficient evidence that its GPU surface
has been presented to Windows capture. Display power, desktop/session access,
and the rendering path can affect that independently of Flutter Driver actions.
On 2026-10-17, another integration and the unchanged fixture both produced white
native frames; the user reported that the displays were off without system
sleep. Later tests while displays were on passed under both `flutter run` and a
direct executable launch. This is a useful reproduction variable, not yet a
controlled demonstration of cause or a diagnosis of a particular GPU/engine.

The native helper offers a read-only query (replace the sample HWND):

```powershell
examples/capture_lab/build/windows/x64/runner/Debug/window_capture.exe --hwnd 123456 --environment
```

It registers for `GUID_SESSION_DISPLAY_STATUS` on a message-only window and
reports the observed `displayState` (`on`, `off`, `dim`, or `unknown`). It also
reports target/helper/input desktop names, session IDs, DWM composition, cloaking,
display affinity, visibility, minimization, foreground/focus state, client size,
and input age. This creates no visible window and changes no input, focus or
power setting. Unknown values remain unknown. Session display state does not
identify the power state of each physical monitor.

A presentation timeout still exits unsuccessfully. With a probe, the Python
wrapper requests an additional `<stem>.failed-native.png` at source resolution.
This is the last rejected native frame, not an accepted screenshot; no image can
be saved if the backend supplied no frames. Structured error metadata contains
`error: capture_not_presented`, `probeMatched: false`, candidate/rejected counts,
`diagnosticOnly: true`, the diagnostic path, sampled RGB bounds, and environment
state. `frameStatus` distinguishes `no_frames`, `uniform_client` and
`probe_mismatch`; these sampled classifications explain failure and never replace
the exact marker check. Python raises `CaptureError`, a `RuntimeError` subclass
whose `diagnostics` member retains that metadata, for screenshot or recording
startup failures. Legacy helper error text remains supported.

Do not label an application, renderer, GPU or Windows version defective based
only on a blank native image. Compare app capture and strict native capture with
the same app state, preserving full-resolution evidence. When native presentation
fails while the display is off, app interaction and app-content capture may still
be testable; report their acceptance separately. Do not automatically wake a
display, inhibit display sleep, change rendering backends or activate the app.
A controlled display-power test requires authorization because it changes the
user's desktop environment. A passing bright-display capture does not establish
reliability while the display is off.

## Screenshot resolution

- App PNG: `RenderRepaintBoundary.toImage(pixelRatio: actualView.devicePixelRatio)`.
  The boundary wraps the entire Navigator, including Flutter dialogs and menus.
- Native PNG: unscaled pixels returned by WGC or PrintWindow, with decoration.
  Native and app dimensions differ because decorations and capture bounds differ.
- The test marker is an overlay in the test app, not a post-capture annotation.
- No resize, JPEG conversion, sharpening or smoothing is applied to these PNGs.
  Display previews in chat may be scaled; inspect the file at 100% or an integer
  zoom when judging jagged edges. Use nearest-neighbor for enlarged crops.

## Video fidelity

App-content and Windows native recordings produce:

- `name.lossless.mkv`: FFV1 level 3, BGRA, at source dimensions, with no scaling,
  chroma subsampling or odd-size padding. This is the pixel-inspection master.
- `name.source.framemd5`: original BGRA frame hashes. The master is decoded back
  to BGRA and every frame hash plus dimensions must match before success is reported.
- `name.mp4`: H.264/yuv420p viewing copy, marked `previewIsLossy: true`. It is
  padded by at most one bottom/right pixel when required for encoding. It is not
  the antialiasing acceptance source.
- App recording additionally retains every original physical-resolution PNG.
  A native recording can be extracted from the lossless master into PNGs.

The resident MCP uses a new attempt directory for each capture. The retained
Python wrapper clears reused output paths and publishes screenshots by atomic
rename after acceptance. Failed attempts retain separate diagnostics so an older
image or video cannot be mistaken for a successful current capture.

## Timing and freshness

Container duration is fixed by the frame count, so it is not evidence of
acquisition pacing. The resident MCP reports app `acquisitionMs`, sample times
and `timingPassed`; app acquisition and Android encoded duration use a 15%
tolerance. Native helper timing and fresh-frame observations are retained
separately. Inspect each channel's actual timing fields as well as its video.

The native helper reports `elapsedMs`, `expectedMs`, `lateFrames` and `maxLagMs`.
Its pacing clock begins once the first frame reaches FFmpeg. The standalone
wrapper retains these observations; fixture timing acceptance is implemented by
the resident verifier.

`freshFrames` is labelled by `freshFrameMeaning`: `wgc_presented_frames`
counts frames DWM actually delivered; `printwindow_changed_frames` counts
PrintWindow bitmaps whose pixels changed (PrintWindow always returns a
bitmap, so a call count would be meaningless).

Example unscaled extract:

```powershell
ffmpeg -ss 1 -i artifacts/window.lossless.mkv -frames:v 1 artifacts/frame-original.png
```

The resident defaults are app sampling at 5 fps on Windows and 2 fps on Android,
and Windows native sampling at 12 fps. Windows `nativeFps` accepts only integers
from 1 to 60, shared by the helper and encoder. Pixel
fidelity does not establish 60 fps smoothness, absence of dropped render frames,
or HDR/color-management fidelity. The helper currently uses 8-bit BGRA capture.
For frame pacing/performance investigations, choose an appropriate sampling rate
and collect engine timing evidence separately.

Contact sheets and the reduced pixel buffers used by behavioral assertions are
derived diagnostics only. The source PNGs and lossless masters remain untouched.
