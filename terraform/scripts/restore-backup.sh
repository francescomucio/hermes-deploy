#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Restoring from R2 backup ==="

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
  exit 0
fi

echo "Found backup: $BACKUP_SIZE"

# Stop containers before restore
cd /opt/hermes && docker compose stop gateway 2>/dev/null || true

# Restore from R2 to the volume
echo "Restoring data..."
rclone copy r2:hermes-backups/latest/ /root/.hermes/ \
  --transfers 4

# Fix ownership
chown -R 10000:10000 /root/.hermes/

# Restart gateway
cd /opt/hermes && docker compose restart gateway 2>/dev/null || true

echo "=== Restore complete ==="
echo "Restored: $BACKUP_SIZE"
