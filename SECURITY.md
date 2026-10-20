# Security policy

This project is early software. Security fixes target the latest source on
`main`; there is no separate long-term support branch yet.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** option on this repository's Security tab
when private reporting is enabled. If that option is unavailable, open an issue
asking `@normalllll` for a private reporting channel, without exploit details,
credentials or screenshots. Do not publish sensitive details until a private
channel has been agreed.

Describe the affected revision, platform, prerequisites, impact and a minimal
reproduction. Remove private screen content, device serials, VM Service URLs and
local paths. No response-time guarantee is currently offered.

## Execution boundary

Driver-enabled fixtures and VM Service endpoints are development interfaces.
Keep them on trusted local connections; do not expose them to the public network
or include test extensions in production entrypoints. The tools execute with the
host user's permissions and write to the requested output paths.

Windows capture requires an explicit HWND/PID match. Android requires an explicit
device ID and fixture identity. Device screenshots include system bars and the
keyboard, and can contain information outside Flutter content. Use a dedicated
test target and review artifacts before sharing. Ownership checks limit cleanup
to recorded sessions; they are not a sandbox for untrusted applications.

Installing the skill does not authorize builds, app launches or captures. Follow
the user's existing scope and the platform instructions in `SKILL.md`.
