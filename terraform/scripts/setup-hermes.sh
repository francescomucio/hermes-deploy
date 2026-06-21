#!/bin/bash
set -euo pipefail

# Load config
source /tmp/hermes-deploy.env

echo "=== Hermes Setup ==="

# Clone Hermes agent repo (needed for docker-compose.yml)
if [ ! -d /opt/hermes ]; then
  echo "Cloning hermes-agent..."
  git clone https://github.com/nousresearch/hermes-agent /opt/hermes
fi

# Pull pre-built Docker image (skip ~10 min build)
echo "Pulling pre-built Hermes image..."
docker pull nousresearch/hermes-agent:latest

# Set up deploy key (stored with \n escapes in env file)
mkdir -p /root/.ssh
printf '%b' "$DEPLOY_KEY" > /root/.ssh/hermes_deploy_key
chmod 600 /root/.ssh/hermes_deploy_key
cat > /root/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile /root/.ssh/hermes_deploy_key
  StrictHostKeyChecking no
EOF
ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

# Clone deploy repo if not present
git config --global --add safe.directory /opt/hermes-deploy
if [ ! -d /opt/hermes-deploy ]; then
  echo "Cloning deploy repo..."
  git clone "$DEPLOY_REPO" /opt/hermes-deploy
else
  echo "Pulling latest deploy repo..."
  cd /opt/hermes-deploy && git pull
fi

# Set deploy repo ownership to hermes user (UID 10000)
chown -R 10000:10000 /opt/hermes-deploy

# Copy deploy key into repo for hermes user access
cp /root/.ssh/hermes_deploy_key /opt/hermes-deploy/.deploy_key
chown 10000:10000 /opt/hermes-deploy/.deploy_key
chmod 600 /opt/hermes-deploy/.deploy_key

# Set up SSH config for hermes user (HOME=/opt/data)
HERMES_SSH="/root/.hermes/.ssh"
mkdir -p "$HERMES_SSH"
cat > "$HERMES_SSH/config" <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile /opt/hermes-deploy/.deploy_key
  StrictHostKeyChecking no
EOF
ssh-keyscan github.com >> "$HERMES_SSH/known_hosts" 2>/dev/null
chmod 700 "$HERMES_SSH"
chmod 600 "$HERMES_SSH/config"
chown -R 10000:10000 "$HERMES_SSH"

# Write .env for docker-compose variable substitution
cat > /opt/hermes/.env <<EOF
OLLAMA_API_KEY=$OLLAMA_API_KEY
OLLAMA_BASE_URL=https://ollama.com/v1
HERMES_MODEL=$OLLAMA_MODEL
DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN
DISCORD_ALLOWED_USERS=$DISCORD_ALLOWED_USERS
EMAIL_ADDRESS=$EMAIL_ADDRESS
EMAIL_PASSWORD=$EMAIL_PASSWORD
EMAIL_IMAP_HOST=imap.gmail.com
EMAIL_IMAP_PORT=993
EMAIL_ALLOWED_USERS=$EMAIL_ADDRESS
EMAIL_POLL_INTERVAL=60
HERMES_USER_TIMEZONE=$USER_TIMEZONE
EOF

# Write docker-compose.override.yml (uses pre-built image, no build needed)
cat > /opt/hermes/docker-compose.override.yml <<'EOF'
services:
  gateway:
    image: nousresearch/hermes-agent:latest
    command: ["sleep", "infinity"]
    volumes:
      - ~/.hermes:/opt/data
      - /opt/hermes-deploy:/opt/hermes-deploy
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
      - DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}
      - DISCORD_ALLOWED_USERS=${DISCORD_ALLOWED_USERS}
      - OLLAMA_API_KEY=${OLLAMA_API_KEY}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
      - HERMES_MODEL=${HERMES_MODEL}
      - EMAIL_ADDRESS=${EMAIL_ADDRESS}
      - EMAIL_PASSWORD=${EMAIL_PASSWORD}
      - EMAIL_IMAP_HOST=${EMAIL_IMAP_HOST}
      - EMAIL_IMAP_PORT=${EMAIL_IMAP_PORT}
      - EMAIL_ALLOWED_USERS=${EMAIL_ALLOWED_USERS}
      - EMAIL_POLL_INTERVAL=${EMAIL_POLL_INTERVAL}
      - HERMES_USER_TIMEZONE=${HERMES_USER_TIMEZONE}

  dashboard:
    image: nousresearch/hermes-agent:latest
    volumes:
      - ~/.hermes:/opt/data
      - /root/no-reconcile.sh:/etc/cont-init.d/02-reconcile-profiles:ro
EOF

# Create no-reconcile script (prevents dual gateway in dashboard)
echo '#!/bin/sh' > /root/no-reconcile.sh && chmod +x /root/no-reconcile.sh

echo "=== Starting containers ==="
cd /opt/hermes && docker compose up -d

echo "=== Waiting for containers to initialize ==="
until docker exec hermes echo ready 2>/dev/null; do
  echo "Waiting for hermes container..."
  sleep 3
done

# Configure Hermes: model, base_url, max_turns, auto_thread
docker exec hermes sed -i \
  "s|default: anthropic/claude-opus-4.6|default: $OLLAMA_MODEL|; s|base_url: https://openrouter.ai/api/v1|base_url: https://ollama.com/v1|; s|auto_thread: true|auto_thread: false|; s|max_turns: 90|max_turns: 100|" \
  /opt/data/config.yaml

# Add safe.directory for hermes user
docker exec hermes git config --global --add safe.directory /opt/hermes-deploy
docker exec hermes sh -c 'cd /opt/hermes-deploy && git config user.name Claudiano && git config user.email claudiano@hermes'

# Install himalaya to persistent volume (if not already there)
if ! docker exec hermes himalaya --version > /dev/null 2>&1; then
  echo "Installing himalaya..."
  docker exec hermes sh -c 'mkdir -p /opt/data/.local/bin && curl -sSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh | PREFIX=/opt/data/.local sh'
fi

# Himalaya config directories + symlink
docker exec hermes mkdir -p /opt/data/.config/himalaya /opt/data/home/.config
docker exec hermes ln -sf /opt/data/.config/himalaya /opt/data/home/.config/himalaya

# Set up auto-pull cron (syncs git changes every 5 minutes)
cat > /usr/local/bin/hermes-sync <<'SYNCEOF'
#!/bin/bash
cd /opt/hermes-deploy || exit 1
BEFORE=$(git rev-parse HEAD)
git pull --quiet 2>/dev/null || exit 0
AFTER=$(git rev-parse HEAD)
if [ "$BEFORE" != "$AFTER" ]; then
  # New commits — deploy profiles
  cp /opt/hermes-deploy/profiles/default/SOUL.md /root/.hermes/SOUL.md
  for profile in /opt/hermes-deploy/profiles/*/; do
    name=$(basename "$profile")
    [ "$name" = "default" ] && continue
    mkdir -p "/root/.hermes/profiles/$name"
    for f in SOUL.md profile.yaml; do
      [ -f "$profile/$f" ] && cp "$profile/$f" "/root/.hermes/profiles/$name/$f"
    done
  done
  for skill in /opt/hermes-deploy/skills/*/; do
    name=$(basename "$skill")
    mkdir -p "/root/.hermes/skills/$name"
    cp -r "$skill"/* "/root/.hermes/skills/$name/"
  done
  chown -R 10000:10000 /root/.hermes/SOUL.md /root/.hermes/profiles/ /root/.hermes/skills/ 2>/dev/null
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) synced $(git log --oneline $BEFORE..$AFTER | wc -l) commit(s)" >> /var/log/hermes-sync.log
fi
SYNCEOF
chmod +x /usr/local/bin/hermes-sync
SYNC_CRON="*/5 * * * * /usr/local/bin/hermes-sync"
(crontab -l 2>/dev/null | grep -v hermes-sync; echo "$SYNC_CRON") | crontab -

# Copy .env to data dir (Hermes reads config from here)
cp /opt/hermes/.env /root/.hermes/.env

# Fix ownership on all data dir contents
chown -R 10000:10000 /root/.hermes/

# Start the gateway service (registered but not started on fresh install)
docker exec hermes /command/s6-svc -u /run/service/gateway-default 2>/dev/null || true

echo "=== Setup complete ==="
