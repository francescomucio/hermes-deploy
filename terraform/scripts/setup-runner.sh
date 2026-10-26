#!/bin/bash
set -euo pipefail

# Self-hosted GitHub Actions runners for the private site repos (Scritto nelle
# stelle, later Data Berlin), so their builds don't burn GitHub minutes.
# Nothing in common with Hermes or Umami except the host and the Docker engine:
# - one fresh container per job (`docker run --rm`, runner --ephemeral), so
#   nothing a job leaves behind reaches the next one;
# - own bridge network, firewalled from the host itself (Hermes uses the host
#   network: its ports would otherwise be reachable via the gateway) and from
#   Hetzner's metadata service: internet only;
# - no host mounts, no Docker socket, no capabilities, no sudo
#   (no-new-privileges), CPU/memory caps with low CPU priority;
# - the GitHub token only ever lives on the host: it mints a one-hour
#   registration token per job, and only that enters the container.
# /tmp/github-runners.tsv: one "name<TAB>org-or-repo URL<TAB>token" line per runner.

echo "=== Setting up GitHub Actions runners ==="

DIR=/opt/github-runner
SUBNET=172.30.0.0/24
mkdir -p "$DIR"
chmod 700 "$DIR"

docker network inspect github-runner >/dev/null 2>&1 ||
  docker network create --driver bridge --subnet "$SUBNET" github-runner >/dev/null

cat > /usr/local/bin/github-runner-job <<'JOBEOF'
#!/bin/bash
# One job: register an ephemeral runner, run a single job, exit. systemd
# (github-runner@NAME) starts the next one.
set -euo pipefail
NAME=$1
SUBNET=172.30.0.0/24
IMAGE=ghcr.io/actions/actions-runner:latest   # tracked, not pinned: GitHub stops sending jobs to outdated runners
source /opt/github-runner/$NAME.env           # GH_URL, GH_TOKEN

# Firewall, re-applied every time (iptables rules don't survive a reboot)
rule() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
rule INPUT -s "$SUBNET" -j DROP                              # the host itself, any of its addresses
for dst in 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  rule DOCKER-USER -s "$SUBNET" -d "$dst" -j DROP            # metadata service, private ranges
done

# Org runner for https://github.com/ORG, repo runner for https://github.com/OWNER/REPO
TARGET=${GH_URL#https://github.com/}
case "$TARGET" in */*) API=repos/$TARGET ;; *) API=orgs/$TARGET ;; esac
REG_TOKEN=$(curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/$API/actions/runners/registration-token" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
export REG_TOKEN GH_URL RUNNER_NAME="hermes-$NAME-$(date +%s)"

docker pull -q "$IMAGE" >/dev/null || true
docker rm -f "gh-runner-$NAME" >/dev/null 2>&1 || true
exec docker run --rm --name "gh-runner-$NAME" --network github-runner \
  --cpus 3 --cpu-shares 256 --memory 4g --memory-swap 4g --pids-limit 4096 \
  --security-opt no-new-privileges --cap-drop ALL \
  -e REG_TOKEN -e GH_URL -e RUNNER_NAME \
  --entrypoint bash "$IMAGE" -c '
    ./config.sh --unattended --ephemeral --disableupdate --replace \
      --url "$GH_URL" --token "$REG_TOKEN" --name "$RUNNER_NAME" --labels hermes >/dev/null
    unset REG_TOKEN
    exec ./run.sh'
JOBEOF
chmod +x /usr/local/bin/github-runner-job

cat > /etc/systemd/system/github-runner@.service <<'EOF'
[Unit]
Description=GitHub Actions runner %i (one fresh container per job)
After=docker.service network-online.target
Requires=docker.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/github-runner-job %i
ExecStop=-/usr/bin/docker stop -t 60 gh-runner-%i
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# Runners from the list: env file + unit; runners no longer listed: stopped and removed
WANTED=""
while IFS=$'\t' read -r name url token; do
  [ -n "$name" ] || continue
  WANTED="$WANTED $name"
  umask 077
  printf 'GH_URL=%q\nGH_TOKEN=%q\n' "$url" "$token" > "$DIR/$name.env.new"
  if ! cmp -s "$DIR/$name.env.new" "$DIR/$name.env" 2>/dev/null; then
    mv "$DIR/$name.env.new" "$DIR/$name.env"
    systemctl enable -q "github-runner@$name"
    systemctl restart "github-runner@$name"   # pick up a new URL/token
  else
    rm -f "$DIR/$name.env.new"
    systemctl enable -q --now "github-runner@$name"
  fi
  echo "runner $name → $url"
done < /tmp/github-runners.tsv

for f in "$DIR"/*.env; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .env)
  case " $WANTED " in *" $name "*) ;; *)
    systemctl disable -q --now "github-runner@$name" || true
    rm -f "$f"
    echo "runner $name removed" ;;
  esac
done

rm -f /tmp/github-runners.tsv
echo "=== GitHub runners configured:${WANTED:- none} ==="
