#!/usr/bin/env python3
"""Cron gate for tee-for-transform code reviews (t4t-chef-bruno). No LLM.

Finds open, non-draft PRs that request review from t4t-chef-bruno and have not been reviewed on the current head
commit. If there is none (or GitHub is unreachable), the last line is {"wakeAgent": false} and the model is not
woken at all — before this, kimi-k3 was woken every 30 minutes just to read "[]" (~45k tokens a run).

When there is work it prints ONE PR (oldest first) with everything the review needs, so the model reads once and
posts, instead of fetching diffs and files with tools (each tool call re-sends the whole context):
  pr: number, title, url, head_sha, body; previous_review (our last review body, if any);
  files: [{file, status, patch}] up to CHAR_BUDGET characters; not_included_too_long: files left out;
  queued_after_this: other PRs waiting (the prompt re-triggers the job when this list isn't empty).
Never prints the token.
"""
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = "francescomucio/tee-for-transform"
REVIEWER = "t4t-chef-bruno"
TOKEN_PATH = Path("/opt/data/profiles/bruno-barbieri/.github_token")
CHAR_BUDGET = 60000


def api_request(url: str, token: str):
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}", "Accept": "application/vnd.github+json", "User-Agent": "t4t-review-bot"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def nothing_to_do(code: int = 0) -> int:
    print("[]")
    print(json.dumps({"wakeAgent": False}))
    return code


def main() -> int:
    token = TOKEN_PATH.read_text().strip() if TOKEN_PATH.exists() else ""
    if not token:
        print("GitHub token not found or empty", file=sys.stderr)
        return nothing_to_do(1)
    base = f"https://api.github.com/repos/{REPO}"
    query = f"is:open+is:pr+review-requested:{REVIEWER}+repo:{REPO}+draft:false"
    try:
        items = api_request(f"https://api.github.com/search/issues?q={query}", token).get("items", [])
    except Exception as e:
        print(f"GitHub search error: {e}", file=sys.stderr)
        return nothing_to_do(1)

    candidates = []
    for item in items:
        number = item.get("number")
        try:
            pr = api_request(f"{base}/pulls/{number}", token)
            head_sha = pr.get("head", {}).get("sha", "")
            reviews = [r for r in api_request(f"{base}/pulls/{number}/reviews?per_page=100", token)
                       if r.get("user", {}).get("login") == REVIEWER]
            if any(r.get("commit_id") == head_sha for r in reviews):
                continue
            # a top-level comment by us after the last push also counts as "already handled" (as before)
            comments = api_request(f"{base}/issues/{number}/comments?per_page=100", token)
            pushed = pr.get("head", {}).get("repo", {}).get("pushed_at") or pr.get("created_at", "")
            if any(c.get("user", {}).get("login") == REVIEWER and c.get("created_at", "") >= pushed for c in comments):
                continue
            candidates.append((number, pr, reviews[-1] if reviews else None))
        except Exception as e:
            print(f"Skipping PR #{number} due to fetch error: {e}", file=sys.stderr)
    if not candidates:
        return nothing_to_do()

    candidates.sort(key=lambda c: c[0])
    number, pr, last = candidates[0]
    head_sha = pr.get("head", {}).get("sha", "")
    try:
        if last and last.get("commit_id") and last["commit_id"] != head_sha:
            # follow-up round: only what changed since our last review, restricted to the PR's own files
            changed = api_request(f"{base}/compare/{last['commit_id']}...{head_sha}", token).get("files", [])
            in_pr = {f["filename"] for f in api_request(f"{base}/pulls/{number}/files?per_page=100", token)}
            files = [f for f in changed if f["filename"] in in_pr]
        else:
            files = api_request(f"{base}/pulls/{number}/files?per_page=100", token)
    except Exception as e:
        print(f"PR #{number} files error: {e}", file=sys.stderr)
        return nothing_to_do(1)

    included, left_out, used = [], [], 0
    for f in files:
        patch = f.get("patch") or "(binary or too large for the API: open it at the head commit if it matters)"
        if used and used + len(patch) > CHAR_BUDGET:
            left_out.append(f["filename"])
            continue
        included.append({"file": f["filename"], "status": f.get("status"), "patch": patch})
        used += len(patch)
    print(json.dumps({
        "repo": REPO,
        "pr": {"number": number, "title": pr.get("title", ""), "url": pr.get("html_url", ""), "head_sha": head_sha,
               "body": (pr.get("body") or "")[:4000]},
        "round": "follow-up" if last else "first",
        "previous_review": (last.get("body") or "")[:4000] if last else None,
        "files": included,
        "not_included_too_long": left_out,
        "queued_after_this": [c[0] for c in candidates[1:]],
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
