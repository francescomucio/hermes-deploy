#!/bin/bash
set -euo pipefail

# Load config
set -a
source /tmp/hermes-deploy.env
set +a

echo "=== Restoring from R2 backup ==="

# The R2 restore (rclone copy of the whole /root/.hermes tree — sessions,
# logs, profile data) is the single biggest cost of every deploy, often
# 5+ minutes on its own, dominated by per-object API overhead across
# thousands of small files rather than actual data volume. It's only
# genuinely needed once: populating a brand-new server. On an
# already-provisioned server, the live filesystem IS the current state —
# restoring FROM the backup INTO it on every routine apply (a token
# swap, a config tweak, a script fix) doesn't accomplish anything except
# cost several minutes, since cron backs up the live state every 30 min
# regardless. Skipped by default once a server looks provisioned;
# force it back on for a genuine one-off (disaster recovery, suspected
# local corruption) with `terraform apply -var="force_restore=true"` —
# deliberately not something to leave set in tfvars, or every future
# apply would pay this cost again for no reason.
if [ -f /root/.hermes/config.yaml ] && [ "${FORCE_RESTORE:-false}" != "true" ]; then
  echo "Server already provisioned and force_restore not set — skipping R2 restore."
  echo "(pass -var=\"force_restore=true\" to terraform apply to force one anyway)"
else
  # Lock shared with hermes-backup: wait for any in-flight backup upload to
  # finish (and block new ones) before touching /root/.hermes, so restore
  # and backup never race against each other.
  exec 200>/var/lock/hermes-backup.lock
  if ! flock -w 300 200; then
    echo "Could not acquire backup lock within 5 minutes — a backup/restore is stuck. Aborting."
    exit 1
  fi

  # Install rclone if not present
  if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl -s https://rclone.org/install.sh | bash
  fi

  # Configure rclone for R2
  mkdir -p /root/.config/rclone
  cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_ENDPOINT
acl = private
no_check_bucket = true
EOF

  # Check if backup exists
  BACKUP_SIZE=$(rclone size r2:hermes-backups/latest/ 2>/dev/null | grep "Total size" || echo "")
  if [ -z "$BACKUP_SIZE" ]; then
    echo "No backup found in r2:hermes-backups/latest/"
    echo "Skipping restore — starting fresh."
  else
    echo "Found backup: $BACKUP_SIZE"

    # Stop containers before restore
    cd /opt/hermes && docker compose stop gateway 2>/dev/null || true

    # Restore from R2 to the volume
    echo "Restoring data..."
    rclone copy r2:hermes-backups/latest/ /root/.hermes/ \
      --transfers 4

    # Fix ownership
    chown -R 10000:10000 /root/.hermes/

    echo "Restored: $BACKUP_SIZE"
  fi
fi

# Gateway may be stopped (restore path above) or already running (fresh
# install) — bring it up and wait until docker exec works before touching
# config.yaml. `up -d` is a safe no-op if it's already running.
cd /opt/hermes && docker compose up -d gateway
until docker exec hermes echo ready 2>/dev/null; do
  echo "Waiting for hermes container..."
  sleep 3
done

# Config corrections that must survive a restore — these run here (not in
# setup-hermes.sh) because this script's rclone copy above overwrites
# config.yaml from the R2 backup, which would silently revert any edits
# made earlier in the deploy. Idempotent, safe to run every time.
docker exec hermes sed -i \
  "s|default: anthropic/claude-opus-4.6|default: $OLLAMA_MODEL|; s|base_url: https://openrouter.ai/api/v1|base_url: https://ollama.com/v1|; s|auto_thread: true|auto_thread: false|; s|max_turns: 90|max_turns: 100|" \
  /opt/data/config.yaml
docker exec hermes grep -q '^- browser$' /opt/data/config.yaml || \
  docker exec hermes sed -i '/^- hermes-cli$/a\- browser' /opt/data/config.yaml
# Fixed Camofox identity so browser_navigate reuses the persisted Reddit
# login (see reddit-login.py) instead of a fresh random session each task.
docker exec hermes sed -i "s|user_id: ''|user_id: hermes-reddit|" /opt/data/config.yaml

# A Hermes profile can carry its own FULL config.yaml that shadows the root
# one entirely for that profile's behavior — not merged key-by-key.
# researcher's does (a ~600-line standalone copy, not a small override),
# which is how Barbero silently ended up on a different model/max_turns/
# auto_thread AND an unauthenticated Camofox identity despite every
# correction above landing correctly in the root file. Propagate the same
# corrected values to every profile config.yaml that defines them — first
# occurrence only, so unrelated nested keys with the same name (e.g.
# goals.max_turns) aren't touched — so this class of drift can't recur for
# any profile, present or future, without a manual patch each time.
ROOT_MODEL=$(docker exec hermes sed -n '0,/^  default: /{s/^  default: //p}' /opt/data/config.yaml)
ROOT_MAX_TURNS=$(docker exec hermes sed -n '0,/^  max_turns: /{s/^  max_turns: //p}' /opt/data/config.yaml)
ROOT_AUTO_THREAD=$(docker exec hermes sed -n '0,/^  auto_thread: /{s/^  auto_thread: //p}' /opt/data/config.yaml)
for pc in $(docker exec hermes sh -c 'ls /opt/data/profiles/*/config.yaml 2>/dev/null' || true); do
  docker exec hermes sed -i "0,/^  default: /{s|^  default: .*|  default: $ROOT_MODEL|}" "$pc"
  docker exec hermes sed -i "0,/^  max_turns: /{s|^  max_turns: .*|  max_turns: $ROOT_MAX_TURNS|}" "$pc"
  docker exec hermes sed -i "0,/^  auto_thread: /{s|^  auto_thread: .*|  auto_thread: $ROOT_AUTO_THREAD|}" "$pc"
  docker exec hermes sed -i "s|user_id: ''|user_id: hermes-reddit|" "$pc"
done

# Narrow, Reddit-only credentials file for reddit-login.py — deliberately
# NOT /tmp/hermes-deploy.env, which also holds Discord tokens, R2 keys, the
# email password and API keys. Claudiano/Barbero can safely run
# reddit-login.py themselves (it only ever reads this file), without ever
# needing to touch the shared secrets blob. Lives in the volume so it
# survives restarts and is visible at /opt/data/.reddit-credentials inside
# the container as well as /root/.hermes/.reddit-credentials on the host.
if [ -n "${REDDIT_USERNAME:-}" ] && [ -n "${REDDIT_PASSWORD:-}" ]; then
  cat > /root/.hermes/.reddit-credentials <<EOF
REDDIT_USERNAME=$REDDIT_USERNAME
REDDIT_PASSWORD=$REDDIT_PASSWORD
EOF
  chmod 600 /root/.hermes/.reddit-credentials
  chown 10000:10000 /root/.hermes/.reddit-credentials
fi

# Same narrow-file pattern for Blind (teamblind.com) — see blind-login.py.
if [ -n "${BLIND_USERNAME:-}" ] && [ -n "${BLIND_PASSWORD:-}" ]; then
  cat > /root/.hermes/.blind-credentials <<EOF
BLIND_USERNAME=$BLIND_USERNAME
BLIND_PASSWORD=$BLIND_PASSWORD
EOF
  chmod 600 /root/.hermes/.blind-credentials
  chown 10000:10000 /root/.hermes/.blind-credentials
fi

# Fresh Camofox installs (marker left by setup-hermes.sh) need an initial
# Reddit login — the credentials file above just became available.
if [ -f /tmp/camofox-needs-reddit-login ]; then
  echo "Logging Camofox into Reddit..."
  python3 /opt/hermes-deploy/terraform/scripts/reddit-login.py || \
    echo "Reddit login failed — run reddit-login.py manually to retry"
  rm -f /tmp/camofox-needs-reddit-login
fi

# Restart to pick up the corrected config.yaml (Hermes reads it at startup
# only). Runs BEFORE the per-profile Discord bot block below, not after —
# `docker compose restart gateway` resets s6's runtime service state back
# to its static defaults, undoing any `s6-svc -d` stop from a prior run.
# Confirmed live: with this restart last, a profile explicitly stopped
# below would come right back up on this restart, and — without its own
# .env, since that part of the fix does hold — silently fall back to
# connecting on the *shared default* bot token instead, alongside
# whichever profile already legitimately uses it. The per-profile start/
# stop below needs to be the actual last word.
cd /opt/hermes && docker compose restart gateway 2>/dev/null || true
until docker exec hermes echo ready 2>/dev/null; do
  echo "Waiting for hermes container..."
  sleep 3
done

# Per-profile Discord bots (from PROFILE_DISCORD_TOKENS map). Runs here,
# not in setup-hermes.sh, because this script's rclone copy above would
# otherwise silently restore a removed profile's stale .env right back —
# confirmed live: swapping which profile owns a token stopped the old
# profile's gateway for the moment, but the restore brought its .env back
# from an older R2 snapshot, and it reconnected with a token that had
# since been reassigned, racing the new profile for the same Discord
# session.
echo "$PROFILE_DISCORD_TOKENS" | python3 -c "
import glob, sys, json, os
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

for env_path in glob.glob('/root/.hermes/profiles/*/.env'):
    profile = env_path.split('/')[-2]
    if not tokens.get(profile):
        os.remove(env_path)
        print(f'  Removed stale Discord bot credentials for profile: {profile}')
"

# Start gateway services: only profiles with tokens, stop the rest.
#
# Uses `hermes gateway start/stop` (via HERMES_HOME pointed at the
# profile), NOT raw `s6-svc -u/-d` — found live that s6-svc only changes
# the CURRENT container's runtime state. On every container boot, an
# earlier boot hook (container_boot.py, "reconcile_profile_gateways")
# reads each profile's *persisted* profiles/<name>/gateway_state.json
# and auto-restarts exactly the ones whose `desired_state` says
# "running", regardless of whatever s6 runtime state existed before the
# restart. A profile stopped only via s6-svc comes right back on the very
# next restart (including the config-picking-up restart earlier in this
# same script) — confirmed live twice tonight, the second time by reading
# container_boot.py directly rather than guessing again from timestamps.
# The `hermes gateway` CLI is what actually writes `desired_state`.
docker exec hermes /opt/hermes/.venv/bin/hermes gateway start 2>/dev/null || true
echo "$PROFILE_DISCORD_TOKENS" | python3 -c "
import sys, json, os, subprocess

tokens = json.loads(sys.stdin.read())
profiles_with_tokens = {p for p, t in tokens.items() if t}

result = subprocess.run(['docker', 'exec', 'hermes', 'ls', '/opt/data/profiles/'], capture_output=True, text=True)
# 'default' shows up as a profiles/ subdirectory (deploy-profiles.sh
# copies its SOUL.md/config.yaml there like any other profile), but it
# is NOT a real gateway target the way the others are — the default
# profile's actual home is /opt/data itself, already started explicitly
# above. Including it here stops the main shared-token gateway right
# after starting it (confirmed live: took the whole default gateway
# down with a real outage) since it never appears in
# PROFILE_DISCORD_TOKENS to begin with.
all_profiles = [p for p in result.stdout.split() if p and p != 'default']

for profile in all_profiles:
    home = f'/opt/data/profiles/{profile}'
    if profile in profiles_with_tokens:
        os.system(f'docker exec -e HERMES_HOME={home} hermes /opt/hermes/.venv/bin/hermes gateway start 2>/dev/null || true')
        print(f'  Started gateway: {profile}')
    else:
        os.system(f'docker exec -e HERMES_HOME={home} hermes /opt/hermes/.venv/bin/hermes gateway stop 2>/dev/null || true')
        print(f'  Stopped gateway (no token): {profile}')
"

echo "=== Restore complete ==="
