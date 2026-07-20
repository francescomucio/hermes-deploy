---
name: cursor
description: "Delegate coding to Cursor CLI (features, PRs) — Cursor edits, Kitt reviews and owns the commit/PR."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Coding-Agent, Cursor, Code-Review, Refactoring]
    related_skills: [codex, claude-code, hermes-agent]
---

# Cursor CLI

Delegate coding tasks to [Cursor Agent](https://cursor.com/docs/cli) via the Hermes terminal. Cursor is an autonomous coding agent CLI, backed by frontier models.

## When to use

- Building features
- Refactoring
- Bug fixes
- Anything that requires writing or editing real code

**Cursor writes the diff. You (Kitt) review it, run tests, write the commit message and PR description, and own the commit/PR — never let Cursor commit or open the PR itself.** This keeps you the actual author of what ships, not a passthrough.

## Prerequisites

- The `agent` CLI is already installed at `/opt/data/.local/bin/agent` (in PATH — just run `agent`)
- Auth is via `CURSOR_API_KEY`, already set in the environment — no `agent login` needed
- **Always pass `--trust`** when invoking headlessly (`-p`/`--print` mode) — without it, Cursor blocks on a workspace-trust prompt that never resolves in a non-interactive context
- Unlike Codex, Cursor's `-p`/`--print` mode does **not** need `pty=true` — it's built for scripted, non-interactive use

## One-Shot Tasks

```
terminal(command="agent -p \"Add dark mode toggle to settings\" --output-format text --trust", workdir="~/project")
```

For a read-only plan first, before committing to a full implementation pass:
```
terminal(command="agent -p \"Propose a plan for adding dark mode\" --mode plan --output-format text --trust", workdir="~/project")
```

## After Cursor Finishes: Your Review Step

Cursor only edits files — it does not commit or push. Once it's done:

```
terminal(command="git diff", workdir="~/project")
terminal(command="git status", workdir="~/project")
# run the project's test suite here
```

Review the diff against your own standards (see `shared/best-practices.md`). If it's not good enough, either fix it directly yourself or send Cursor another `agent -p "..." --trust` pass with corrective instructions. Only once you're satisfied do you commit, push, and follow the existing kanban PR workflow (create the PR yourself, assign review to bruno-barbieri) — see the "Kanban completion workflow" in your own SOUL.md.

## Key Flags

| Flag | Effect |
|------|--------|
| `-p, --print` | Non-interactive mode — prints output, exits when done. Required for headless use. |
| `--trust` | Skip the workspace-trust prompt (required in headless mode; no other effect) |
| `--mode plan` | Read-only planning — analyze and propose, no edits. Good for previewing before committing to a large run. |
| `--mode ask` | Read-only Q&A — for explanations, not implementation |
| `--output-format text\|json\|stream-json` | Output format (only with `-p`) |
| `--model <model>` | Override the underlying model for this invocation (e.g. `gpt-5`, `sonnet-4-thinking`) |
| `-f, --force` / `--yolo` | Bypass command-level approval prompts too, not just workspace trust — broader than `--trust` alone. Only reach for this if `--trust` isn't enough for a specific task. |
| `-w, --worktree [name]` | Run in an isolated git worktree at `~/.cursor/worktrees/<repo>/<name>` — built-in equivalent of manual `git worktree add`, useful for parallel tasks |
| `--resume [chatId]` / `--continue` | Resume a previous Cursor session |

## Parallel Work with Worktrees

Cursor has native worktree support — no need to manage `git worktree add` by hand:

```
terminal(command="agent -p \"Fix issue #78: <description>\" --worktree fix-78 --trust", workdir="~/project", background=true)
terminal(command="agent -p \"Fix issue #99: <description>\" --worktree fix-99 --trust", workdir="~/project", background=true)
```

Review, test, and commit each worktree's result the same way as a single task before merging.

## Rules

1. **Cursor edits, you commit** — never let Cursor run `git commit`/`git push`/`gh pr create` itself. Review its diff first, always.
2. **Always pass `--trust`** for headless invocations, or the command hangs waiting for a prompt nobody can answer.
3. **`--mode plan` before big changes** — get a plan back before committing to a large, expensive implementation pass.
4. **Don't use the `worker` command** — that turns this box into a compute donor *for* Cursor's cloud, the opposite of what we want here. Not relevant to our use case.
5. **Test before committing** — Cursor's diff isn't done until it passes your own review and the project's tests, per `shared/best-practices.md`.
