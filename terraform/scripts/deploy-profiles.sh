#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Deploying profiles ==="

# Copy default SOUL.md to live location
cp /opt/hermes-deploy/profiles/default/SOUL.md /root/.hermes/SOUL.md

# Append timezone to SOUL.md
cat >> /root/.hermes/SOUL.md <<EOF

## Timezone

The user's timezone is $USER_TIMEZONE. When the user mentions a time (e.g. "remind me at 9am", "check at 3pm"), always interpret it as $USER_TIMEZONE. When displaying times to the user, convert from UTC to $USER_TIMEZONE. The system runs in UTC internally — use TZ=$USER_TIMEZONE date to get the user's local time.
EOF

# Deploy all non-default profiles
for profile in /opt/hermes-deploy/profiles/*/; do
  name=$(basename "$profile")
  [ "$name" = "default" ] && continue
  echo "Deploying profile: $name"
  mkdir -p "/root/.hermes/profiles/$name"
  for f in SOUL.md profile.yaml; do
    [ -f "$profile/$f" ] && cp "$profile/$f" "/root/.hermes/profiles/$name/$f"
  done
done

# Write himalaya config
mkdir -p /root/.hermes/.config/himalaya
cp /tmp/himalaya-config.toml /root/.hermes/.config/himalaya/config.toml

# Deploy skills from deploy repo
for skill in /opt/hermes-deploy/skills/*/; do
  name=$(basename "$skill")
  echo "Deploying skill: $name"
  mkdir -p "/root/.hermes/skills/$name"
  cp -r "$skill"/* "/root/.hermes/skills/$name/"
done

# Fix ownership
chown -R 10000:10000 /root/.hermes/SOUL.md
chown -R 10000:10000 /root/.hermes/profiles/ 2>/dev/null || true
chown -R 10000:10000 /root/.hermes/.config/ 2>/dev/null || true

echo "=== Restarting gateway ==="
cd /opt/hermes && docker compose restart gateway

echo "=== Profiles deployed ==="
