#!/bin/bash
# Post-deploy health check. Runs at the end of every `terraform apply`.
#
# Rule for every check here: report what the actual consumer sees, not an
# intermediate state that looks right. A container being "Up" isn't the
# same as Discord actually being connected; a config file containing the
# right text isn't the same as every profile's copy agreeing with it.
# Failures must reach this script's own exit code, or Terraform will report
# a green apply while something is actually broken — exactly what happened
# with Barbero's Reddit access drifting silently for hours.
set -uo pipefail

set -a
source /tmp/hermes-deploy.env
set +a

FAIL=0
WARN=0

pass() { echo "  OK   $1"; }
warn() { echo "  WARN $1"; WARN=$((WARN + 1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

echo "=== Verifying deploy ==="

echo "--- Containers ---"
for name in hermes searxng camofox-browser hermes-dashboard; do
  status=$(docker ps --filter "name=^${name}\$" --format '{{.Status}}')
  if [ -z "$status" ]; then
    fail "$name is not running"
  elif [[ "$status" != Up* ]]; then
    fail "$name status: $status"
  else
    pass "$name: $status"
  fi
done

echo "--- Gateway assignment (per profile) ---"
# Not a blind process count — this project runs one dedicated gateway
# process per profile that has its own Discord bot token, plus the
# always-on "default" one sharing the main bot. The real invariant is:
# default is up, every token-holding profile is up, and no other named
# profile is running (if one is, it's silently sharing a token it
# shouldn't — exactly how Cannavacciuolo kept stealing Bruno Barbieri's
# and then Claudiano's session tonight).
gw_list=$(docker exec hermes /opt/hermes/.venv/bin/hermes gateway list 2>/dev/null)
gw_issues=$(echo "$gw_list" | PROFILE_DISCORD_TOKENS="$PROFILE_DISCORD_TOKENS" python3 -c "
import json, os, re, sys
tokens = json.loads(os.environ['PROFILE_DISCORD_TOKENS'])
profiles_with_tokens = {p for p, t in tokens.items() if t}
lines = sys.stdin.read().splitlines()
seen = {}
for line in lines:
    m = re.match(r'\s*([✓✗])\s+(\S+)', line)
    if not m:
        continue
    seen[m.group(2)] = (m.group(1) == '✓')

if not seen.get('default'):
    print('default gateway is not running')
for profile in sorted(profiles_with_tokens):
    if not seen.get(profile):
        print(f'{profile} has a Discord token but its gateway is not running')
for profile, running in sorted(seen.items()):
    if profile == 'default' or profile in profiles_with_tokens:
        continue
    if running:
        print(f'{profile} is running but has no assigned token (likely sharing another profile\'s Discord session)')
")
if [ -z "$gw_issues" ]; then
  pass "gateway assignment: $(echo "$gw_list" | tr '\n' ' ')"
else
  while IFS= read -r issue; do
    fail "$issue"
  done <<< "$gw_issues"
fi

echo "--- Discord connection ---"
if docker exec hermes grep -q "Connected as" /opt/data/logs/gateway.log 2>/dev/null; then
  pass "Discord connected"
else
  fail "no \"Connected as\" line in gateway.log — Discord may not be connected"
fi

echo "--- Config consistency (root vs. every profile) ---"
root_model=$(docker exec hermes sed -n '0,/^  default: /{s/^  default: //p}' /opt/data/config.yaml)
root_max_turns=$(docker exec hermes sed -n '0,/^  max_turns: /{s/^  max_turns: //p}' /opt/data/config.yaml)
root_auto_thread=$(docker exec hermes sed -n '0,/^  auto_thread: /{s/^  auto_thread: //p}' /opt/data/config.yaml)
pass "root: model=$root_model max_turns=$root_max_turns auto_thread=$root_auto_thread"

for pc in $(docker exec hermes sh -c 'ls /opt/data/profiles/*/config.yaml 2>/dev/null' || true); do
  profile=$(basename "$(dirname "$pc")")
  p_model=$(docker exec hermes sed -n '0,/^  default: /{s/^  default: //p}' "$pc")
  p_max_turns=$(docker exec hermes sed -n '0,/^  max_turns: /{s/^  max_turns: //p}' "$pc")
  p_auto_thread=$(docker exec hermes sed -n '0,/^  auto_thread: /{s/^  auto_thread: //p}' "$pc")
  drift=""
  [ -n "$p_model" ] && [ "$p_model" != "$root_model" ] && drift="${drift}model=$p_model(root=$root_model) "
  [ -n "$p_max_turns" ] && [ "$p_max_turns" != "$root_max_turns" ] && drift="${drift}max_turns=$p_max_turns(root=$root_max_turns) "
  [ -n "$p_auto_thread" ] && [ "$p_auto_thread" != "$root_auto_thread" ] && drift="${drift}auto_thread=$p_auto_thread(root=$root_auto_thread) "
  if [ -n "$drift" ]; then
    fail "profile $profile has diverged from root: $drift"
  else
    pass "profile $profile matches root (or has no override)"
  fi

  if docker exec hermes grep -q "user_id: ''" "$pc" 2>/dev/null; then
    fail "profile $profile has an empty Camofox user_id (will get a fresh, unauthenticated session every task)"
  fi
done

echo "--- Reddit session ---"
reddit_out=$(python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py 2>&1)
if echo "$reddit_out" | grep -q "Already logged in"; then
  pass "Reddit session valid, no login needed"
elif echo "$reddit_out" | grep -q "Reddit login OK"; then
  warn "Reddit session had expired and was just re-logged-in — worth knowing, not necessarily a problem"
else
  fail "Reddit login check failed: $reddit_out"
fi

echo "--- Backup freshness ---"
# Reads /var/log/hermes-backup.log, not /opt/data/.backup-status: that
# file lives inside /root/.hermes, which restore-backup.sh's rclone copy
# overwrites from R2 on every deploy — right after a restore it reflects
# whatever snapshot R2 had, not the true latest completion, causing a
# false "stale" reading for up to 30 minutes after every deploy. The log
# lives outside /root/.hermes and is never touched by the restore.
last_backup=$(grep "backup complete" /var/log/hermes-backup.log 2>/dev/null | tail -1 | awk '{print $1}')
if [ -z "$last_backup" ]; then
  warn "no successful backup found in /var/log/hermes-backup.log yet (expected on a brand-new deploy)"
else
  last_epoch=$(date -d "$last_backup" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age_min=$(( (now_epoch - last_epoch) / 60 ))
  if [ "$last_epoch" -eq 0 ]; then
    warn "couldn't parse backup timestamp: $last_backup"
  elif [ "$age_min" -gt 40 ]; then
    fail "last backup was ${age_min}m ago (expected every 30m)"
  else
    pass "last backup ${age_min}m ago"
  fi
fi

echo "--- Disk space ---"
disk_pct=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$disk_pct" -ge 90 ]; then
  fail "disk at ${disk_pct}%"
elif [ "$disk_pct" -ge 80 ]; then
  warn "disk at ${disk_pct}%"
else
  pass "disk at ${disk_pct}%"
fi

echo "--- SearXNG reachable ---"
# GitHub only — the one engine that's never been rate-limited by this
# project's own testing. Deliberately not exercising Google/DuckDuckGo/etc.
# here: a routine check that fires on every deploy is exactly the kind of
# repeated automated query volume that got those engines CAPTCHA'd earlier.
gh_results=$(curl -s "http://127.0.0.1:8080/search?q=%21gh+test&format=json" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('results',[])))" 2>/dev/null || echo 0)
if [ "$gh_results" -gt 0 ]; then
  pass "SearXNG responds (github engine, $gh_results results)"
else
  fail "SearXNG github engine returned 0 results"
fi

echo "=== Summary: $FAIL failed, $WARN warned ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
