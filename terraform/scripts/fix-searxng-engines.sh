#!/bin/bash
# Re-apply this deployment's SearXNG settings on a RUNNING host, restart the container and
# smoke-test a few queries.
#
#   ssh root@<server> 'bash -s' < terraform/scripts/fix-searxng-engines.sh
#
# The settings themselves live in ONE place: setup-searxng.sh (also run by Terraform as
# null_resource.hermes_searxng). This wrapper runs the server's copy of it from the deploy
# checkout (/opt/hermes-deploy, kept current by the 5-min hermes-sync cron), so push the
# change first, or run `cd /opt/hermes-deploy && git pull` before this.
#
# Context (2026-11-15): every general-category engine SearXNG enables by default (google,
# duckduckgo, startpage, brave) is blocked for this host's datacenter IP — CAPTCHA,
# "Suspended: CAPTCHA", "too many requests" — so `/search?format=json` returned an empty
# result set for ordinary queries while non-search HTTP still worked fine. Verified from
# this host: `seznam` and `bing` DO answer, so they carry general search here and the
# blocked engines are explicitly disabled to stop paying their timeouts.
#
# Agents cannot run this themselves: the hermes container has no Docker socket and
# /opt/searxng is not mounted into it.
#
# Idempotent: re-running installs the same settings and restarts SearXNG. The home VPN
# proxy setting is kept as it is (marker file /opt/searxng/.home-vpn-proxy).
set -euo pipefail

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the Hetzner host as root" >&2; exit 1; }
SETUP=/opt/hermes-deploy/terraform/scripts/setup-searxng.sh
[ -f "$SETUP" ] || { echo "$SETUP not found — is the deploy repo checked out?" >&2; exit 1; }

DEST=/opt/searxng/settings.yml
if [ -f "$DEST" ]; then
  backup="$DEST.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "$DEST" "$backup"
  echo "backed up $DEST -> $backup"
fi

bash "$SETUP"
echo "installed $DEST and restarted searxng"

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
