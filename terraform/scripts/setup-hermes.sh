#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Hermes Setup ==="

# Agent web traffic (web_search/web_extract/curl/git-over-https/SearXNG) via the
# home VPN's HTTP proxy on 127.0.0.1:1081 (setup-home-vpn.sh). Infrastructure
# endpoints stay direct (NO_PROXY), so the bots keep talking to Ollama/Discord/
# GitHub when the home connection is down. HOME_VPN_WEB_ACTIVE is computed by
# Terraform (home VPN configured && home_vpn_web), so rotating the VPN keys
# doesn't re-run this script.
WEB_PROXY_URL=""
WEB_NO_PROXY=""
if [ "${HOME_VPN_WEB_ACTIVE:-false}" = true ]; then
  WEB_PROXY_URL="http://127.0.0.1:1081"
  WEB_NO_PROXY="localhost,127.0.0.1,::1,host.docker.internal,ollama.com,discord.com,discordapp.com,discordapp.net,discord.gg,discord.media,github.com,githubusercontent.com,githubassets.com,cursor.sh,cursor.com,googleapis.com,accounts.google.com,nousresearch.com,luma.com,cloudflarestorage.com,r2.dev"
fi

# Swap: the cx23 has 3.8GB RAM and the four gateways alone idle at ~1.7GB.
# Without swap, any single ~1GB spike (Camoufox, a bot's git/node/pyright
# process) hit the global OOM killer — 30 kills in 30 days, taking out
# whatever was biggest, Hermes included. Swap turns those into slowdowns.
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  echo "Creating 2GB swapfile..."
  [ -f /swapfile ] || { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile; }
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
# Low swappiness: only swap under real memory pressure, keep hot pages in RAM.
echo 'vm.swappiness=10' > /etc/sysctl.d/99-hermes-swap.conf
sysctl -q -p /etc/sysctl.d/99-hermes-swap.conf

# SSH hardening: port 22 is open to the world (Hetzner firewall) and got
# ~313k failed logins/month, filling /var/log/btmp. Root was already
# key-only; this makes every account key-only and bans repeat offenders.
# Validated with `sshd -t` before reloading, so a bad config can't take
# sshd down. If you ever ban yourself, wait out the ban (1h, longer for
# repeat offenders) or use the Hetzner web console:
# `fail2ban-client set sshd unbanip <ip>`.
cat > /etc/ssh/sshd_config.d/10-hermes-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t && systemctl reload ssh
if ! command -v fail2ban-client &> /dev/null; then
  apt-get update -qq && apt-get install -y -qq fail2ban
fi
cat > /etc/fail2ban/jail.d/hermes-sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl reload fail2ban

# Clone Hermes agent repo (needed for docker-compose.yml)
if [ ! -d /opt/hermes ]; then
  echo "Cloning hermes-agent..."
  git clone https://github.com/nousresearch/hermes-agent /opt/hermes
fi

# Pull pre-built Docker image (skip ~10 min build)
echo "Pulling Hermes image: nousresearch/hermes-agent:$HERMES_IMAGE_TAG"
docker pull "nousresearch/hermes-agent:$HERMES_IMAGE_TAG"

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
CURSOR_API_KEY=$CURSOR_API_KEY
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
SEARXNG_URL=http://127.0.0.1:8080
CAMOFOX_URL=http://127.0.0.1:9377
DARIO_API_KEY=$DARIO_API_KEY
WEB_PROXY_URL=$WEB_PROXY_URL
WEB_NO_PROXY=$WEB_NO_PROXY
EOF

# Write docker-compose.override.yml (uses pre-built image, no build needed)
HERMES_IMAGE="nousresearch/hermes-agent:$HERMES_IMAGE_TAG"
cat > /opt/hermes/docker-compose.override.yml <<'COMPEOF'
services:
  gateway:
    image: __HERMES_IMAGE__
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
      - CURSOR_API_KEY=${CURSOR_API_KEY}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
      - HERMES_MODEL=${HERMES_MODEL}
      - EMAIL_ADDRESS=${EMAIL_ADDRESS}
      - EMAIL_PASSWORD=${EMAIL_PASSWORD}
      - EMAIL_IMAP_HOST=${EMAIL_IMAP_HOST}
      - EMAIL_IMAP_PORT=${EMAIL_IMAP_PORT}
      - EMAIL_ALLOWED_USERS=${EMAIL_ALLOWED_USERS}
      - EMAIL_POLL_INTERVAL=${EMAIL_POLL_INTERVAL}
      - HERMES_USER_TIMEZONE=${HERMES_USER_TIMEZONE}
      - SEARXNG_URL=http://127.0.0.1:8080
      - CAMOFOX_URL=http://127.0.0.1:9377
      - DARIO_URL=http://127.0.0.1:3456/v1
      - DARIO_API_KEY=${DARIO_API_KEY}
      # Home VPN web egress (empty = direct). Both cases: curl only reads
      # lowercase http_proxy, Python reads either.
      - HTTP_PROXY=${WEB_PROXY_URL:-}
      - HTTPS_PROXY=${WEB_PROXY_URL:-}
      - http_proxy=${WEB_PROXY_URL:-}
      - https_proxy=${WEB_PROXY_URL:-}
      - NO_PROXY=${WEB_NO_PROXY:-}
      - no_proxy=${WEB_NO_PROXY:-}

  dashboard:
    image: __HERMES_IMAGE__
    volumes:
      - ~/.hermes:/opt/data
      - /root/no-reconcile.sh:/etc/cont-init.d/02-reconcile-profiles:ro

  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/searxng:/etc/searxng
    environment:
      - SEARXNG_BASE_URL=http://127.0.0.1:8080/
COMPEOF
sed -i "s|__HERMES_IMAGE__|$HERMES_IMAGE|g" /opt/hermes/docker-compose.override.yml

# SearXNG settings, the home VPN (wireproxy + front proxy), Camofox and dario
# are set up by their own scripts (setup-searxng.sh, setup-home-vpn.sh,
# setup-camofox.sh, setup-dario.sh), each a separate Terraform resource that
# re-runs only when its own script or inputs change.

# Create no-reconcile script (prevents dual gateway in dashboard)
echo '#!/bin/sh' > /root/no-reconcile.sh && chmod +x /root/no-reconcile.sh

echo "=== Starting containers ==="
cd /opt/hermes && docker compose up -d

echo "=== Waiting for containers to initialize ==="
until docker exec hermes echo ready 2>/dev/null; do
  echo "Waiting for hermes container..."
  sleep 3
done

# NOTE: config.yaml corrections (model/base_url/toolsets) are applied in
# restore-backup.sh, not here — that script's R2 restore runs after this one
# and would silently overwrite any edits made to config.yaml at this point.

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

# Gmail API token for every profile.
#
# The OAuth token lives at the deployment-wide $HERMES_HOME/google_token.json
# (i.e. /opt/data/google_token.json). A named profile runs with
# HERMES_HOME=/opt/data/profiles/<name>, so its google_api.py looks for the
# token THERE and finds nothing -> "Not authenticated". The profile dir lives
# on the persistent volume, so the fix is a symlink that survives restarts.
# Confirmed live: symlinks are NOT what makes this fragile — rclone's
# `sync` does not follow/copy symlinks, so a symlink created by hand is
# silently dropped by the next R2 snapshot and every redeploy. Recreating it
# here, on every boot, is what makes it durable.
docker exec hermes sh -c '
  for d in /opt/data/profiles/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ "$name" = "default" ] && continue
    ln -sfn /opt/data/google_token.json "$d/google_token.json"
    ln -sfn /opt/data/google_client_secret.json "$d/google_client_secret.json"
  done
'

# Set up auto-pull cron (syncs git changes every 5 minutes)
cat > /usr/local/bin/hermes-sync <<'SYNCEOF'
#!/bin/bash
cd /opt/hermes-deploy || exit 1
# The checkout belongs to the container user (Claudiano commits from inside
# the container), but this pull runs as root: hand back anything it wrote,
# or root-owned .git/objects dirs make Claudiano's next commit fail.
trap 'find /opt/hermes-deploy \! -user 10000 -exec chown 10000:10000 {} + 2>/dev/null' EXIT
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
  # Skill discovery scans each profile's OWN skills/ directory, not just the
  # global tier above — confirmed live: a skill only present under
  # /root/.hermes/skills/ never showed up in that profile's skills_list,
  # even after a restart and a cleared .skills_prompt_snapshot.json cache.
  # Bundled skills (codex, claude-code, opencode) ship pre-copied into every
  # profile's own skills/ dir for the same reason. Custom profile-specific
  # skills in this repo need the same treatment.
  for profile_skills in /opt/hermes-deploy/profiles/*/skills/*/; do
    [ -d "$profile_skills" ] || continue
    profile_name=$(basename "$(dirname "$(dirname "$profile_skills")")")
    skill_name=$(basename "$profile_skills")
    dest="/root/.hermes/profiles/$profile_name/skills/$skill_name"
    mkdir -p "$dest"
    cp -r "$profile_skills"/* "$dest/"
  done
  chown -R 10000:10000 /root/.hermes/SOUL.md /root/.hermes/profiles/ /root/.hermes/skills/ 2>/dev/null
  # Token symlinks: rclone does not carry symlinks, so a fresh R2 restore
  # loses them. Recreate on every sync, same as setup-hermes.sh does at boot.
  docker exec hermes sh -c '
    for d in /opt/data/profiles/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d"); [ "$n" = "default" ] && continue
      ln -sfn /opt/data/google_token.json "$d/google_token.json"
      ln -sfn /opt/data/google_client_secret.json "$d/google_client_secret.json"
    done
  '

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) synced $(git log --oneline $BEFORE..$AFTER | wc -l) commit(s)" >> /var/log/hermes-sync.log
fi
SYNCEOF
chmod +x /usr/local/bin/hermes-sync
SYNC_CRON="*/5 * * * * /usr/local/bin/hermes-sync"
(crontab -l 2>/dev/null | grep -v hermes-sync; echo "$SYNC_CRON") | crontab -

# Sandbox cleanup cron (tirith dirs fill /tmp fast)
CLEANUP_CRON='0 * * * * docker exec hermes find /tmp -maxdepth 1 -name "tirith-install-*" -type d -mmin +60 -exec rm -rf {} + 2>/dev/null'
(crontab -l 2>/dev/null | grep -v tirith; echo "$CLEANUP_CRON") | crontab -

# Copy .env to data dir (Hermes reads config from here)
cp /opt/hermes/.env /root/.hermes/.env

# NOTE: per-profile Discord bot setup (.env write/cleanup + gateway
# start/stop) lives in restore-backup.sh, not here — same reason as the
# config.yaml corrections: this script runs BEFORE restore-backup.sh's
# rclone copy, so anything written here can get silently overwritten by
# whatever profiles/*/.env the R2 backup snapshot happens to contain
# (found this the hard way: a removed profile's stale .env came right
# back after the restore, undoing a cleanup that ran here first).

echo "=== Setup complete ==="
