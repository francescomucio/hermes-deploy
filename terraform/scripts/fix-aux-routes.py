#!/usr/bin/env python3
"""Pin every Hermes auxiliary task to an explicit, authenticated Ollama route.

Why: with `auxiliary.<task>.provider: auto` (the default), each aux task falls
back to a provider discovery chain (main -> fallback -> OpenRouter -> Nous ->
...). On this deployment that chain can reach an endpoint with no Authorization
header and fail with `401 Missing Authentication header` — compression aborts,
smart approvals escalate (each failure is a wasted model call), etc.

Also: aux tasks use their OWN model (`auxiliary.<task>.model`), independent of
the profile's main model. So a costly reviewer (glm-5.3) can keep its brain
while compression/approval/titling run on a cheap fast model.

Idempotent, text-based (no full YAML round-trip, so comments/ordering and the
sed corrections in restore-backup.sh keep working). Safe to run every deploy.

Usage:
    python3 fix-aux-routes.py [CONFIG ...]
"""
from __future__ import annotations

import glob
import re
import sys

TEXT_MODEL = "deepseek-v4.1-flash"
VISION_MODEL = "gemma4:31b"
BASE = "https://ollama.com/v1"
KEY_ENV = "OLLAMA_API_KEY"

# task -> (model, timeout, extra lines)
TASKS: dict[str, tuple[str, int, str]] = {
    "compression": (TEXT_MODEL, 300, ""),
    "vision": (VISION_MODEL, 120, "    download_timeout: 30\n"),
    "approval": (TEXT_MODEL, 60, ""),
    "title_generation": (TEXT_MODEL, 30, ""),
    "mcp": (TEXT_MODEL, 30, ""),
    "skills_hub": (TEXT_MODEL, 30, ""),
    "triage_specifier": (TEXT_MODEL, 120, ""),
    "kanban_decomposer": (TEXT_MODEL, 180, ""),
    "profile_describer": (TEXT_MODEL, 60, ""),
    "web_extract": (TEXT_MODEL, 360, ""),
    "curator": (TEXT_MODEL, 120, ""),
    "monitor": (TEXT_MODEL, 60, ""),
    "tts_audio_tags": (TEXT_MODEL, 30, ""),
}

DEFAULT_CONFIGS = ["/opt/data/config.yaml"] + sorted(
    glob.glob("/opt/data/profiles/*/config.yaml")
)


def block(task: str) -> str:
    model, timeout, extra = TASKS[task]
    return (
        f"  {task}:\n"
        f"    provider: openai\n"
        f"    model: {model}\n"
        f"    base_url: {BASE}\n"
        f"    key_env: {KEY_ENV}\n"
        f"    timeout: {timeout}\n"
        f"{extra}"
    )


def _patch_task(aux_block: str, task: str) -> tuple[str, str]:
    """Insert or replace one task sub-block inside the auxiliary block text."""
    m = re.search(rf"(?m)^  {re.escape(task)}:[ \t]*\n", aux_block)
    if m is None:
        return block(task) + aux_block, "ins"
    after = aux_block[m.end():]
    end = re.search(r"(?m)^  \S|^\S", after)  # next 2-space child or top-level key
    tail_start = m.end() + (end.start() if end else len(after))
    return aux_block[:m.start()] + block(task) + aux_block[tail_start:], "rep"


def patch(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return "missing"

    aux = re.search(r"(?m)^auxiliary:[ \t]*\n", text)
    if aux is None:
        body = "auxiliary:\n" + "".join(block(t) for t in TASKS)
        new = text.rstrip("\n") + "\n\n" + body
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        return "appended"

    start = aux.end()
    rest = text[start:]
    end = re.search(r"(?m)^\S", rest)
    block_end = start + (end.start() if end else len(rest))
    aux_block = text[start:block_end]

    actions = []
    for task in TASKS:
        aux_block, act = _patch_task(aux_block, task)
        actions.append(act)

    new_text = text[:start] + aux_block + text[block_end:]
    if new_text == text:
        return "unchanged"
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    return "patched(" + "".join(actions) + ")"


def main(argv: list[str]) -> int:
    for p in (argv[1:] or DEFAULT_CONFIGS):
        print(f"{patch(p):22} {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
