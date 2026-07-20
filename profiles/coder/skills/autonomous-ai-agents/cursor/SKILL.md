---
name: cursor
description: "Delegate coding to Cursor CLI (features, PRs) — Cursor edits, Kitt reviews and owns the commit/PR."
version: 1.1.0
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

## Always write the prompt to a file first

**Don't pass the prompt as an inline `-p "..."` string once it has any real content.** Any backtick in a prompt (and code-referencing prompts always have them — `` `functionName()` ``, `` `file.ts` ``) gets interpreted by the shell as command substitution, not literal text. That fails with a confusing `exit 127` ("command not found") that looks nothing like a prompting problem — confirmed in production on a 4-instruction prompt with inline code references.

Instead:

```
write_file(path="~/project/.cursor-prompt.txt", content="<your full prompt, backticks and all — safe here, it's not shell>")
terminal(command="agent -p \"$(cat .cursor-prompt.txt)\" --output-format text --trust --background", workdir="~/project", background=true)
```

Trivial one-line prompts with no code syntax (no backticks, no quotes) are fine inline. Anything referencing actual code, file paths, or function names — use the file.

## Always run in the background for real implementation work

**Hermes's terminal tool has a hard 180-second timeout per foreground command — it kills the process at 180s regardless of whether Cursor is still actively working.** This isn't a Cursor problem, it's the terminal tool's default, and it will bite any implementation task that touches more than one or two small files — confirmed in production (a 4-file change hit exactly 180.2s and got killed mid-run).

Always launch with `background=true` and poll instead of waiting in the foreground:

```
terminal(command="agent -p \"$(cat .cursor-prompt.txt)\" --output-format text --trust", workdir="~/project", background=true)
# returns a session_id

process(action="poll", session_id="<id>")   # check progress
process(action="log", session_id="<id>")    # see output so far
```

Keep polling (every minute or so — don't busy-loop) until it completes. There's no hard ceiling on this beyond the kanban task's own multi-hour staleness timeout, so it's fine to let a genuinely large change take the time it needs — the only thing that kills a background run early is you deciding it's stuck (no output changing across several polls) and killing it yourself.

Only skip `background=true` for trivial, fast, single-line-prompt tasks where a sub-30-second turnaround is expected.

For a read-only plan first, before committing to a full implementation pass (usually fast enough for foreground):
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

Review the diff against your own standards (see `shared/best-practices.md`). If it's not good enough, either fix it directly yourself or send Cursor another pass (same file-prompt + background pattern) with corrective instructions. Only once you're satisfied do you commit, push, and follow the existing kanban PR workflow (create the PR yourself, assign review to bruno-barbieri) — see the "Kanban completion workflow" in your own SOUL.md.

**If Cursor genuinely stalls (no progress across several polls) or you kill it, don't silently fall back to writing the whole thing yourself as if nothing happened.** Say so in your task comment — "Cursor stalled after N minutes, implemented directly instead" — so Bruno's review and anyone reading the task history knows the diff wasn't Cursor-reviewed-by-you-after-Cursor-wrote-it, it's fully hand-written this time.

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

Cursor has native worktree support — no need to manage `git worktree add` by hand. Same file-prompt + background pattern as above, per worktree:

```
terminal(command="agent -p \"$(cat .cursor-prompt-78.txt)\" --worktree fix-78 --trust", workdir="~/project", background=true)
terminal(command="agent -p \"$(cat .cursor-prompt-99.txt)\" --worktree fix-99 --trust", workdir="~/project", background=true)
```

Review, test, and commit each worktree's result the same way as a single task before merging.

## Rules

1. **Cursor edits, you commit** — never let Cursor run `git commit`/`git push`/`gh pr create` itself. Review its diff first, always.
2. **Always pass `--trust`** for headless invocations, or the command hangs waiting for a prompt nobody can answer.
3. **Write real prompts to a file, never inline** — backticks in an inline `-p "..."` string get parsed as shell command substitution, not literal text.
4. **Run implementation work in the background and poll** — the terminal tool's 180s foreground timeout will kill any non-trivial change mid-run otherwise.
5. **`--mode plan` before big changes** — get a plan back before committing to a large, expensive implementation pass.
6. **Don't use the `worker` command** — that turns this box into a compute donor *for* Cursor's cloud, the opposite of what we want here. Not relevant to our use case.
7. **Test before committing** — Cursor's diff isn't done until it passes your own review and the project's tests, per `shared/best-practices.md`.
8. **If Cursor stalls and you fall back to writing it yourself, say so explicitly** in the task comment — don't let it look like a Cursor-authored, Kitt-reviewed diff when it wasn't.
