#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Setting up R2 backups ==="

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

# Test connection
echo "Testing R2 connection..."
rclone lsd r2:hermes-backups 2>&1 || rclone mkdir r2:hermes-backups

# Create backup script
cat > /usr/local/bin/hermes-backup <<'BACKUPEOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/root/.hermes"
BUCKET="r2:hermes-backups"

# Lock shared with restore-backup.sh: skip if a backup/restore is already in
# flight rather than racing rclone against itself (past incident: cron fired
# a second sync while a manual one was still running, and a deploy's restore
# raced against a cron backup — both hitting /root/.hermes concurrently).
exec 200>/var/lock/hermes-backup.lock
if ! flock -n 200; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) skipped (backup/restore already in progress)" >> /var/log/hermes-backup.log
  exit 0
fi

# Checkpoint SQLite WAL files so all data is in the main .db before sync
find "$BACKUP_DIR" -name "*.db" -type f 2>/dev/null | while read -r db; do
  sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
done

# Sync data to R2 (excludes caches, temp files, and reproducible artifacts —
# venvs/node_modules/build caches don't need backing up, they blow up the
# file count and slow every sync down; ~178K files/4.5GB before this).
#
# NOTE on `**/.local/share/uv/**`-style patterns: confirmed live that
# rclone's `**/` prefix doesn't reliably match a multi-segment literal
# path (`.local/share/uv`) the way it does a single-segment one
# (`.venv`, `__pycache__`) — that pattern silently matched nothing, so
# .local/share/uv (7472 files, a uv-managed Python distribution) kept
# reappearing in the R2 backup no matter how many times it was purged
# manually. Fixed by dropping the `**/` prefix for paths known to always
# sit at the backup root (`.local/share/uv/**`, not `**/.local/...`) —
# confirmed empirically to actually match, unlike the broken version.
rclone sync "$BACKUP_DIR" "$BUCKET/latest/" \
  --exclude "cache/**" \
  --exclude ".cache/**" \
  --exclude "image_cache/**" \
  --exclude "audio_cache/**" \
  --exclude "logs/**" \
  --exclude "*.db-shm" \
  --exclude "*.db-wal" \
  --exclude "lost+found/**" \
  --exclude "**/.venv/**" \
  --exclude "**/venv/**" \
  --exclude "**/__pycache__/**" \
  --exclude "**/.ruff_cache/**" \
  --exclude "**/.pytest_cache/**" \
  --exclude "**/.mypy_cache/**" \
  --exclude "**/node_modules/**" \
  --exclude "**/.cache/**" \
  --exclude ".local/share/uv/**" \
  --exclude ".venv*/**" \
  --exclude "lsp/**" \
  --exclude "google-venv/**" \
  --exclude "data-berlin-jobs/**" \
  --exclude "tee-for-transform/**" \
  --exclude "t4t-review/**" \
  --delete-excluded \
  --transfers 4 \
  --quiet
# The three excludes above are coder-profile project directories confirmed
# to be regularly pushed to GitHub (2026-07-10) — R2 backup is redundant
# for them, git remote is the real safety net. No structural convention
# catches these automatically (they sit at the backup root alongside real
# Hermes state, not under a dedicated projects/ dir) — if the coder profile
# starts a new large project that should stay off R2, it needs its own
# exclude line added here.

# Weekly snapshot (keeps last 4 weeks of recovery points)
DOW=$(date -u +%u)
HOUR=$(date -u +%H)
if [ "$DOW" = "7" ] && [ "$HOUR" = "03" ]; then
  WEEK=$(date -u +%Y-W%V)
  rclone copy "$BUCKET/latest/" "$BUCKET/weekly/$WEEK/" --transfers 4 --quiet

  # Prune snapshots older than 4 weeks
  rclone lsd "$BUCKET/weekly/" 2>/dev/null | awk '{print $NF}' | sort | head -n -4 | while read -r old; do
    rclone purge "$BUCKET/weekly/$old/" 2>/dev/null || true
  done
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup complete" >> /var/log/hermes-backup.log

# Status file visible to Hermes profiles (BACKUP_DIR is bind-mounted into
# containers at /opt/data) — lets Claudiano/etc check backup health without
# needing host/Docker access.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup complete" > "$BACKUP_DIR/.backup-status"
BACKUPEOF
chmod +x /usr/local/bin/hermes-backup

# Run initial backup (allow failure — transient R2 errors shouldn't block deploy)
echo "Running initial backup..."
/usr/local/bin/hermes-backup || echo "Initial backup had errors (will retry on next cron run)"

# Set up hourly cron
CRON_LINE="*/30 * * * * /usr/local/bin/hermes-backup"
(crontab -l 2>/dev/null | grep -v hermes-backup; echo "$CRON_LINE") | crontab -

echo "=== Backups configured (every 30 min to R2) ==="
