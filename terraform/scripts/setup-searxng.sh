#!/bin/bash
set -euo pipefail

# SearXNG settings (engines, home VPN proxy) + restart.
# Run by Terraform (null_resource, see main.tf) after setup-hermes.sh; re-runs
# only when this script or its own env file (/root/.deploy-staging/hermes-searxng.env) changes.
#
# Also runnable by hand on the host (fix-searxng-engines.sh does that): without
# the env file, the home VPN proxy setting is kept as it was (marker file).
if [ -f /root/.deploy-staging/hermes-searxng.env ]; then
  set -a
  source /root/.deploy-staging/hermes-searxng.env
  set +a
  rm -f /root/.deploy-staging/hermes-searxng.env
elif [ -f /opt/searxng/.home-vpn-proxy ]; then
  HOME_VPN_WEB_ACTIVE=true
fi
HOME_VPN_WEB_ACTIVE=${HOME_VPN_WEB_ACTIVE:-false}

# SearXNG config — the single source of the engine list
# (fix-searxng-engines.sh runs this same script from the server's checkout).
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
  # may cool down on its own (README "Google — not solved"). With home VPN web egress on,
  # every engine goes out via the home IP (`outgoing.proxies`, appended below) — testing
  # showed that alone doesn't unblock Google, so it stays disabled.
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

# Home VPN web egress: all SearXNG engine requests go out via the home IP.
# The marker file tells fix-searxng-engines.sh (which rewrites settings.yml
# on its own) to append the same block.
if [ "$HOME_VPN_WEB_ACTIVE" = true ]; then
  cat >> /opt/searxng/settings.yml <<'SEARXEOF'

outgoing:
  proxies:
    all://: socks5h://127.0.0.1:1080
SEARXEOF
  touch /opt/searxng/.home-vpn-proxy
else
  rm -f /opt/searxng/.home-vpn-proxy
fi

# Restart SearXNG to pick up the new settings (only this container, no
# impact on the gateway/dashboard or Discord bot connections)
docker restart searxng >/dev/null 2>&1 || true

for _ in $(seq 1 30); do
  curl -sf -m 5 -o /dev/null http://127.0.0.1:8080/ && break
  sleep 1
done
