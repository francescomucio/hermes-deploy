#!/bin/bash
# Re-apply this deployment's SearXNG settings on a RUNNING host and restart the container.
#
#   ssh root@<server> 'bash -s' < terraform/scripts/fix-searxng-engines.sh
#
# Context (2026-11-15): every general-category engine SearXNG enables by default (google,
# duckduckgo, startpage, brave) is blocked for this host's datacenter IP — CAPTCHA,
# "Suspended: CAPTCHA", "too many requests" — so `/search?format=json` returned an empty
# result set for ordinary queries while non-search HTTP still worked fine. Verified from
# this host: `seznam` and `bing` DO answer, so they carry general search here and the
# blocked engines are explicitly disabled to stop paying their timeouts.
# SearXNG only reads settings.yml at start, hence the restart.
#
# Agents cannot run this themselves: the hermes container has no Docker socket and
# /opt/searxng is not mounted into it.
#
# Idempotent: re-running installs the same settings and restarts SearXNG.
set -euo pipefail

DEST=/opt/searxng/settings.yml
command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the Hetzner host as root" >&2; exit 1; }

mkdir -p /opt/searxng
if [ -f "$DEST" ]; then
  backup="$DEST.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "$DEST" "$backup"
  echo "backed up $DEST -> $backup"
fi

cat > "$DEST" <<'SEARXEOF'
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
  # may cool down on its own (README "Google — not solved"). No `proxies:` override here —
  # the home-IP SOCKS5 tunnel is opt-in and started manually (`ssh -R 1080 ...`), not a
  # standing service; pointing google at 127.0.0.1:1080 unconditionally made every query
  # fail with a bare "proxy error" whenever the tunnel wasn't running.
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
echo "installed $DEST"

docker restart searxng >/dev/null
echo "restarted searxng — waiting for it to answer"
for _ in $(seq 1 30); do
  curl -sf -m 5 -o /dev/null http://127.0.0.1:8080/ && break
  sleep 1
done

fail=0
for q in "data engineering newsletter" "duckdb release notes" "capital of France"; do
  out=$(curl -s -m 40 --get --data-urlencode "q=$q" --data-urlencode "format=json" \
        http://127.0.0.1:8080/search || true)
  n=$(printf '%s' "$out" | grep -o '"url":' | wc -l | tr -d ' ')
  printf '  %-30s -> %s results\n' "$q" "$n"
  [ "${n:-0}" -gt 0 ] || fail=1
done

if [ "$fail" -ne 0 ]; then
  echo "FAIL: a general query still returns nothing — inspect 'docker logs --tail 100 searxng'" >&2
  exit 1
fi
echo "OK: general search returns results"
