# Changelog

## 0.2.0 — unreleased

- Resident Dart MCP embedding the official Dart/Flutter server, with persistent
  Driver sessions, an authenticated CLI broker, jobs and cancellation.
- Shared Windows/Android interaction, capture, recording and verification tools;
  source hot reload/restart, explicit target identity and owned-session recovery.
- Per-channel capture evidence, integer Windows native frame rates, independent
  Android keyboard checks, and strict lease/attach ownership validation.
- Logical-display panel selection for Fold capture and an isolated BooruFlow
  Android Debug integration with live source reload.
- Foreground/focus observations remain separate from capture acceptance;
  background-only checks require an established background interval.
- Linux/Windows headless CI, compiled MCP startup without SDK environment hints,
  and consolidated current workflow/validation documentation.

## 0.1.0 — unreleased

- Windows Flutter Driver interactions, app PNG capture and independent scoped
  WGC/PrintWindow capture with optional presentation verification.
- Original frame retention, FFV1/BGRA master verification and MP4 viewing copies.
- Android fixture sessions with explicit device selection, identity validation,
  ADB display capture and real lifecycle checks.
- Shared agent skill, platform integration references and historical validation
  notes, including the limitations of device encoding and display-off capture.
- Public repository metadata, GPL-3.0-or-later licensing, contributor/security
  guidance, repository checks and GitHub Actions CI.

This initial source snapshot used the Python CLI. The resident MCP is introduced
in 0.2.0; no hosted service is included.
