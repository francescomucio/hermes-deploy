#!/bin/bash
set -euo pipefail

# Self-hosted Umami: its own compose stack in /opt/umami (umami + postgres +
# cloudflared), separate from the Hermes stack. Reachable only through the
# Cloudflare Tunnel (no host ports beyond 127.0.0.1:3001 for local checks).
# Daily pg_dump to R2 (r2:hermes-backups/umami/); a fresh server with an empty
# database restores the latest dump before Umami starts.

set -a
source /tmp/umami.env
set +a

echo "=== Setting up Umami ($UMAMI_HOSTNAME) ==="

UMAMI_IMAGE="umamisoftware/umami:3.4.1"
POSTGRES_IMAGE="postgres:16-alpine"           # same major as the Railway original
CLOUDFLARED_IMAGE="cloudflare/cloudflared:2026.10.3"
DIR=/opt/umami
R2_PATH="r2:hermes-backups/umami"

mkdir -p "$DIR/cloudflared" "$DIR/backups"
chmod 700 "$DIR"
TUNNEL_FILES_BEFORE=$(cat "$DIR/cloudflared/credentials.json" "$DIR/cloudflared/config.yml" 2>/dev/null | sha256sum)

install -m 600 /tmp/umami-tunnel.json "$DIR/cloudflared/credentials.json"
# cloudflared runs as uid 65532 (nonroot) in its image
chown 65532:65532 "$DIR/cloudflared" "$DIR/cloudflared/credentials.json"
cat > "$DIR/cloudflared/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/credentials.json
no-autoupdate: true
ingress:
  - hostname: $UMAMI_HOSTNAME
    service: http://umami:3000
  - service: http_status:404
EOF

cat > "$DIR/.env" <<EOF
POSTGRES_PASSWORD=$UMAMI_DB_PASSWORD
APP_SECRET=$UMAMI_APP_SECRET
HASH_SALT=$UMAMI_HASH_SALT
EOF
chmod 600 "$DIR/.env"

cat > "$DIR/docker-compose.yml" <<EOF
services:
  db:
    image: $POSTGRES_IMAGE
    restart: unless-stopped
    environment:
      POSTGRES_DB: umami
      POSTGRES_USER: umami
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      TZ: UTC
      PGTZ: UTC
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U umami -d umami"]
      interval: 5s
      timeout: 5s
      retries: 10
    mem_limit: 512m

  umami:
    image: $UMAMI_IMAGE
    restart: unless-stopped
    environment:
      DATABASE_URL: postgresql://umami:\${POSTGRES_PASSWORD}@db:5432/umami
      APP_SECRET: \${APP_SECRET}
      HASH_SALT: \${HASH_SALT}
      DISABLE_TELEMETRY: "1"
    ports:
      - "127.0.0.1:3001:3000"
    depends_on:
      db:
        condition: service_healthy
    mem_limit: 768m

  cloudflared:
    image: $CLOUDFLARED_IMAGE
    restart: unless-stopped
    command: tunnel --config /etc/cloudflared/config.yml run
    volumes:
      - ./cloudflared:/etc/cloudflared:ro
    depends_on:
      - umami
    mem_limit: 128m
EOF

cd "$DIR"
docker compose pull -q

# Fresh database + a dump on R2 → restore it before Umami's first start, so
# Umami migrates the restored schema instead of creating an empty one.
if [ ! -d "$DIR/pgdata" ] || [ -z "$(ls -A "$DIR/pgdata" 2>/dev/null)" ]; then
  docker compose up -d --wait db
  LATEST=$(rclone lsf "$R2_PATH/" 2>/dev/null | grep '\.sql\.gz$' | sort | tail -1 || true)
  if [ -n "$LATEST" ]; then
    echo "Restoring $LATEST from R2..."
    rclone cat "$R2_PATH/$LATEST" | gunzip | docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U umami -d umami
  else
    echo "No Umami dump on R2 — starting with an empty database"
  fi
fi

docker compose up -d --wait
# cloudflared reads its credentials/config only at startup, and `up -d`
# doesn't recreate it when just the mounted files changed (new tunnel/secret).
if [ "$TUNNEL_FILES_BEFORE" != "$(cat "$DIR/cloudflared/credentials.json" "$DIR/cloudflared/config.yml" | sha256sum)" ]; then
  docker compose restart cloudflared
fi

cat > /usr/local/bin/umami-backup <<'BACKUPEOF'
#!/bin/bash
set -euo pipefail
cd /opt/umami
FILE="backups/umami-$(date -u +%Y-%m-%d).sql.gz"
docker compose exec -T db pg_dump -U umami -d umami --no-owner --no-acl | gzip > "$FILE"
ls -1t backups/umami-*.sql.gz | tail -n +8 | xargs -r rm -f   # keep 7 locally
rclone copy "$FILE" r2:hermes-backups/umami/ --quiet
# R2 keeps 30 days
rclone delete r2:hermes-backups/umami/ --min-age 30d --quiet
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) umami backup $FILE" >> /var/log/umami-backup.log
BACKUPEOF
chmod +x /usr/local/bin/umami-backup

CRON_LINE="45 2 * * * /usr/local/bin/umami-backup"
(crontab -l 2>/dev/null | grep -v umami-backup; echo "$CRON_LINE") | crontab -

for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:3001/api/heartbeat >/dev/null && break
  sleep 2
done
curl -sf http://127.0.0.1:3001/api/heartbeat >/dev/null || { echo "Umami not healthy"; docker compose logs --tail 30 umami; exit 1; }

rm -f /tmp/umami.env /tmp/umami-tunnel.json
echo "=== Umami up: https://$UMAMI_HOSTNAME (backups daily 02:45 UTC → $R2_PATH) ==="
