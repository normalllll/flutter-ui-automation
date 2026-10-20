# Repository guidance

This repository packages the `flutter-ui-automation` skill, independent Windows capture
tools, and a Flutter verification fixture. Keep the fixture under
`examples/capture_lab/`; do not turn the repository root into a Flutter project.

For Flutter GUI checks, read `SKILL.md` and prefer application-internal controls
and scoped capture. Do not default to Computer Use, global input, or foreground
activation. Missing prerequisites must be reported rather than bypassed with
desktop control. Respect the user's existing launch/build/capture authorization.

Keep normal app behavior separate from the test binding. Preserve actual Windows
foreground observations and last platform events; simulated foreground status
must remain explicit and reversible. Do not commit generated build artifacts,
recordings, transient session URLs or lock files.

Android sessions require an explicit device ID and fixture instance identity.
Preserve real mobile lifecycle/focus and leave Windows simulation in its adapter.
Keep app content and system capture evidence separate, and do not label Android
screenrecord output as a lossless display master. Mobile runtime acceptance
requires authorized device execution and inspection of the retained artifacts.
