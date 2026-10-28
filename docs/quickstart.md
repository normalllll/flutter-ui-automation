# Quick start

This walks through the reference fixture on Windows and Android after the
[installation](installation.md) steps. Builds, launches and captures still need
your authorization; installing the skill alone grants none.

## Build and register the service

From the repository root on Windows:

```powershell
./tools/automation/build.ps1 -FlutterRoot C:/path/to/flutter -Fixture windows
# For Android, select -Fixture android instead.
```

On Linux, macOS or for the iOS Simulator use
`bash tools/automation/build.sh linux|macos|ios` on that host.

Register the compiled executable as the single MCP server for this workflow,
using [the MCP configuration example](../tools/automation/mcp.example.json) and
the [setup instructions](../references/mcp.md#one-time-preparation). It embeds
the official Dart/Flutter MCP and derives both SDK paths from the selected
Flutter installation; `DART_ROOT` and `DART_SDK` are not required.

Without an MCP client, start the persistent CLI service once and reuse it:

```powershell
./tools/automation/build/automation.exe --root . serve
./tools/automation/build/automation.exe --root . call automation_environment '{}'
```

See [CLI calls and ownership](../references/mcp.md#sessions-recovery-and-cli).

## Windows

Call `automation_environment` to inspect prerequisites, then start the fixture
with `automation_session`:

```json
{"action":"start","platform":"windows","sessionId":"win"}
```

Long operations return jobs. Wait with `automation_jobs` and inspect the
completed job's actual result. Read the widget tree with `automation_drive`:

```json
{"sessionId":"win","action":"tree"}
```

Use observed keys or text for interactions, then capture both channels with
`automation_capture`:

```json
{"sessionId":"win","label":"overview","includeImages":true}
```

Inspect each item's `passed` field and the original images. For an offline
fixture walkthrough, use `automation_verify`; for a networked app, keep checks
bounded and task-relevant. Stop an owned session:

```json
{"action":"stop","sessionId":"win"}
```

Windows launches use the nonactivating test runner. You may bring the window
forward to look at it. Foreground/focus changes and activation counts stay as
observations; background-only checks become `not_assessed` when interrupted.
The automation never raises the window or pushes it back behind others.

## Android

Use an explicitly authorized device ID from `automation_environment`:

```json
{"action":"start","platform":"android","deviceId":"ACTUAL_SERIAL","sessionId":"phone"}
```

Drive, capture and stop it with the same tools and `sessionId: "phone"`. The
service validates device, package, process and fixture instance; it never picks
another device or boots an emulator. See [Android](../references/android.md).

Turn Driver text emulation on explicitly for Unicode injection, and off again
before testing the real IME. Device screenshots include system UI; app
screenshots cover Flutter content. Screenrecord keeps its original lossy source
and is never presented as a lossless display master.

## Evidence

Original media, logs and session metadata stay under the ignored `artifacts/`
directory. Retry only a failed capture channel. Inspect original PNGs or
unscaled lossless extracts for text and antialiasing; MP4 previews are for
browsing. See [capture fidelity](../references/capture.md) and
[foreground simulation](../references/foreground.md).

To automate your own app, keep test hooks in a separate Debug entrypoint and
follow the [integration guide](../references/mcp.md#integrating-an-app).
