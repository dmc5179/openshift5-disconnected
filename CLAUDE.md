# CLAUDE.md

The project context, sources, conventions, and the item tracker all live in AGENTS.md. Keep that file as the single source of truth and update its tracker as items progress.

@AGENTS.md

## Claude-specific notes
- Use the `/redhat-product` skill (OKP MCP) for Red Hat docs. Use codebase-memory for `main`, and `git show/grep/diff origin/release-*` for the 5.x branches.
- Delegate wide code sweeps to subagents, then spot-check their key claims yourself before recording them as [CODE].
- When an item is resolved, update the AGENTS.md tracker status **and** `ocp5-disconnected-findings.md`.
