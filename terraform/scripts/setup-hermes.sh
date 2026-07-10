#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Hermes Setup ==="

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

# Create SearXNG config
mkdir -p /opt/searxng
cat > /opt/searxng/settings.yml <<'SEARXEOF'
use_default_settings: true

server:
  secret_key: "hermes-searxng-secret"
  limiter: false

search:
  safe_search: 0
  formats:
    - html
    - json

engines:
  - name: google
    engine: google
    shortcut: g
    proxies:
      all://:
        - socks5://127.0.0.1:1080
  # No `reddit` engine: reddit.com/search.json hard-requires an authenticated
  # session, which SearXNG's engine can't provide. Use browser_navigate with
  # the persisted Camofox Reddit login instead (see researcher/SOUL.md).
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
  - name: wikipedia
    engine: wikipedia
    shortcut: wp
  - name: github
    engine: github
    shortcut: gh
  # News category — separate engines from general search, so a general
  # search block (google/duckduckgo/etc.) doesn't take these down too.
  - name: duckduckgo news
    engine: duckduckgo_extra
    categories: [news]
    ddg_category: news
    shortcut: ddn
  - name: wikinews
    engine: mediawiki
    shortcut: wn
    categories: [news, wikimedia]
    base_url: "https://{language}.wikinews.org/"
    search_type: text
  - name: mojeek news
    shortcut: mjknews
    engine: mojeek
    categories: [news, web]
    search_type: news
    paging: false
  - name: bing news
    engine: bing_news
    shortcut: bin
SEARXEOF

# Restart SearXNG to pick up the new settings (only this container, no
# impact on the gateway/dashboard or Discord bot connections)
docker restart searxng >/dev/null 2>&1 || true

# Camofox: self-hosted anti-detection browser server (browser_navigate/etc.
# tools). Own standalone container, independent of docker-compose — gateway
# reaches it over the shared host network at 127.0.0.1:9377. Bound to
# loopback only, not published to the internet.
CAMOFOX_IMAGE="camofox-browser:135.0.1-x86_64"
mkdir -p /opt/camofox-data
CAMOFOX_FRESH_INSTALL=false

# If a container exists but isn't using the persistence volume or host
# networking (e.g. from before these were added), recreate it — otherwise
# logins/cookies are lost on every redeploy, or the proxy is unreachable.
if docker ps -a --format '{{.Names}}' | grep -qx camofox-browser; then
  NEEDS_RECREATE=false
  docker inspect camofox-browser --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -qx /opt/camofox-data || NEEDS_RECREATE=true
  [ "$(docker inspect camofox-browser --format '{{.HostConfig.NetworkMode}}')" = "host" ] || NEEDS_RECREATE=true
  if [ "$NEEDS_RECREATE" = true ]; then
    echo "Camofox container outdated (volume/networking), recreating..."
    docker rm -f camofox-browser
  fi
fi

if docker ps -a --format '{{.Names}}' | grep -qx camofox-browser; then
  echo "Camofox already installed, ensuring running..."
  docker start camofox-browser >/dev/null 2>&1 || true
else
  echo "Installing Camofox browser server..."
  if ! command -v make &> /dev/null; then
    apt-get update -qq && apt-get install -y -qq make
  fi
  if [ ! -d /opt/camofox-browser ]; then
    git clone https://github.com/jo-inc/camofox-browser /opt/camofox-browser
  fi
  # Known upstream bugs (Linux/Docker only, os.platform()==='linux' code
  # path — doesn't affect macOS, which is likely why they're still open).
  # See README.md "Camofox Browser Automation" for the full table + upstream
  # links. Re-applied every run (idempotent seds) in case /opt/camofox-browser
  # already existed from before these were added.
  # 1. missing `await` on VirtualDisplay.get() -> DISPLAY becomes the
  #    literal string "[object Promise]", browser fails to launch at all.
  sed -i 's/vdDisplay = localVirtualDisplay\.get();/vdDisplay = await localVirtualDisplay.get();/' /opt/camofox-browser/server.js
  # 2 & 3. explicit/default viewport dims send an `isMobile` field this
  #    Camoufox version's protocol schema rejects -> every tab creation
  #    500s, and the health probe's bare newContext() hits the same thing
  #    every ~3 min, force-restarting the whole browser.
  sed -i 's/viewport: { width: 1280, height: 720 }/viewport: null/g' /opt/camofox-browser/server.js
  sed -i 's/testContext = await browser\.newContext();/testContext = await browser.newContext({ viewport: null });/' /opt/camofox-browser/server.js
  # 4. PROXY_HOST/PROXY_PORT hardcode an http:// scheme (lib/proxy.js) —
  #    doesn't work with our SOCKS5 reverse tunnel (search_proxy_tunnel
  #    output); Playwright supports socks5:// natively, the env-var wrapper
  #    just never offered it.
  sed -i 's|server: `http://${host}:${port}`|server: `socks5://${host}:${port}`|' /opt/camofox-browser/lib/proxy.js
  # 5. GeoIP auto-detection (triggered whenever a proxy is set) verifies the
  #    proxy's exit IP via 6 external lookup APIs — all unreachable through
  #    our tunnel, so it blocked browser launch entirely. Disabling it only
  #    loses automatic locale/timezone/geo fingerprint matching, not the
  #    actual proxying.
  sed -i 's/geoip: !!launchProxy/geoip: false/g' /opt/camofox-browser/server.js
  # Bind loopback only for defense-in-depth (redundant with the Hetzner
  # firewall only allowing port 22 in, but cheap insurance) — required once
  # switched to --network host below, since the container no longer has its
  # own network namespace to isolate it.
  sed -i "s/const server = app.listen(PORT, async () => {/const server = app.listen(PORT, '127.0.0.1', async () => {/" /opt/camofox-browser/server.js
  (cd /opt/camofox-browser && make build)
  # --network host (not -p 127.0.0.1:9377:9377): needed so 127.0.0.1 inside
  # the container means the *host's* loopback, where the reverse SOCKS
  # tunnel actually listens — otherwise PROXY_HOST=127.0.0.1 points at the
  # container's own loopback and every proxied request gets connection
  # refused. Matches gateway/searxng, which are host-networked for the same
  # reason.
  # No PROXY_HOST/PROXY_PORT: tested both ways for Google (blocked either
  # way — this server's IP built up enough automated-query history that the
  # proxy makes no difference, and routing Google traffic through the home
  # IP burns that IP's reputation for no benefit) and for Reddit (persisted
  # session browses fine without it — the proxy only ever seemed to matter
  # for a *fresh* login, and even that's confounded by attempt-spacing, not
  # cleanly isolated to the proxy). Not worth the complexity as a default;
  # revisit empirically if a future Reddit re-login genuinely needs it.
  # MAX_OLD_SPACE_SIZE: the image's own default (128MB) OOM-crashed under
  # normal use ("JavaScript heap out of memory", Node aborted) — plenty of
  # RAM headroom on this box to give it much more.
  docker run -d --restart unless-stopped --name camofox-browser \
    --network host \
    -v /opt/camofox-data:/root/.camofox \
    -e MAX_OLD_SPACE_SIZE=1024 \
    "$CAMOFOX_IMAGE"
  CAMOFOX_FRESH_INSTALL=true
fi

# Log the fixed hermes-reddit Camofox identity into Reddit on fresh installs
# (persistence volume means this only needs to happen once, going forward).
# config.yaml's browser.camofox.user_id is set to the same fixed userId in
# restore-backup.sh so Barbero's browser_navigate calls reuse this session.
if [ "$CAMOFOX_FRESH_INSTALL" = true ] && [ -n "${REDDIT_USERNAME:-}" ]; then
  echo "Logging Camofox into Reddit..."
  sleep 3
  python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py || \
    echo "Reddit login failed — run reddit-login.py manually to retry"
fi

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

# Sandbox cleanup cron (tirith dirs fill /tmp fast)
CLEANUP_CRON='0 * * * * docker exec hermes find /tmp -maxdepth 1 -name "tirith-install-*" -type d -mmin +60 -exec rm -rf {} + 2>/dev/null'
(crontab -l 2>/dev/null | grep -v tirith; echo "$CLEANUP_CRON") | crontab -

# Copy .env to data dir (Hermes reads config from here)
cp /opt/hermes/.env /root/.hermes/.env

# Set up per-profile Discord bots (from PROFILE_DISCORD_TOKENS map)
echo "$PROFILE_DISCORD_TOKENS" | python3 -c "
import sys, json, os
tokens = json.loads(sys.stdin.read())
for profile, token in tokens.items():
    if not token:
        continue
    profile_dir = f'/root/.hermes/profiles/{profile}'
    os.makedirs(profile_dir, exist_ok=True)
    env_path = f'{profile_dir}/.env'
    with open(env_path, 'w') as f:
        f.write(f'DISCORD_BOT_TOKEN={token}\n')
        f.write(f'DISCORD_ALLOWED_USERS={os.environ[\"DISCORD_ALLOWED_USERS\"]}\n')
        f.write(f'OLLAMA_API_KEY={os.environ[\"OLLAMA_API_KEY\"]}\n')
        f.write(f'OLLAMA_BASE_URL=https://ollama.com/v1\n')
    os.system(f'chown -R 10000:10000 {env_path}')
    print(f'  Configured Discord bot for profile: {profile}')
"

# Fix ownership on all data dir contents
chown -R 10000:10000 /root/.hermes/

# Start gateway services: only profiles with tokens, stop the rest
docker exec hermes /command/s6-svc -u /run/service/gateway-default 2>/dev/null || true
echo "$PROFILE_DISCORD_TOKENS" | python3 -c "
import sys, json, os, subprocess

tokens = json.loads(sys.stdin.read())
profiles_with_tokens = {p for p, t in tokens.items() if t}

# List all gateway services
result = subprocess.run(['docker', 'exec', 'hermes', 'ls', '/run/service/'], capture_output=True, text=True)
all_gateways = [d.replace('gateway-', '') for d in result.stdout.split() if d.startswith('gateway-') and d != 'gateway-default' and '/log' not in d]

for profile in all_gateways:
    if profile in profiles_with_tokens:
        os.system(f'docker exec hermes /command/s6-svc -u /run/service/gateway-{profile} 2>/dev/null || true')
        print(f'  Started gateway: {profile}')
    else:
        os.system(f'docker exec hermes /command/s6-svc -d /run/service/gateway-{profile} 2>/dev/null || true')
        print(f'  Stopped gateway (no token): {profile}')
"

echo "=== Setup complete ==="
