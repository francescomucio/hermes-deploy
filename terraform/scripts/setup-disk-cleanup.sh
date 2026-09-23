#!/bin/bash
set -euo pipefail

echo "=== Setting up disk cleanup ==="

# Create cleanup script
cat > /usr/local/bin/hermes-cleanup <<'CLEANUPEOF'
#!/bin/bash
set -uo pipefail

# Weekly disk maintenance for the hermes host. Clears regenerable caches
# and logs, prunes scratch data nothing points back to, and repacks any
# git repo sitting on a pile of un-gc'd loose objects. Nothing here touches
# reachable git history, running containers, or profile/app state.
#
# Written 2026-09-07 after / hit 100% and took the hermes container down
# with OSError: [Errno 28] No space left on device — the culprits were
# uv/npm/pip caches, un-vacuumed journald logs, a year of loose git objects
# in data-berlin-jobs (1.8G -> 42M after gc), and finished kanban task
# workspaces nobody cleaned up.

LOG=/var/log/hermes-cleanup.log
STALE_DAYS=30
CUTOFF=$(( $(date +%s) - STALE_DAYS*86400 ))

{
echo "=== hermes-cleanup run: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "--- disk before ---"; df -h /

# Regenerable package caches (both HOME layouts hermes uses)
rm -rf /root/.hermes/.cache/uv /root/.hermes/home/.cache/uv
rm -rf /root/.hermes/.npm/_cacache /root/.hermes/home/.npm/_cacache
rm -rf /root/.hermes/.cache/typescript
rm -rf /root/.hermes/.cache/pip /root/.hermes/home/.cache/pip
rm -rf /root/.hermes/home/.cache/pre-commit
rm -rf /root/.hermes/home/.duckdb/extensions

# System logs & package manager cache
journalctl --vacuum-time=7d
apt-get clean
docker builder prune -f >/dev/null

# Finished/abandoned kanban task workspaces: if no file in the workspace
# has been touched in $STALE_DAYS days, the task is done or dead — remove
# it. Threshold is intentionally longer than the manual cleanup used
# (14d) since this runs unattended with no one reviewing what's still WIP.
for d in /root/.hermes/kanban/workspaces/*/; do
  [ -d "$d" ] || continue
  last=$(find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
  last=${last%%.*}
  if [ -z "$last" ] || [ "$last" -lt "$CUTOFF" ]; then
    echo "removing stale kanban workspace: $d"
    rm -rf "$d"
  fi
done

# Same staleness rule for one-off scratch files/clones dropped in tmp/
for e in /root/.hermes/tmp/*; do
  [ -e "$e" ] || continue
  if [ -d "$e" ]; then
    last=$(find "$e" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    last=${last%%.*}
  else
    last=$(stat -c '%Y' "$e" 2>/dev/null)
  fi
  if [ -z "${last:-}" ] || [ "$last" -lt "$CUTOFF" ]; then
    echo "removing stale tmp entry: $e"
    rm -rf "$e"
  fi
done

# The hermes container's own /tmp (its writable layer, not a bind mount —
# invisible from /root/.hermes). Bots use it as a scratchpad: scraped pages,
# repo clones for PR review, throwaway venvs. Hit 2.7G by 2026-09-23 (a
# 1.6G data-berlin-jobs clone, two PR checkouts, three identical PDF
# venvs). Shorter threshold than above: /tmp is scratch by definition and
# is wiped on every container recreate anyway. Judged by each entry's
# newest file, so anything a bot is still writing into is kept.
TMP_STALE_DAYS=7
docker exec hermes sh -c '
  cutoff=$(( $(date +%s) - '"$TMP_STALE_DAYS"'*86400 ))
  for e in /tmp/* /tmp/.[!.]*; do
    [ -e "$e" ] || continue
    last=$(find "$e" -xdev -printf "%T@\n" 2>/dev/null | sort -rn | head -1)
    last=${last%%.*}
    if [ -n "$last" ] && [ "$last" -lt "$cutoff" ]; then
      echo "removing stale container tmp entry: $e"
      rm -rf "$e"
    fi
  done
' || echo "container /tmp cleanup skipped (hermes container not running?)"

# A bot once created a 4G swapfile in its own data dir (2026-07-18) — it
# can't be activated from inside a container, so it was pure dead weight.
# Real swap is /swapfile on the host (setup-hermes.sh).
if [ -f /root/.hermes/swapfile ] && ! swapon --show=NAME --noheadings | grep -qx /root/.hermes/swapfile; then
  echo "removing unusable /root/.hermes/swapfile"
  rm -f /root/.hermes/swapfile
fi

# Opportunistic git gc: repack any repo whose loose objects exceed 50MB.
# `git gc` never drops reachable history, so this is safe even on repos
# with uncommitted local changes.
#
# This runs as root, but these repos are owned by the container user
# (uid 10000, bind-mounted from the host) — plain `git gc` here writes new
# packs/refs/reflogs as root, leaving files the container user can no
# longer commit/push through (bit us once: 2026-09-07, blocked Claudiano's
# push until the root-owned reflogs were manually cleared). Preserve the
# repo's existing owner across the gc instead of just running as root.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
find /root/.hermes -maxdepth 4 -type d -name .git 2>/dev/null | while read -r gitdir; do
  repo=$(dirname "$gitdir")
  loose_kb=$(git -C "$repo" count-objects -v 2>/dev/null | awk '/^size:/{print $2}')
  if [ -n "${loose_kb:-}" ] && [ "$loose_kb" -gt 51200 ]; then
    echo "git gc: $repo (${loose_kb}KB loose objects)"
    owner=$(stat -c '%u:%g' "$repo")
    git -C "$repo" gc --quiet || true
    chown -R "$owner" "$gitdir"
  fi
done

echo "--- disk after ---"; df -h /
echo
} >> "$LOG" 2>&1
CLEANUPEOF
chmod +x /usr/local/bin/hermes-cleanup

# Weekly cron, offset an hour after the daily R2 backup (03:00 UTC) so the
# two never touch /root/.hermes at the same time.
CRON_LINE="0 4 * * 0 /usr/local/bin/hermes-cleanup"
(crontab -l 2>/dev/null | grep -v hermes-cleanup; echo "$CRON_LINE") | crontab -

echo "=== Disk cleanup configured (weekly Sunday 04:00 UTC) ==="
