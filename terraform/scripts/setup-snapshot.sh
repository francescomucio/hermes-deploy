#!/bin/bash
set -euo pipefail

echo "=== Setting up live → hermes-live snapshot ==="

# Hermes is the source of truth for config.yaml and for the skills the agents
# write themselves (Claudiano and the curator keep tuning both live). This
# daily job mirrors them into the PRIVATE repo francescomucio/hermes-live:
#   /root/.hermes/config.yaml            → config.yaml
#   /root/.hermes/profiles/*/config.yaml → profiles/*/config.yaml
#   agent-created skills                 → skills/, profiles/*/skills/
# It never writes to the public deploy repo, and hermes-sync never reads from
# this one, so live skill edits can't be overwritten by a stale copy.
# Even in a private repo, api keys/tokens are blanked and the commit is
# aborted if the staged diff still looks like it carries a secret.

LIVE_REPO_URL="git@github-live:francescomucio/hermes-live.git"
LIVE_KEY=/root/.ssh/hermes_live_key

# Own deploy key, write access to hermes-live only (separate from the public
# deploy repo's key). A fresh server gets a fresh key, which must be added to
# the repo's deploy keys before the first push succeeds.
if [ ! -f "$LIVE_KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "hermes-live@hermes" -f "$LIVE_KEY"
  echo "NEW deploy key — add it (write access) to francescomucio/hermes-live:"
  cat "$LIVE_KEY.pub"
fi
grep -q "^Host github-live$" /root/.ssh/config 2>/dev/null || cat >> /root/.ssh/config <<EOF

Host github-live
  HostName github.com
  User git
  IdentityFile $LIVE_KEY
  IdentitiesOnly yes
  StrictHostKeyChecking no
EOF

cat > /usr/local/lib/hermes-snapshot.py <<'PYEOF'
import os, re, shutil, sys

live, repo, image_skills = sys.argv[1], sys.argv[2], sys.argv[3]

# Names of the skills shipped in the running Hermes image (skills/ and
# optional-skills/): profiles get copies of these, they're not agent-written.
with open(image_skills) as f:
    SHIPPED = {l.strip() for l in f if l.strip()}

SECRET_KEY = re.compile(
    r"^(\s*(?:api_key|token|secret|password|access_token|client_secret|bot_token):\s*)"
    r"(?!''\s*$)(?!\"\"\s*$)(?!null\s*$)(?!~\s*$)\S.*$", re.M)
JUNK = {"__pycache__", ".venv", "venv", "node_modules", ".pytest_cache", ".ruff_cache"}


def copy_config(src, dst):
    if not os.path.isfile(src):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src) as f:
        text = SECRET_KEY.sub(r"\1''", f.read())
    with open(dst, "w") as f:
        f.write(text)


def bundled(skills_root):
    # .bundled_manifest lists the skills shipped with Hermes (name:hash per line)
    path = f"{skills_root}/.bundled_manifest"
    if not os.path.isfile(path):
        return set()
    with open(path) as f:
        return {l.split(":", 1)[0].strip() for l in f if l.strip()}


def ignore(d, names):
    return [n for n in names if n in JUNK or n.endswith(".pyc")
            or (n.startswith(".") and os.path.isdir(os.path.join(d, n)))]


def export_skills(rel_root):
    src_root = f"{live}/{rel_root}"
    shutil.rmtree(f"{repo}/{rel_root}", ignore_errors=True)
    if not os.path.isdir(src_root):
        return
    skip = bundled(src_root) | SHIPPED
    chosen = []
    for dirpath, dirnames, filenames in os.walk(src_root):
        # .archive, .hub (hub installs), .curator_backups: not agent-written
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in JUNK)
        if "SKILL.md" not in filenames:
            continue
        rel = os.path.relpath(dirpath, live)
        if os.path.basename(dirpath) in skip:
            dirnames[:] = []
        elif not any(rel.startswith(c + "/") for c in chosen):
            chosen.append(rel)  # nested skills are copied with their parent
    for rel in chosen:
        shutil.copytree(f"{live}/{rel}", f"{repo}/{rel}", ignore=ignore)
    print(f"{rel_root}: {len(chosen)} skill(s)")


copy_config(f"{live}/config.yaml", f"{repo}/config.yaml")
export_skills("skills")
for p in sorted(os.listdir(f"{live}/profiles")):
    if os.path.isdir(f"{live}/profiles/{p}"):
        copy_config(f"{live}/profiles/{p}/config.yaml", f"{repo}/profiles/{p}/config.yaml")
        export_skills(f"profiles/{p}/skills")
PYEOF

cat > /usr/local/bin/hermes-snapshot <<'SNAPEOF'
#!/bin/bash
set -euo pipefail

REPO=/opt/hermes-live
LIVE=/root/.hermes
LOG=/var/log/hermes-snapshot.log
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

exec 201>/var/lock/hermes-snapshot.lock
flock -n 201 || exit 0

cd "$REPO"
git pull --rebase --quiet origin main 2>/dev/null || true  # empty remote on first run

SHIPPED=$(mktemp)
trap 'rm -f "$SHIPPED"' EXIT
if ! docker exec hermes sh -c 'find /opt/hermes/skills /opt/hermes/optional-skills -name SKILL.md' \
    > "$SHIPPED" || [ ! -s "$SHIPPED" ]; then
  log "ABORTED: can't list the skills shipped in the hermes image (container down?)"
  exit 1
fi
# Plus the host's hermes-agent clone (/opt/hermes, older than the image):
# skills bundled by earlier releases stay copied into the profiles after
# upstream drops or renames them.
find /opt/hermes/skills /opt/hermes/optional-skills -name SKILL.md 2>/dev/null >> "$SHIPPED" || true
xargs -rn1 dirname < "$SHIPPED" | xargs -rn1 basename | sort -u > "$SHIPPED.names"
mv "$SHIPPED.names" "$SHIPPED"

python3 /usr/local/lib/hermes-snapshot.py "$LIVE" "$REPO" "$SHIPPED" >/dev/null

git add -A .
if git diff --cached --quiet; then
  log "no changes"
  exit 0
fi

if git diff --cached -U0 | grep '^+' | grep -qE \
  '(ghp_|gho_|github_pat_)[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9-])sk-[A-Za-z0-9_-]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|[0-9a-f]{32}\.[A-Za-z0-9]{16,}'; then
  git reset -q
  log "ABORTED: staged diff looks like it contains a secret, nothing committed"
  exit 1
fi

CHANGED=$(git diff --cached --name-only | wc -l)
git commit -q -m "snapshot $(date -u +%F): $CHANGED file"
git push -q origin HEAD:main
log "committed and pushed $CHANGED file(s)"
SNAPEOF
chmod +x /usr/local/bin/hermes-snapshot

if [ ! -d /opt/hermes-live/.git ]; then
  git init -q -b main /opt/hermes-live
  git -C /opt/hermes-live remote add origin "$LIVE_REPO_URL"
  git -C /opt/hermes-live config user.name "Hermes snapshot"
  git -C /opt/hermes-live config user.email "snapshot@hermes"
  cat > /opt/hermes-live/README.md <<'EOF'
# hermes-live

Daily mirror of the live Hermes state: `config.yaml` (root and per profile, keys
blanked) and the skills the agents wrote themselves. Written by
`/usr/local/bin/hermes-snapshot` on the server (02:30 UTC), set up by
`terraform/scripts/setup-snapshot.sh` in hermes-deploy. Read-only: changes made
here don't reach the server.
EOF
fi

# Daily at 02:30 UTC, before the 03:00 R2 backup
CRON_LINE="30 2 * * * /usr/local/bin/hermes-snapshot"
(crontab -l 2>/dev/null | grep -v hermes-snapshot; echo "$CRON_LINE") | crontab -

echo "=== Snapshot configured (daily at 02:30 UTC → hermes-live) ==="
