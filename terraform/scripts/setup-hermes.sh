#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Hermes Setup ==="

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

# Create SearXNG config. Canonical engine list also lives in
# terraform/scripts/fix-searxng-engines.sh — keep the two in sync (setup-hermes.sh is copied
# to /tmp alone on deploy, so it cannot read a sibling file).
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
  # --- general search: the engines that actually answer from this host's IP ---
  # seznam carries general search (relevant results, no CAPTCHA from the Hetzner IP).
  - name: seznam
    engine: seznam
    shortcut: szn
    categories: [general, web]
  # bing answers too, but its parsed results are weak (often only the first query word
  # matches) — kept as a second opinion, not the primary.
  - name: bing
    engine: bing
    shortcut: bi
    categories: [general, web]
  # --- general search: dead from this host, disabled until the block clears ---
  # Left configured-but-disabled rather than removed: google's block is volume-driven and
  # may cool down on its own (README "Google — not solved"). No `proxies:` override here,
  # on purpose: the home-IP SOCKS5 proxy on 127.0.0.1:1080 is always up now (wireproxy-home,
  # "Home VPN egress" below), but testing showed it doesn't change Google's outcome and it
  # would spend the home IP's reputation on scraped queries. Only Camofox uses it.
  # No `reddit` engine either: reddit.com/search.json hard-requires an authenticated
  # session, which SearXNG's engine can't provide. Use browser_navigate with the persisted
  # Camofox Reddit login instead (see researcher/SOUL.md).
  - name: google
    engine: google
    shortcut: g
    disabled: true
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
    disabled: true
  - name: startpage
    engine: startpage
    shortcut: sp
    disabled: true
  - name: brave
    engine: brave
    shortcut: br
    disabled: true

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

# Home VPN egress: wireproxy is a userspace WireGuard client that exposes the
# tunnel to the home router as a SOCKS5 proxy on 127.0.0.1:1080. Nothing else
# on the server changes: no kernel interface, no routes, so SSH/Discord/
# Ollama/email keep going out directly from Hetzner. Only what is explicitly
# pointed at the proxy (Camofox, see below) exits via the home IP.
# Replaces the old manual `ssh -R 1080` tunnel, which only worked while the
# laptop was on — this one is always up.
#
# AllowedIPs = the public IPv4 internet only (0.0.0.0/0 minus RFC1918,
# CGNAT, loopback, link-local, multicast, reserved). wireguard-go drops
# anything else, so nothing using the proxy can reach the home router
# (10.6.0.1 / 192.168.x) or the home LAN — on top of the router's own
# "Access Intranet: off". DNS goes through the tunnel to a public resolver
# for the same reason (not the router's 10.6.0.1).
WIREPROXY_VERSION="v1.1.3"
WIREPROXY_SHA256="e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c"
WIREPROXY_ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/3, 96.0.0.0/6, 100.0.0.0/10, 100.128.0.0/9, 101.0.0.0/8, 102.0.0.0/7, 104.0.0.0/5, 112.0.0.0/5, 120.0.0.0/6, 124.0.0.0/7, 126.0.0.0/8, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/8, 169.0.0.0/9, 169.128.0.0/10, 169.192.0.0/11, 169.224.0.0/12, 169.240.0.0/13, 169.248.0.0/14, 169.252.0.0/15, 169.255.0.0/16, 170.0.0.0/7, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.1.0/24, 192.0.2.0/23, 192.0.4.0/22, 192.0.8.0/21, 192.0.16.0/20, 192.0.32.0/19, 192.0.64.0/18, 192.0.128.0/17, 192.1.0.0/16, 192.2.0.0/15, 192.4.0.0/14, 192.8.0.0/13, 192.16.0.0/12, 192.32.0.0/11, 192.64.0.0/10, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/7, 198.0.0.0/12, 198.16.0.0/15, 198.20.0.0/14, 198.24.0.0/13, 198.32.0.0/11, 198.64.0.0/10, 198.128.0.0/9, 199.0.0.0/8, 200.0.0.0/5, 208.0.0.0/4"
HOME_VPN_ENABLED=false
if [ -n "${HOME_VPN_CLIENT_PRIVATE_KEY:-}" ] && [ -n "${HOME_VPN_SERVER_PUBLIC_KEY:-}" ] && [ -n "${HOME_VPN_ENDPOINT:-}" ]; then
  HOME_VPN_ENABLED=true
  if ! /usr/local/bin/wireproxy --version 2>/dev/null | grep -qx "wireproxy, version ${WIREPROXY_VERSION#v}"; then
    echo "Installing wireproxy $WIREPROXY_VERSION..."
    TMP_WP=$(mktemp -d)
    curl -fsSL -o "$TMP_WP/wp.tgz" "https://github.com/windtf/wireproxy/releases/download/$WIREPROXY_VERSION/wireproxy_linux_amd64.tar.gz"
    echo "$WIREPROXY_SHA256  $TMP_WP/wp.tgz" | sha256sum -c --quiet
    tar -xzf "$TMP_WP/wp.tgz" -C "$TMP_WP" wireproxy
    install -m 0755 "$TMP_WP/wireproxy" /usr/local/bin/wireproxy
    rm -rf "$TMP_WP"
  fi

  install -d -m 0700 /etc/wireproxy
  umask 077
  cat > /etc/wireproxy/home.conf <<WPEOF
[Interface]
Address = ${HOME_VPN_CLIENT_ADDRESS:-10.6.0.2/32}
PrivateKey = $HOME_VPN_CLIENT_PRIVATE_KEY
DNS = 1.1.1.1, 9.9.9.9

[Peer]
PublicKey = $HOME_VPN_SERVER_PUBLIC_KEY
Endpoint = $HOME_VPN_ENDPOINT
AllowedIPs = $WIREPROXY_ALLOWED_IPS
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:1080
WPEOF
  umask 022
  /usr/local/bin/wireproxy --configtest --config /etc/wireproxy/home.conf

  # Sandboxed: no root, no writable filesystem, no capabilities. The config
  # (root-only, holds the private key) is handed over as a systemd credential;
  # %d is the credentials directory.
  cat > /etc/systemd/system/wireproxy-home.service <<'UNITEOF'
[Unit]
Description=wireproxy: SOCKS5 127.0.0.1:1080 via home router WireGuard
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/wireproxy --config %d/home.conf
Restart=always
RestartSec=10
LoadCredential=home.conf:/etc/wireproxy/home.conf
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=
# AF_NETLINK/AF_UNIX: wireguard-go needs them to bring the interface up
# ("Unable to update bind: address family not supported by protocol").
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
MemoryMax=128M

[Install]
WantedBy=multi-user.target
UNITEOF

  # Health check every 5 min: WireGuard resolves the asuscomm.com endpoint
  # only at start, so after the home IP changes (nightly PPPoE reconnect at
  # 04:00) the tunnel goes dead until restarted. Probe through the proxy and
  # restart on failure.
  cat > /etc/systemd/system/wireproxy-home-check.service <<'UNITEOF'
[Unit]
Description=Restart wireproxy-home if the home tunnel is dead

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'curl -sf --max-time 15 --socks5-hostname 127.0.0.1:1080 -o /dev/null https://1.1.1.1/cdn-cgi/trace || { echo "home tunnel down, restarting"; systemctl restart wireproxy-home; }'
UNITEOF
  cat > /etc/systemd/system/wireproxy-home-check.timer <<'UNITEOF'
[Unit]
Description=Check the home tunnel every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNITEOF
  systemctl daemon-reload
  systemctl enable wireproxy-home wireproxy-home-check.timer >/dev/null 2>&1
  systemctl restart wireproxy-home
  systemctl start wireproxy-home-check.timer
else
  # Disabled: tear down any previous install so nothing listens on 1080.
  if [ -f /etc/systemd/system/wireproxy-home.service ]; then
    systemctl disable --now wireproxy-home wireproxy-home-check.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wireproxy-home.service /etc/systemd/system/wireproxy-home-check.service /etc/systemd/system/wireproxy-home-check.timer
    systemctl daemon-reload
  fi
  rm -rf /etc/wireproxy
fi

# Camofox proxy settings: through the home VPN when enabled, direct otherwise.
CAMOFOX_PROXY_HOST=""
if [ "$HOME_VPN_ENABLED" = true ] && [ "${HOME_VPN_CAMOFOX:-true}" = true ]; then
  CAMOFOX_PROXY_HOST="127.0.0.1"
fi

# Camofox: self-hosted anti-detection browser server (browser_navigate/etc.
# tools). Own standalone container, independent of docker-compose — gateway
# reaches it over the shared host network at 127.0.0.1:9377. Bound to
# loopback only, not published to the internet.
#
# Pinned to an upstream release tag. To upgrade, bump CAMOFOX_REF and
# CAMOUFOX_VERSION/CAMOUFOX_RELEASE together (the latter from the Dockerfile's
# ARG defaults at that tag) — see README "Camofox Browser Automation".
CAMOFOX_REF="v1.17.0"
CAMOUFOX_VERSION="152.0.4"
CAMOUFOX_RELEASE="beta.28"
CAMOFOX_IMAGE="camofox-browser:${CAMOFOX_REF}-${CAMOUFOX_VERSION}-x86_64"
# Bump when the `docker run` flags/env below change, so existing containers
# get recreated to pick them up (flags only take effect at creation).
CAMOFOX_RUN_REV="2"
mkdir -p /opt/camofox-data
CAMOFOX_FRESH_INSTALL=false

# Build first, so an outdated container keeps serving until its
# replacement image is ready (and stays up if the build fails).
if ! docker image inspect "$CAMOFOX_IMAGE" >/dev/null 2>&1; then
  echo "Building Camofox $CAMOFOX_REF (Camoufox $CAMOUFOX_VERSION-$CAMOUFOX_RELEASE)..."
  if ! command -v make &> /dev/null; then
    apt-get update -qq && apt-get install -y -qq make
  fi
  if [ ! -d /opt/camofox-browser ]; then
    git clone https://github.com/jo-inc/camofox-browser /opt/camofox-browser
  fi
  # -f: discards the sed patches older deploys applied in place (all fixed
  # or made configurable upstream by v1.17.0, see README).
  git -C /opt/camofox-browser fetch -q --tags origin
  git -C /opt/camofox-browser checkout -q -f "$CAMOFOX_REF"
  # Upstream bug (jo-inc/camofox-browser#11025, v1.17.0): the Dockerfile runs
  # `npm ci` before copying postinstall.js, which package.json's postinstall
  # hook needs — the build fails with "Cannot find module /app/postinstall.js".
  # Copy it (and the one lib file it imports) in first; it then finds the
  # pre-baked Camoufox and skips its download. Drop once #11025 is fixed.
  grep -q '^COPY postinstall.js' /opt/camofox-browser/Dockerfile || \
    sed -i '0,/^COPY scripts\/ \.\/scripts\/$/s//COPY scripts\/ .\/scripts\/\nCOPY postinstall.js .\/\nCOPY lib\/camoufox-download.js .\/lib\//' /opt/camofox-browser/Dockerfile
  # VERSION/RELEASE must be passed explicitly: the Makefile's own defaults
  # (135.0.1-beta.24) are stale and, passed as --build-arg, override the
  # Dockerfile's pinned Camoufox — silently pairing new server code with an
  # old browser whose protocol schema it doesn't match.
  (cd /opt/camofox-browser && make build VERSION="$CAMOUFOX_VERSION" RELEASE="$CAMOUFOX_RELEASE")
  docker tag "camofox-browser:${CAMOUFOX_VERSION}-x86_64" "$CAMOFOX_IMAGE"
  docker rmi "camofox-browser:${CAMOUFOX_VERSION}-x86_64" >/dev/null
fi

# Recreate the container whenever it's outdated: wrong volume/networking,
# a different image (upgrade), different run flags, or a newly-set/rotated/
# cleared CAMOFOX_API_KEY. The /opt/camofox-data volume (cookies, persisted
# logins) survives the recreate.
if docker ps -a --format '{{.Names}}' | grep -qx camofox-browser; then
  NEEDS_RECREATE=false
  docker inspect camofox-browser --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -qx /opt/camofox-data || NEEDS_RECREATE=true
  [ "$(docker inspect camofox-browser --format '{{.HostConfig.NetworkMode}}')" = "host" ] || NEEDS_RECREATE=true
  [ "$(docker inspect camofox-browser --format '{{.Config.Image}}')" = "$CAMOFOX_IMAGE" ] || NEEDS_RECREATE=true
  [ "$(docker inspect camofox-browser --format '{{index .Config.Labels "hermes.camofox.run-rev"}}')" = "$CAMOFOX_RUN_REV" ] || NEEDS_RECREATE=true
  CURRENT_CAMOFOX_KEY=$(docker inspect camofox-browser --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^CAMOFOX_API_KEY=//p')
  [ "$CURRENT_CAMOFOX_KEY" = "${CAMOFOX_API_KEY:-}" ] || NEEDS_RECREATE=true
  CURRENT_CAMOFOX_PROXY=$(docker inspect camofox-browser --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^PROXY_HOST=//p')
  [ "$CURRENT_CAMOFOX_PROXY" = "$CAMOFOX_PROXY_HOST" ] || NEEDS_RECREATE=true
  if [ "$NEEDS_RECREATE" = true ]; then
    echo "Camofox container outdated (volume/networking/image/flags/API key/proxy), recreating..."
    docker rm -f camofox-browser
    # A recreate isn't a fresh install: persisted logins survive on the volume.
    CAMOFOX_RECREATED=true
  fi
fi

if docker ps -a --format '{{.Names}}' | grep -qx camofox-browser; then
  echo "Camofox already installed, ensuring running..."
  docker start camofox-browser >/dev/null 2>&1 || true
else
  # --network host (not -p 127.0.0.1:9377:9377): needed so 127.0.0.1 inside
  # the container means the *host's* loopback, where the reverse SOCKS
  # tunnel actually listens (PROXY_HOST=127.0.0.1, PROXY_PROTOCOL=socks5
  # when proxied — see README). Matches gateway/searxng.
  # CAMOFOX_BIND_HOST: with host networking there's no per-container port
  # isolation, so bind loopback explicitly (defense-in-depth on top of the
  # Hetzner firewall only allowing port 22 in).
  # PROXY_HOST/PORT/PROTOCOL: set only when the home VPN is configured and
  # home_vpn_camofox is on (CAMOFOX_PROXY_HOST above). Then Camofox exits via
  # the home IP through wireproxy's always-on SOCKS5 — what Blind/Glassdoor
  # need (see README). No confirmed benefit for Google, and it spends the home
  # IP's reputation, so set home_vpn_camofox = false to turn it off.
  # Memory: --memory caps the whole container so a runaway browser gets
  # OOM-killed inside its own cgroup instead of triggering the host-wide
  # OOM killer (which picks the biggest process — often Hermes itself).
  # BROWSER_RSS_RESTART_THRESHOLD_MB makes Camofox restart the browser on
  # its own before reaching that cap. MAX_OLD_SPACE_SIZE: the image default
  # (128MB) OOM-crashed the Node server under real use.
  # --shm-size: Docker's 64MB /dev/shm default is too small for Firefox
  # content processes (upstream's own Makefile uses 2g).
  # CAMOFOX_CRASH_REPORT_ENABLED=false: on by default upstream, it files
  # *public* GitHub issues including session/tab context.
  docker run -d --restart unless-stopped --name camofox-browser \
    --network host \
    --memory=1536m --memory-swap=2048m \
    --shm-size=1g \
    --label hermes.camofox.run-rev="$CAMOFOX_RUN_REV" \
    -v /opt/camofox-data:/root/.camofox \
    -e CAMOFOX_BIND_HOST=127.0.0.1 \
    -e MAX_OLD_SPACE_SIZE=512 \
    -e BROWSER_RSS_RESTART_THRESHOLD_MB=1000 \
    -e CAMOFOX_CRASH_REPORT_ENABLED=false \
    -e CAMOFOX_API_KEY="${CAMOFOX_API_KEY:-}" \
    ${CAMOFOX_PROXY_HOST:+-e PROXY_HOST="$CAMOFOX_PROXY_HOST" -e PROXY_PORT=1080 -e PROXY_PROTOCOL=socks5} \
    "$CAMOFOX_IMAGE"
  [ "${CAMOFOX_RECREATED:-false}" = true ] || CAMOFOX_FRESH_INSTALL=true
fi

# Drop superseded Camofox images (each is ~3.7GB on a 38GB disk).
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^camofox-browser:' | grep -vx "$CAMOFOX_IMAGE" | xargs -r docker rmi >/dev/null 2>&1 || true

# Fresh Camofox installs need an initial Reddit login. The narrow
# credentials file reddit-login.py reads doesn't exist yet at this point
# in the deploy (restore-backup.sh writes it, and runs after this script),
# so just leave a marker for restore-backup.sh to act on once it's ready.
if [ "$CAMOFOX_FRESH_INSTALL" = true ]; then
  touch /tmp/camofox-needs-reddit-login
fi

# dario: local OpenAI/Anthropic-compatible router for non-Claude backends
# (ChatGPT subscription via `dario add altman`, API-key backends via
# `dario backend add`). Opt-in: only installed when DARIO_API_KEY is set.
# Own standalone container like Camofox; gateway reaches it over the host
# network at 127.0.0.1:3456 (DARIO_URL), loopback only.
#
# --no-claude-auth: the Claude OAuth pool is never loaded, so claude-* models
# return an auth error — routing a Claude subscription through a third-party
# proxy is against Anthropic's terms. Never run `dario login` here.
#
# Accounts/backends live in /opt/dario-data, outside /root/.hermes on
# purpose: that tree is mounted into the agents' container, and they must
# not be able to read the OAuth tokens. Not backed up to R2 — re-add the
# accounts after a fresh deploy (see README "dario").
DARIO_IMAGE="ghcr.io/askalf/dario:v6.12.25"
# Bump when the `docker run` flags/env below change (see CAMOFOX_RUN_REV).
DARIO_RUN_REV="1"
if [ -n "${DARIO_API_KEY:-}" ]; then
  mkdir -p /opt/dario-data
  if docker ps -a --format '{{.Names}}' | grep -qx dario; then
    NEEDS_RECREATE=false
    [ "$(docker inspect dario --format '{{.Config.Image}}')" = "$DARIO_IMAGE" ] || NEEDS_RECREATE=true
    [ "$(docker inspect dario --format '{{index .Config.Labels "hermes.dario.run-rev"}}')" = "$DARIO_RUN_REV" ] || NEEDS_RECREATE=true
    CURRENT_DARIO_KEY=$(docker inspect dario --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^DARIO_API_KEY=//p')
    [ "$CURRENT_DARIO_KEY" = "$DARIO_API_KEY" ] || NEEDS_RECREATE=true
    if [ "$NEEDS_RECREATE" = true ]; then
      echo "dario container outdated (image/flags/API key), recreating..."
      docker rm -f dario
    fi
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx dario; then
    docker start dario >/dev/null 2>&1 || true
  else
    # DARIO_HOST=127.0.0.1: the image binds 0.0.0.0 by default; with host
    # networking that would be every interface (Hetzner firewall aside).
    # DARIO_NO_LIVE_CAPTURE=1: the Claude Code template capture is pointless
    # without Claude auth. Docker reports the container "unhealthy" until a
    # ChatGPT account is added, and stays so with API-key backends only
    # (/health only counts Codex accounts under --no-claude-auth). Harmless:
    # plain `docker run` never restarts on health; check /livez instead.
    docker run -d --restart unless-stopped --name dario \
      --network host \
      --memory=256m --memory-swap=512m \
      --label hermes.dario.run-rev="$DARIO_RUN_REV" \
      -v /opt/dario-data:/home/dario/.dario \
      -e DARIO_HOST=127.0.0.1 \
      -e DARIO_PORT=3456 \
      -e DARIO_API_KEY="$DARIO_API_KEY" \
      -e DARIO_NO_LIVE_CAPTURE=1 \
      "$DARIO_IMAGE" proxy --no-claude-auth
  fi
elif docker ps -a --format '{{.Names}}' | grep -qx dario; then
  echo "DARIO_API_KEY unset, removing dario container (accounts kept in /opt/dario-data)..."
  docker rm -f dario
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
