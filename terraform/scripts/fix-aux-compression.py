#!/usr/bin/env python3
"""Pin auxiliary.compression to the explicit Ollama route in every Hermes config.

Why: with `auxiliary.compression.provider: auto` (the default), compression
falls back to a provider discovery chain (main -> fallback -> OpenRouter ->
Nous -> ...). On this deployment that chain can reach an endpoint without an
Authorization header and abort with `401 Missing Authentication header` —
context compression never runs. An explicit provider + base_url + key_env makes
the route deterministic and authenticated.

Idempotent, text-based (no full YAML round-trip, so comments/ordering and the
sed corrections elsewhere in restore-backup.sh keep working). Safe to run on
every deploy.

Usage:
    python3 fix-aux-compression.py [CONFIG ...]

With no args it patches the root config and every profile config under the
standard locations (/opt/data/config.yaml and /opt/data/profiles/*/config.yaml).
"""
from __future__ import annotations

import glob
import re
import sys

BLOCK = """  compression:
    provider: openai
    model: deepseek-v4.1-flash
    base_url: https://ollama.com/v1
    key_env: OLLAMA_API_KEY
    timeout: 300
"""

DEFAULT_CONFIGS = ["/opt/data/config.yaml"] + sorted(
    glob.glob("/opt/data/profiles/*/config.yaml")
)


def patch(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return "missing"

    aux = re.search(r"(?m)^auxiliary:[ \t]*\n", text)
    if aux is None:
        new = text.rstrip("\n") + "\n\nauxiliary:\n" + BLOCK
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        return "appended-auxiliary"

    start = aux.end()
    rest = text[start:]
    end = re.search(r"(?m)^\S", rest)  # next top-level key ends the auxiliary block
    block_end = start + (end.start() if end else len(rest))
    aux_block = text[start:block_end]

    cm = re.search(r"(?m)^  compression:[ \t]*\n", aux_block)
    if cm is None:
        new_aux = BLOCK + aux_block
        action = "inserted-compression"
    else:
        cs = cm.start()
        after = aux_block[cm.end():]
        ce = re.search(r"(?m)^  \S|^\S", after)  # next 2-space child or top-level key
        cend = cm.end() + (ce.start() if ce else len(after))
        new_aux = aux_block[:cs] + BLOCK + aux_block[cend:]
        action = "replaced-compression"

    new_text = text[:start] + new_aux + text[block_end:]
    if new_text == text:
        return "unchanged"
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    return action


def main(argv: list[str]) -> int:
    paths = argv[1:] or DEFAULT_CONFIGS
    for p in paths:
        print(f"{patch(p):22} {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
