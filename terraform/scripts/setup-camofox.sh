#!/bin/bash
set -euo pipefail

# Camofox anti-detection browser server (build, run, image cleanup).
# Run by Terraform (null_resource, see main.tf) after setup-hermes.sh; re-runs
# only when this script or its own env file (/tmp/hermes-camofox.env) changes.

set -a
source /tmp/hermes-camofox.env
set +a
rm -f /tmp/hermes-camofox.env

# Camofox proxy settings: through the home VPN front proxy when enabled,
# direct otherwise. HOME_VPN_CAMOFOX_ACTIVE is computed by Terraform (home VPN
# configured && home_vpn_camofox).
CAMOFOX_PROXY_HOST=""
if [ "${HOME_VPN_CAMOFOX_ACTIVE:-false}" = true ]; then
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

# Fresh Camofox installs need an initial Reddit login. This runs after
# setup-hermes.sh + restore-backup.sh, which write the narrow credentials file
# reddit-login.py reads; if it isn't there (no Reddit creds yet), leave the
# marker for a later restore-backup.sh run to act on.
if [ "$CAMOFOX_FRESH_INSTALL" = true ]; then
  if [ -f /root/.hermes/.reddit-credentials ]; then
    echo "Logging Camofox into Reddit..."
    python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py || \
      echo "Reddit login failed — run reddit-login.py manually to retry"
  else
    touch /tmp/camofox-needs-reddit-login
  fi
fi

