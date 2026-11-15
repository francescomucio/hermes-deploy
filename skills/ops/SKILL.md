---
name: hermes-ops
description: "Manage Hermes deployment: backups, health checks, restarts, profile deployment, log inspection."
version: 1.0.0
author: hermes-deploy
metadata:
  hermes:
    tags: [ops, backup, deploy, health, maintenance]
---

# Hermes Operations

Operational commands for managing this Hermes deployment.

## Backup

Force a backup to R2 right now:
```bash
/usr/local/bin/hermes-backup
```

Check last backup time:
```bash
tail -5 /var/log/hermes-backup.log
```

Check backup size on R2:
```bash
rclone size r2:hermes-backups
```

Backups run automatically once a day (03:00 UTC) via cron.

## Health Check

Check if all services are running:
```bash
docker ps --format "{{.Names}} {{.Status}} {{.Image}}"
```

Check Discord connection:
```bash
grep "Connected as" /root/.hermes/logs/gateway.log | tail -1
```

Check gateway process count (should be exactly 1):
```bash
docker exec hermes ps aux | grep "hermes gateway" | grep -v grep | wc -l
```

Check disk usage:
```bash
du -sh /root/.hermes/
```

## Restart

Restart the gateway (picks up config.yaml changes):
```bash
cd /opt/hermes && docker compose restart gateway
```

Full restart (both containers):
```bash
cd /opt/hermes && docker compose down && docker compose up -d
```

After restart, the gateway service needs to be started:
```bash
docker exec hermes /command/s6-svc -u /run/service/gateway-default
```

## Logs

Gateway log (Discord connections, messages, errors):
```bash
docker exec hermes tail -50 /opt/data/logs/gateway.log
```

Error log:
```bash
docker exec hermes cat /opt/data/logs/errors.log | tail -20
```

Gateway s6 service log:
```bash
docker exec hermes cat /opt/data/logs/gateways/default/current
```

## Profile Deployment

After editing a profile in /opt/hermes-deploy/profiles/:

1. Copy to live location:
```bash
cp /opt/hermes-deploy/profiles/default/SOUL.md /root/.hermes/SOUL.md
```

For other profiles:
```bash
cp /opt/hermes-deploy/profiles/<name>/SOUL.md /root/.hermes/profiles/<name>/SOUL.md
```

2. Commit and push:
```bash
cd /opt/hermes-deploy && git add -A && git commit -m "description" && git push
```

SOUL.md changes take effect immediately — no restart needed.

## Deploy Repo

Changes pushed to GitHub are auto-synced every 5 minutes via cron. To sync immediately:
```bash
/usr/local/bin/hermes-sync
```

Check sync log:
```bash
tail -5 /var/log/hermes-sync.log
```

Pull latest manually:
```bash
cd /opt/hermes-deploy && git pull
```

Check current status:
```bash
cd /opt/hermes-deploy && git log --oneline -5
```

## Update Hermes

The Hermes Docker image version is pinned in `terraform.tfvars` as `hermes_image_tag`. To update:

1. Check available versions: https://hub.docker.com/r/nousresearch/hermes-agent/tags
2. Update `hermes_image_tag` in tfvars on the local machine
3. Run `terraform apply` — this re-runs the setup script with the new image

Do NOT update the image manually on the server — Terraform manages it.

Check current version:
```bash
docker exec hermes hermes --version
```

## web_search returns 0 results (SearXNG engines blocked)

Symptom: `web_search` succeeds but returns 0 hits for ordinary queries. Network is fine
(APIs, curl, RSS all work) — the engines are blocked, not the host.

Diagnose from inside the container:
```bash
curl -s -G http://127.0.0.1:8080/search \
  --data-urlencode "q=test query" --data-urlencode "format=json" | head -c 800
```
`unresponsive_engines` names the blocked ones (`CAPTCHA`, `Suspended: CAPTCHA`, `too many
requests`). `google` fails *silently* (0 results, no error), so always read that field.

Then probe which engines still answer from this IP:
```bash
curl -s -G http://127.0.0.1:8080/search --data-urlencode "q=!szn test query" --data-urlencode "format=json"
curl -s -G http://127.0.0.1:8080/search --data-urlencode "q=test query" --data-urlencode "format=json" --data-urlencode "categories=web"
curl -s http://127.0.0.1:8080/config   # enabled engines, categories, shortcuts
```
An `engines=<name>` param only works for engines already in the queried category; a `!shortcut`
bang works for any loaded engine, so it is the reliable per-engine probe.

Two fix paths:
- **Host side (needs Docker — no profile has the socket):**
  `ssh root@<server> 'bash -s' < terraform/scripts/fix-searxng-engines.sh` re-writes
  `/opt/searxng/settings.yml` (seznam/bing carry `general`, blocked engines `disabled: true`),
  restarts SearXNG and verifies with three queries. SearXNG reads settings only at start.
- **Agent side (no host access):** route search to a keyless backend that answers from this IP:
  `hermes -p <profile> config set web.search_backend exa` (anonymous Exa tier; the keyless ring
  fails over to parallel/firecrawl/keenable on rate limits). Apply to the root config **and**
  every profile config, then mirror into `/opt/hermes-deploy` — the repo is the deploy source of
  truth and a redeploy overwrites live configs. Set per-profile values with
  `hermes -p <name> config set`, not by editing the file: the file tools refuse to write Hermes
  configs, and `HERMES_PROFILE=<x> hermes config path` still prints the root config.
- Verify with real queries (trivial, technical, current-events) through `web_search` itself.
  "It should work now" is not a verification.

## Important Notes

- The server's local disk is **not persistent** — all data is backed up to R2 once a day (03:00 UTC).
- Always force a backup before any destructive operation.
- `terraform apply` is NOT available on this server — infrastructure changes must be done from the local machine.
- The gateway service is managed by s6 supervisor. After container restarts, it needs `s6-svc -u` to start.
