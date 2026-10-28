# Remote execution through SSH

Run the resident MCP on the host that owns the app, toolchain and capture backend.
SSH carries MCP stdio; no public HTTP server or exposed VM Service port is needed.
Use [mcp.remote.example.json](../tools/automation/mcp.remote.example.json) and replace
the SSH alias and absolute target-host paths. Prepare host-key trust and
noninteractive authentication separately. Keep startup banners/logs off stdout.
The last SSH argument is one command interpreted by the remote login shell.
Keep each path single-quoted, including paths containing spaces; JSON argument
boundaries alone do not quote remote shell arguments. A literal single quote in
a path must be written as `'"'"'` inside the shell command. `exec` replaces the
remote shell so EOF and connection shutdown reach the resident service directly.

The target host needs the complete repository, its own Flutter installation,
resolved dependencies and native helpers. Build on that host. Windows, Linux and
macOS caches and compiled executables must not be copied between platforms.
Use an isolated artifact directory for each client/service instance.

## Source and evidence

The running app uses the target host's project files. Synchronize intended source
changes to a dedicated target-host worktree, then reload that session. Avoid
overwriting unrelated changes or syncing `.git/`, build outputs, SDK caches,
credentials or production app data. The service keeps its Driver connection
resident across requests.

`automation_capture` with `includeImages: true` returns successful original PNGs
inline as MCP image content. Other returned paths belong to the target host;
copy videos/logs using SSH/SCP before opening them locally. Preserve original
frames and masters rather than downloading only lossy previews. Runtime reports
and service descriptors may contain private connection data and stay out of Git.

## Display and device ownership

Linux unattended work should use a dedicated virtual display. macOS capture needs
an actual usable login/display session and Screen Recording authorization; SSH
does not supply either. iOS Simulator work needs an explicit device on the Mac.
Missing permissions or captures remain separate failures even if app screenshots
and interactions succeed.

The Windows-to-Mac SSH stdio path has been exercised with the compiled service:
tool discovery, remote prerequisite inspection, fixture start, inline PNG return,
nonactivation observation and owned stop. This does not establish macOS native
window capture while the host's Screen Recording permission remains ungranted.
