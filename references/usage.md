# Independent Windows window capture

For Flutter sessions, interaction and verification, use [the resident MCP](mcp.md).
This guide covers the standalone HWND/PID capture tool. It can capture an
explicitly authorized window without adding Flutter Driver hooks, changing
foreground focus or injecting desktop input.

## Prepare the tool

Use native Windows, Python 3.11+, Visual C++/Windows SDK and CMake. Recording
requires FFmpeg on PATH. The Python wrapper uses only the standard library.
Build the C++ helper from the repository root:

```powershell
cmake -S tools/window_capture -B tools/window_capture/build -A x64
cmake --build tools/window_capture/build --config Release
```

Pass this standalone helper path explicitly. The wrapper's default helper path
is the fixture build's `examples/capture_lab/build/windows/x64/runner/Debug/window_capture.exe`.
No Flutter SDK is required when using the standalone CMake build.

## Capture an authorized target

Supply the actual HWND and PID of the selected application:

```powershell
python scripts/window_capture.py screenshot --hwnd 123456 --pid 1234 --helper tools/window_capture/build/Release/window_capture.exe --backend wgc --output artifacts/window.png
python scripts/window_capture.py record --hwnd 123456 --pid 1234 --helper tools/window_capture/build/Release/window_capture.exe --backend wgc --output artifacts/window.mp4 --seconds 8 --fps 12
```

Supported backends are `wgc` and `printwindow`; the wrapper defaults to
PrintWindow. Recording accepts 1..120 seconds and integer rates from 1..60 fps.
The target must remain visible, non-minimized and at a stable size. The tool does
not activate, raise, reposition or launch it. Foreground observations remain
metadata and do not establish who changed focus.

## Presentation markers

If the application's authorized test hooks expose a marker, pass its exact token
and bounds. Physical-client coordinates use `--probe`:

```powershell
python scripts/window_capture.py screenshot --hwnd 123456 --pid 1234 --helper tools/window_capture/build/Release/window_capture.exe --backend wgc --output artifacts/window.png --probe 42 1700 1000 192 12
```

`--probe-json FILE` accepts `{token, rect: {x, y, width, height}, pixelRatio}`
from a test hook; `-` reads JSON from stdin. Logical coordinates are converted
using `pixelRatio`. Select exactly one probe format.

Without a probe, the wrapper warns and returns `presentationVerified: false`;
inspect content before accepting it. API success and a visible title bar alone
cannot prove freshness. With a probe, stale frames are rejected until the token
appears, or the operation fails with retained diagnostics.

## Outputs and failure evidence

Screenshots preserve original PNG pixels and publish by atomic rename only after
acceptance. Reused success/diagnostic paths are cleared before each attempt.
Native failures expose `CaptureError.diagnostics` when the helper supplies JSON,
including target/display state and the original rejected PNG when available.

Recordings stream raw BGRA to FFmpeg. `scripts/media.py` verifies the FFV1 master
against all source-frame hashes and dimensions, then publishes a separate lossy
H.264 MP4 preview. It is the standalone capture tool's media helper; it contains
no Flutter session, Android or app-recording runtime.

Retain `.lossless.mkv`, `.source.framemd5` and original diagnostic images for
inspection. The preview may be padded to even dimensions; it is not the source
for pixel-fidelity acceptance. See [capture fidelity](capture.md) for native
presentation, display-off limits and unscaled frame extraction.

## Development checks

```powershell
python -B scripts/check_repository.py
python -B -m unittest discover -s scripts -p "test_*.py" -v
```

These Windows tests validate target scope, atomic publication, diagnostic
retention and owned-helper cleanup without launching an application or capturing
an actual desktop. Flutter control and media regressions live in
`tools/automation/test/` and are run with `dart test`.
