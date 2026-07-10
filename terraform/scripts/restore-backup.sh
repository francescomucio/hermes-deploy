#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Restoring from R2 backup ==="

# Lock shared with hermes-backup: wait for any in-flight backup upload to
# finish (and block new ones) before touching /root/.hermes, so restore and
# backup never race against each other.
exec 200>/var/lock/hermes-backup.lock
if ! flock -w 300 200; then
  echo "Could not acquire backup lock within 5 minutes — a backup/restore is stuck. Aborting."
  exit 1
fi

# Install rclone if not present
if ! command -v rclone &> /dev/null; then
  echo "Installing rclone..."
  curl -s https://rclone.org/install.sh | bash
fi

# Configure rclone for R2
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_ENDPOINT
acl = private
no_check_bucket = true
EOF

# Check if backup exists
BACKUP_SIZE=$(rclone size r2:hermes-backups/latest/ 2>/dev/null | grep "Total size" || echo "")
if [ -z "$BACKUP_SIZE" ]; then
  echo "No backup found in r2:hermes-backups/latest/"
  echo "Skipping restore — starting fresh."
else
  echo "Found backup: $BACKUP_SIZE"

  # Stop containers before restore
  cd /opt/hermes && docker compose stop gateway 2>/dev/null || true

  # Restore from R2 to the volume
  echo "Restoring data..."
  rclone copy r2:hermes-backups/latest/ /root/.hermes/ \
    --transfers 4

  # Fix ownership
  chown -R 10000:10000 /root/.hermes/

  echo "Restored: $BACKUP_SIZE"
fi

# Gateway may be stopped (restore path above) or already running (fresh
# install) — bring it up and wait until docker exec works before touching
# config.yaml. `up -d` is a safe no-op if it's already running.
cd /opt/hermes && docker compose up -d gateway
until docker exec hermes echo ready 2>/dev/null; do
  echo "Waiting for hermes container..."
  sleep 3
done

# Config corrections that must survive a restore — these run here (not in
# setup-hermes.sh) because this script's rclone copy above overwrites
# config.yaml from the R2 backup, which would silently revert any edits
# made earlier in the deploy. Idempotent, safe to run every time.
docker exec hermes sed -i \
  "s|default: anthropic/claude-opus-4.6|default: $OLLAMA_MODEL|; s|base_url: https://openrouter.ai/api/v1|base_url: https://ollama.com/v1|; s|auto_thread: true|auto_thread: false|; s|max_turns: 90|max_turns: 100|" \
  /opt/data/config.yaml
docker exec hermes grep -q '^- browser$' /opt/data/config.yaml || \
  docker exec hermes sed -i '/^- hermes-cli$/a\- browser' /opt/data/config.yaml

# Restart once more to pick up the corrected config
cd /opt/hermes && docker compose restart gateway 2>/dev/null || true

echo "=== Restore complete ==="
