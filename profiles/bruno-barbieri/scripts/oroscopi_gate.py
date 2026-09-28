#!/usr/bin/env python3
"""Cron gate for viral-sites/oroscopi reviews. No LLM: decides from GitHub whether a role has work, and if so
hands the model everything it needs, already fetched, so the review is one read and one post (no tool loops:
each tool call re-sends the whole context, and a 35-file review blew the Ollama weekly limit on 27/09).

Usage: oroscopi_gate.py calvino|bruno
A PR is work for a role when it is open, review is requested from t4t-chef-bruno, AND either it carries the role's
label (hermes:calvino / hermes:bruno-barbieri) or a comment newer than the last review starts with /calvino or /bruno.
Already reviewed at the current head = no work (unless a newer /role command asks again).
One PR per run, oldest first. First round: every file of the PR; later rounds: only files changed since the last
review. Calvino gets the full text of changed content files (up to WORD_BUDGET words); Bruno gets the diff
(up to CHAR_BUDGET characters). What doesn't fit is listed, not included.
When there is nothing to do the last line is {"wakeAgent": false} and no model is called. Never prints the token.
"""
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "viral-sites/oroscopi"
REVIEWER = "t4t-chef-bruno"
TOKEN_PATH = Path("/opt/data/profiles/bruno-barbieri/.github_token")
SOUL = {"calvino": Path("/opt/data/profiles/calvino/SOUL.md")}
ROLES = {"calvino": ("hermes:calvino", "/calvino"), "bruno": ("hermes:bruno-barbieri", "/bruno")}
WORD_BUDGET = 4500     # ~ one week of daily horoscopes (84 lines) or 3-4 articles
CHAR_BUDGET = 40000


def api(url, token, raw=False):
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}", "User-Agent": "oroscopi-gate",
        "Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode("utf-8")
    return body if raw else json.loads(body)


def sleep_gate(reason):
    print(json.dumps({"reason": reason}))
    print(json.dumps({"wakeAgent": False}))
    return 0


def find_work(role, token, base):
    label, command = ROLES[role]
    work = []
    for pr in api(f"{base}/pulls?state=open&per_page=50", token):
        if REVIEWER not in [u["login"] for u in pr.get("requested_reviewers", [])]:
            continue
        n, head = pr["number"], pr["head"]["sha"]
        try:
            reviews = [r for r in api(f"{base}/pulls/{n}/reviews?per_page=100", token) if r["user"]["login"] == REVIEWER]
            last = reviews[-1] if reviews else None
            since = last["submitted_at"] if last else ""
            comments = api(f"{base}/issues/{n}/comments?per_page=100", token)
            asked = any(c["body"].strip().lower().startswith(command) and c["created_at"] > since for c in comments)
            if not (label in [l["name"] for l in pr.get("labels", [])] or asked):
                continue
            if last and last["commit_id"] == head and not asked:
                continue  # already reviewed this exact version
            work.append({"pr": pr, "last": last})
        except Exception as e:
            print(f"skip PR #{n}: {e}", file=sys.stderr)
    return sorted(work, key=lambda w: w["pr"]["number"])


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ROLES:
        print("usage: oroscopi_gate.py calvino|bruno", file=sys.stderr)
        return sleep_gate("bad usage")
    role = sys.argv[1]
    token = TOKEN_PATH.read_text().strip() if TOKEN_PATH.exists() else ""
    if not token:
        return sleep_gate("no token")
    base = f"https://api.github.com/repos/{REPO}"
    try:
        work = find_work(role, token, base)
    except Exception as e:  # network/API trouble: stay asleep, try next tick
        print(f"list PRs failed: {e}", file=sys.stderr)
        return sleep_gate("github unavailable")
    if not work:
        return sleep_gate(f"no {role} work")

    pr, last = work[0]["pr"], work[0]["last"]
    n, head = pr["number"], pr["head"]["sha"]
    if last and last["commit_id"] != head:
        files = api(f"{base}/compare/{last['commit_id']}...{head}", token).get("files", [])
        # a merge of main into the branch shows main's files too: keep only what the PR itself changes
        in_pr = {f["filename"] for f in api(f"{base}/pulls/{n}/files?per_page=100", token)}
        files = [f for f in files if f["filename"] in in_pr]
    else:
        files = api(f"{base}/pulls/{n}/files?per_page=100", token)
    files = [f for f in files if f["status"] != "removed"]

    out = {"role": role, "repo": REPO, "number": n, "title": pr["title"], "url": pr["html_url"],
           "round": "follow-up" if last else "first", "pr_description": pr.get("body") or "",
           "queued_after_this": [w["pr"]["number"] for w in work[1:]]}
    if last:
        out["your_previous_review"] = last.get("body", "")[:3000]
    included, left_out, used = [], [], 0
    for f in files:
        name = f["filename"]
        if role == "calvino":
            if not (name.startswith("content/") and name.endswith(".md")):
                continue
            text = api(f"{base}/contents/{urllib.parse.quote(name)}?ref={head}", token, raw=True)
            size = len(text.split())
            if used and used + size > WORD_BUDGET:
                left_out.append(name)
                continue
            included.append({"file": name, "text": text})
        else:
            text = f.get("patch", "(binary or too large)")
            size = len(text)
            if used and used + size > CHAR_BUDGET:
                left_out.append(name)
                continue
            included.append({"file": name, "status": f["status"], "patch": text})
        used += size
    if not included and not left_out:
        return sleep_gate(f"PR #{n} has nothing for {role}")
    # daily horoscopes as `npm run vista` shows them: one line per horoscope, by day (the page) and by sign (the week
    # in a row, where "la Bilancia ha sempre appuntamenti" shows); other files stay as full text
    daily = [f for f in included if re.search(r"content/\w+/daily/\d{4}-\d{2}-\d{2}\.md$", f["file"])]
    if daily:
        rows = [(f["file"][-13:-3], s, x) for f in daily for s, x in re.findall(r"^## (\S+)\n(.+)$", f.get("text", ""), re.M)]
        dm = lambda d: f"{d[8:10]}/{d[5:7]}"
        out["vista_giorni"] = "\n".join(f"{dm(d)} {s:<10} {x}" for d, s, x in rows)
        order = list(dict.fromkeys(s for _, s, _ in rows))
        out["vista_segni"] = "\n\n".join(s + "\n" + "\n".join(f"{dm(d)} {x}" for d, s2, x in rows if s2 == s) for s in order)
        included = [f for f in included if f not in daily]
    out["files"] = included
    out["not_included_too_long"] = left_out
    if role in SOUL and SOUL[role].exists():
        out["voice"] = SOUL[role].read_text()
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
