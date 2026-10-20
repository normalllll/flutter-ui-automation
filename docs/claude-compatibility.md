# Claude Code compatibility

Static review date: 2026-10-17. Scope: the local skill package on native Windows.
Claude Code was not started, including diagnostic, version, or non-interactive
commands. No personal or project-level skill installation was performed.

## Findings

| Area | Static finding |
| --- | --- |
| Package identity | Directory and frontmatter name are `flutter-ui-automation`, using a lowercase hyphenated identifier. |
| Shared skill format | `SKILL.md` begins with YAML `name` and `description`; instructions and linked resources are bundled in the package. |
| Execution path | The Driver/Python/C++ workflow does not require a Codex-only tool. MCP inspection is optional. |
| Host integration | `agents/openai.yaml` is Codex metadata. Claude execution does not depend on its fields. |
| Repository guidance | `CLAUDE.md` imports `AGENTS.md` without duplicating the rules. |
| Paths | Python tools resolve their package root from `__file__`; no checkout-specific absolute path is required. |
| Permissions | No hooks or tool pre-approval lists were added. The host's execution permissions still apply. |
| Native dependencies | Windows Python, Flutter's Windows toolchain, FFmpeg, and an interactive Windows session remain prerequisites. |

Claude Code's documented skill locations include
`~/.claude/skills/flutter-ui-automation/` and
`<project>/.claude/skills/flutter-ui-automation/`. Install the complete package,
then invoke `/flutter-ui-automation`. A checkout elsewhere is not automatically
registered. These locations and invocation behavior follow the
[official skill documentation](https://code.claude.com/docs/en/skills).

The root `CLAUDE.md` uses the documented `@AGENTS.md` import, including for
versions or configurations that do not load AGENTS.md directly. See
[instruction-file imports](https://code.claude.com/docs/en/memory#share-one-file-with-other-coding-tools).

The file layout and portable frontmatter follow the
[Agent Skills specification](https://agentskills.io/specification).
For the execution environment, consult the
[native Windows setup documentation](https://code.claude.com/docs/en/setup#set-up-on-windows).

## Review boundary

This establishes format and execution-path compatibility by inspection. It does
not establish skill discovery, model behavior, or permissions inside a live
Claude session. The earlier fixture results used a separate agent environment.
No Claude runtime acceptance is claimed.

The native capture workflow cannot run entirely inside a Linux container or a
cloud-only session. Use a native Windows host with the required desktop and tools.
