#!/bin/bash
set -uo pipefail

# Load config
source /tmp/hermes-deploy.env

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

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="/root/.hermes"
BUCKET="r2:hermes-backups"

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

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup complete" >> /var/log/hermes-backup.log
BACKUPEOF
chmod +x /usr/local/bin/hermes-backup

# Run initial backup (allow failure — transient R2 errors shouldn't block deploy)
echo "Running initial backup..."
/usr/local/bin/hermes-backup || echo "Initial backup had errors (will retry on next cron run)"

# Set up hourly cron
CRON_LINE="*/30 * * * * /usr/local/bin/hermes-backup"
(crontab -l 2>/dev/null | grep -v hermes-backup; echo "$CRON_LINE") | crontab -

echo "=== Backups configured (hourly to R2) ==="
