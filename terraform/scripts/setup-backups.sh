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

# Checkpoint SQLite WAL files so all data is in the main .db before sync
find "$BACKUP_DIR" -name "*.db" -type f 2>/dev/null | while read -r db; do
  sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
done

# Sync data to R2 (excludes caches and temp files)
rclone sync "$BACKUP_DIR" "$BUCKET/latest/" \
  --exclude "cache/**" \
  --exclude ".cache/**" \
  --exclude "image_cache/**" \
  --exclude "audio_cache/**" \
  --exclude "logs/**" \
  --exclude "*.db-shm" \
  --exclude "*.db-wal" \
  --exclude "lost+found/**" \
  --transfers 4 \
  --quiet

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
BACKUPEOF
chmod +x /usr/local/bin/hermes-backup

# Run initial backup (allow failure — transient R2 errors shouldn't block deploy)
echo "Running initial backup..."
/usr/local/bin/hermes-backup || echo "Initial backup had errors (will retry on next cron run)"

# Set up hourly cron
CRON_LINE="*/30 * * * * /usr/local/bin/hermes-backup"
(crontab -l 2>/dev/null | grep -v hermes-backup; echo "$CRON_LINE") | crontab -

echo "=== Backups configured (every 30 min to R2) ==="
