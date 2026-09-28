# Review cron jobs (profile bruno-barbieri)

Three jobs review GitHub PRs as `t4t-chef-bruno`. All three follow the same pattern, learned the hard way in
September 2026: **a script decides, the model only writes.**

- The job's `--script` checks GitHub without any LLM. Nothing to do → its last line is `{"wakeAgent": false}` and
  the model is never called (zero tokens). Before this, the tee-for-transform watcher woke kimi-k3 every 30 minutes
  just to read `[]`: 2.3M tokens in two days, which is what emptied the Ollama weekly limit.
- When there is work, the script puts **everything the review needs into the prompt** (texts or diffs, the
  previous review, one PR per run, oldest first, with a size cap). The model reads once and posts; no tool loops
  (each tool call re-sends the whole context). A full Calvino review went from ~350k tokens to ~150k.
- One PR per run; if `queued_after_this` is not empty the prompt ends with `hermes cron run <id>`, so the next PR
  starts at the next scheduler tick instead of 30 minutes later.

| Job | ID | Script | Model | Prompt |
|---|---|---|---|---|
| oroscopi calvino review | `088fe5d1ca76` | `oroscopi_gate_calvino.py` | glm-5.3-flash | `profiles/bruno-barbieri/cron-prompts/oroscopi-calvino-review.txt` |
| oroscopi bruno review | `46705e540de3` | `oroscopi_gate_bruno.py` | profile default (kimi-k3) | `…/oroscopi-bruno-review.txt` |
| tee-for-transform review watcher | `5a000660d3d4` | `check_review_requests.py` | profile default (kimi-k3) | `…/tee-for-transform-review-watcher.txt` |

The old `oroscopi review watcher` (`7bde623f7741`) is paused: it used kimi-k3 just to decide who should review.

## Who reviews what (viral-sites/oroscopi)

- Label `hermes:calvino` + review requested from `t4t-chef-bruno` → Calvino (texts). Label `hermes:bruno-barbieri`
  → Bruno (code). A PR comment starting with `/calvino` or `/bruno` asks again without a new commit.
- Calvino has no gateway, Discord bot or Ollama key of its own (its gateway service stays down on purpose): the job
  lives in Bruno's profile, pinned to glm-5.3-flash, and the gate passes Calvino's `SOUL.md` as `voice`.
- Daily horoscopes reach Calvino as `vista_giorni` (each day's page, one line per sign) and `vista_segni` (each sign
  across the week): the two readings where repeats show. Other texts come whole; cap 4,500 words per run, so review
  PRs are kept to one week of horoscopes or ~3,500 words.

## Restore on a new server

Scripts go in the profile's `scripts/` dir (Hermes only runs scripts from there); the GitHub token stays in
`/opt/data/profiles/bruno-barbieri/.github_token` and is never printed.

```bash
cp profiles/bruno-barbieri/scripts/*.py /root/.hermes/profiles/bruno-barbieri/scripts/
chown 10000:10000 /root/.hermes/profiles/bruno-barbieri/scripts/*.py
P=profiles/bruno-barbieri/cron-prompts
docker exec -u hermes hermes hermes -p bruno-barbieri cron create "every 30m" "$(cat $P/oroscopi-calvino-review.txt)" \
  --name "oroscopi calvino review" --script oroscopi_gate_calvino.py --model glm-5.3-flash --deliver discord:1553439189402656799
docker exec -u hermes hermes hermes -p bruno-barbieri cron create "every 30m" "$(cat $P/oroscopi-bruno-review.txt)" \
  --name "oroscopi bruno review" --script oroscopi_gate_bruno.py --deliver discord:1553439189402656799
docker exec -u hermes hermes hermes -p bruno-barbieri cron create "every 30m" "$(cat $P/tee-for-transform-review-watcher.txt)" \
  --name "tee-for-transform review watcher" --script check_review_requests.py --deliver origin
```

New jobs get new IDs: update the `hermes cron run <id>` line at the end of each prompt (`cron edit <id> --prompt`).
Check that a gate sleeps: `docker exec -u hermes hermes python3 /opt/data/profiles/bruno-barbieri/scripts/<gate>.py`
must end with `{"wakeAgent": false}` when there is nothing to review. Token use per run is in
`/root/.hermes/profiles/bruno-barbieri/cron/usage_audit.jsonl`.
