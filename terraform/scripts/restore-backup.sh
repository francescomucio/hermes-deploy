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
# Fixed Camofox identity so browser_navigate reuses the persisted Reddit
# login (see reddit-login.py) instead of a fresh random session each task.
docker exec hermes sed -i "s|user_id: ''|user_id: hermes-reddit|" /opt/data/config.yaml

# A Hermes profile can carry its own FULL config.yaml that shadows the root
# one entirely for that profile's behavior — not merged key-by-key.
# researcher's does (a ~600-line standalone copy, not a small override),
# which is how Barbero silently ended up on a different model/max_turns/
# auto_thread AND an unauthenticated Camofox identity despite every
# correction above landing correctly in the root file. Propagate the same
# corrected values to every profile config.yaml that defines them — first
# occurrence only, so unrelated nested keys with the same name (e.g.
# goals.max_turns) aren't touched — so this class of drift can't recur for
# any profile, present or future, without a manual patch each time.
ROOT_MODEL=$(docker exec hermes sed -n '0,/^  default: /{s/^  default: //p}' /opt/data/config.yaml)
ROOT_MAX_TURNS=$(docker exec hermes sed -n '0,/^  max_turns: /{s/^  max_turns: //p}' /opt/data/config.yaml)
ROOT_AUTO_THREAD=$(docker exec hermes sed -n '0,/^  auto_thread: /{s/^  auto_thread: //p}' /opt/data/config.yaml)
for pc in $(docker exec hermes sh -c 'ls /opt/data/profiles/*/config.yaml 2>/dev/null' || true); do
  docker exec hermes sed -i "0,/^  default: /{s|^  default: .*|  default: $ROOT_MODEL|}" "$pc"
  docker exec hermes sed -i "0,/^  max_turns: /{s|^  max_turns: .*|  max_turns: $ROOT_MAX_TURNS|}" "$pc"
  docker exec hermes sed -i "0,/^  auto_thread: /{s|^  auto_thread: .*|  auto_thread: $ROOT_AUTO_THREAD|}" "$pc"
  docker exec hermes sed -i "s|user_id: ''|user_id: hermes-reddit|" "$pc"
done

# Narrow, Reddit-only credentials file for reddit-login.py — deliberately
# NOT /tmp/hermes-deploy.env, which also holds Discord tokens, R2 keys, the
# email password and API keys. Claudiano/Barbero can safely run
# reddit-login.py themselves (it only ever reads this file), without ever
# needing to touch the shared secrets blob. Lives in the volume so it
# survives restarts and is visible at /opt/data/.reddit-credentials inside
# the container as well as /root/.hermes/.reddit-credentials on the host.
if [ -n "${REDDIT_USERNAME:-}" ] && [ -n "${REDDIT_PASSWORD:-}" ]; then
  cat > /root/.hermes/.reddit-credentials <<EOF
REDDIT_USERNAME=$REDDIT_USERNAME
REDDIT_PASSWORD=$REDDIT_PASSWORD
EOF
  chmod 600 /root/.hermes/.reddit-credentials
  chown 10000:10000 /root/.hermes/.reddit-credentials
fi

# Fresh Camofox installs (marker left by setup-hermes.sh) need an initial
# Reddit login — the credentials file above just became available.
if [ -f /tmp/camofox-needs-reddit-login ]; then
  echo "Logging Camofox into Reddit..."
  python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py || \
    echo "Reddit login failed — run reddit-login.py manually to retry"
  rm -f /tmp/camofox-needs-reddit-login
fi

# Restart once more to pick up the corrected config
cd /opt/hermes && docker compose restart gateway 2>/dev/null || true

echo "=== Restore complete ==="
