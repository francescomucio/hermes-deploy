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

Backups run automatically every 30 minutes via cron.

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

Pull latest changes from GitHub:
```bash
cd /opt/hermes-deploy && git pull
```

Check current status:
```bash
cd /opt/hermes-deploy && git log --oneline -5
```

## Update Hermes

Pull the latest Docker image and restart:
```bash
cd /opt/hermes && docker compose pull && docker compose down && docker compose up -d
```

Wait for initialization, then start the gateway:
```bash
sleep 15 && docker exec hermes /command/s6-svc -u /run/service/gateway-default
```

## Important Notes

- The server's local disk is **not persistent** — all data is backed up to R2 every 30 minutes.
- Always force a backup before any destructive operation.
- `terraform apply` is NOT available on this server — infrastructure changes must be done from the local machine.
- The gateway service is managed by s6 supervisor. After container restarts, it needs `s6-svc -u` to start.
