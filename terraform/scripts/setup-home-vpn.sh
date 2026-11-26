#!/bin/bash
set -euo pipefail

# Home VPN egress: wireproxy (WireGuard to the home router) + gost front proxy
# + home-proxy-check (fallback to direct, Discord alerts).
# Run by Terraform (null_resource, see main.tf) after setup-hermes.sh; re-runs
# only when this script or its own env file (/root/.deploy-staging/hermes-home-vpn.env) changes.

set -a
source /root/.deploy-staging/hermes-home-vpn.env
set +a
rm -f /root/.deploy-staging/hermes-home-vpn.env

HOME_VPN_ENABLED=false
if [ -n "${HOME_VPN_CLIENT_PRIVATE_KEY:-}" ] && [ -n "${HOME_VPN_SERVER_PUBLIC_KEY:-}" ] && [ -n "${HOME_VPN_ENDPOINT:-}" ]; then
  HOME_VPN_ENABLED=true
fi

# Home VPN egress: wireproxy is a userspace WireGuard client that exposes the
# tunnel to the home router as SOCKS5 on 127.0.0.1:11080 and HTTP on :11081;
# a gost front proxy re-exposes them on :1080/:1081 and falls back to direct
# when the tunnel is down (home-proxy-check).
# No kernel interface, no routes, so SSH/email/R2 backups keep going out
# directly from Hetzner. What is pointed at the proxy exits via the home IP:
# Camofox (home_vpn_camofox), SearXNG and the gateway's web traffic
# (home_vpn_web, NO_PROXY keeps Ollama/Discord/GitHub/Google APIs direct).
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
GOST_VERSION="v3.3.3"
GOST_SHA256="f4c1255dc892a7014c0ad6e5f1c3573108f7bea4403f04f21873406ab58aa666"
WIREPROXY_ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/3, 96.0.0.0/6, 100.0.0.0/10, 100.128.0.0/9, 101.0.0.0/8, 102.0.0.0/7, 104.0.0.0/5, 112.0.0.0/5, 120.0.0.0/6, 124.0.0.0/7, 126.0.0.0/8, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/8, 169.0.0.0/9, 169.128.0.0/10, 169.192.0.0/11, 169.224.0.0/12, 169.240.0.0/13, 169.248.0.0/14, 169.252.0.0/15, 169.255.0.0/16, 170.0.0.0/7, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.1.0/24, 192.0.2.0/23, 192.0.4.0/22, 192.0.8.0/21, 192.0.16.0/20, 192.0.32.0/19, 192.0.64.0/18, 192.0.128.0/17, 192.1.0.0/16, 192.2.0.0/15, 192.4.0.0/14, 192.8.0.0/13, 192.16.0.0/12, 192.32.0.0/11, 192.64.0.0/10, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/7, 198.0.0.0/12, 198.16.0.0/15, 198.20.0.0/14, 198.24.0.0/13, 198.32.0.0/11, 198.64.0.0/10, 198.128.0.0/9, 199.0.0.0/8, 200.0.0.0/5, 208.0.0.0/4"
if [ "$HOME_VPN_ENABLED" = true ]; then
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
BindAddress = 127.0.0.1:11080

# HTTP CONNECT proxy for the gateway's HTTP(S)_PROXY (every client speaks it;
# SOCKS would need extra Python packages).
[http]
BindAddress = 127.0.0.1:11081
WPEOF
  umask 022
  /usr/local/bin/wireproxy --configtest --config /etc/wireproxy/home.conf

  # Sandboxed: no root, no writable filesystem, no capabilities. The config
  # (root-only, holds the private key) is handed over as a systemd credential;
  # %d is the credentials directory.
  cat > /etc/systemd/system/wireproxy-home.service <<'UNITEOF'
[Unit]
Description=wireproxy: SOCKS5 :11080 / HTTP :11081 via home router WireGuard
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

  # Front proxy on the ports everything uses (127.0.0.1:1080 SOCKS5, :1081
  # HTTP). Mode "tunnel" forwards to wireproxy; mode "direct" goes straight
  # out from Hetzner. home-proxy-check flips the mode, so a dead home tunnel
  # degrades to datacenter-IP browsing instead of breaking the browser and
  # web tools (3 silent days after the 2026-11-23 router reset).
  if ! /usr/local/bin/gost -V 2>/dev/null | grep -q "^gost ${GOST_VERSION#v} "; then
    echo "Installing gost $GOST_VERSION..."
    TMP_G=$(mktemp -d)
    curl -fsSL -o "$TMP_G/g.tgz" "https://github.com/go-gost/gost/releases/download/$GOST_VERSION/gost_${GOST_VERSION#v}_linux_amd64.tar.gz"
    echo "$GOST_SHA256  $TMP_G/g.tgz" | sha256sum -c --quiet
    tar -xzf "$TMP_G/g.tgz" -C "$TMP_G" gost
    install -m 0755 "$TMP_G/gost" /usr/local/bin/gost
    rm -rf "$TMP_G"
  fi
  install -d -m 0755 /var/lib/home-proxy
  [ -f /var/lib/home-proxy/mode ] || echo tunnel > /var/lib/home-proxy/mode
  cat > /etc/systemd/system/home-proxy-front.service <<'UNITEOF'
[Unit]
Description=Home proxy front (127.0.0.1:1080 SOCKS5, :1081 HTTP): via home tunnel or direct
After=network-online.target wireproxy-home.service
Wants=network-online.target

[Service]
ExecStart=/bin/sh -c 'if [ "$(cat /var/lib/home-proxy/mode 2>/dev/null)" = direct ]; then exec /usr/local/bin/gost -L socks5://127.0.0.1:1080 -L http://127.0.0.1:1081; else exec /usr/local/bin/gost -L socks5://127.0.0.1:1080 -L http://127.0.0.1:1081 -F socks5://127.0.0.1:11080; fi'
Restart=always
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryMax=128M

[Install]
WantedBy=multi-user.target
UNITEOF

  # Discord DM for the alerts: Claudiano's bot to the first allowed user.
  install -d -m 0700 /etc/home-proxy
  umask 077
  cat > /etc/home-proxy/notify.env <<NEOF
DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN
DISCORD_USER_ID=${DISCORD_ALLOWED_USERS%%,*}
NEOF
  umask 022

  # Every minute: probe the tunnel directly (wireproxy's own ports). Down 2
  # checks in a row -> front goes direct; up again -> back to tunnel.
  # wireproxy resolves the asuscomm.com endpoint only at start, so after the
  # nightly home IP change (PPPoE reconnect, 04:00) it needs a restart: on the
  # first failure and every 5th after. Down 15 min -> one Discord DM; another
  # when it recovers.
  cat > /usr/local/sbin/home-proxy-check <<'CHKEOF'
#!/bin/sh
S=/var/lib/home-proxy
mode=$(cat $S/mode 2>/dev/null || echo tunnel)
fails=$(cat $S/fails 2>/dev/null || echo 0)

notify() {
  [ -r /etc/home-proxy/notify.env ] || return 0
  . /etc/home-proxy/notify.env
  [ -n "$DISCORD_BOT_TOKEN" ] && [ -n "$DISCORD_USER_ID" ] || return 0
  ch=$(curl -sf --max-time 15 -X POST -H "Authorization: Bot $DISCORD_BOT_TOKEN" -H "Content-Type: application/json" \
    -d "{\"recipient_id\":\"$DISCORD_USER_ID\"}" https://discord.com/api/v10/users/@me/channels |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || { echo "notify: no DM channel"; return 1; }
  msg=$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))')
  curl -sf --max-time 15 -o /dev/null -X POST -H "Authorization: Bot $DISCORD_BOT_TOKEN" -H "Content-Type: application/json" \
    -d "$msg" "https://discord.com/api/v10/channels/$ch/messages" || { echo "notify: send failed"; return 1; }
}
set_mode() {
  echo "$1" > $S/mode
  systemctl restart home-proxy-front
  echo "front proxy -> $1"
}

if curl -sf --max-time 10 --socks5-hostname 127.0.0.1:11080 -o /dev/null https://1.1.1.1/cdn-cgi/trace &&
   curl -sf --max-time 10 --proxy http://127.0.0.1:11081 -o /dev/null https://1.1.1.1/cdn-cgi/trace; then
  [ "$mode" = tunnel ] || set_mode tunnel
  if [ -f $S/down_since ]; then
    mins=$(( ($(date +%s) - $(cat $S/down_since)) / 60 ))
    [ -f $S/alerted ] && notify "✅ Home VPN is back after ${mins} min. Browser and web traffic go via the home IP again."
    rm -f $S/down_since $S/alerted
  fi
  echo 0 > $S/fails
  exit 0
fi

fails=$((fails + 1)); echo $fails > $S/fails
[ -f $S/down_since ] || date +%s > $S/down_since
echo "home tunnel down (check $fails)"
[ "$fails" -ge 2 ] && [ "$mode" = tunnel ] && set_mode direct
if [ "$fails" -eq 1 ] || [ $((fails % 5)) -eq 0 ]; then systemctl restart wireproxy-home; fi
since=$(cat $S/down_since)
if [ ! -f $S/alerted ] && [ $(( $(date +%s) - since )) -ge 900 ]; then
  notify "⚠️ Home VPN down since $(date -d @$since '+%H:%M %Z'). Browser and web traffic fall back to the Hetzner IP (Blind/Glassdoor won't work). Router: WireGuard server + DDNS on? See casa runbook." && touch $S/alerted
fi
exit 0
CHKEOF
  chmod 0755 /usr/local/sbin/home-proxy-check
  cat > /etc/systemd/system/home-proxy-check.service <<'UNITEOF'
[Unit]
Description=Home tunnel health: switch the front proxy tunnel/direct, alert on Discord

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/home-proxy-check
UNITEOF
  cat > /etc/systemd/system/home-proxy-check.timer <<'UNITEOF'
[Unit]
Description=Check the home tunnel every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNITEOF

  # Migration from the 5-min restart-only check.
  if [ -f /etc/systemd/system/wireproxy-home-check.timer ]; then
    systemctl disable --now wireproxy-home-check.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wireproxy-home-check.service /etc/systemd/system/wireproxy-home-check.timer
  fi
  systemctl daemon-reload
  systemctl enable wireproxy-home home-proxy-front home-proxy-check.timer >/dev/null 2>&1
  systemctl restart wireproxy-home
  systemctl restart home-proxy-front
  systemctl start home-proxy-check.timer
else
  # Disabled: tear down any previous install so nothing listens on 1080/1081.
  for u in home-proxy-check.timer home-proxy-front wireproxy-home wireproxy-home-check.timer; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  rm -f /etc/systemd/system/wireproxy-home.service /etc/systemd/system/wireproxy-home-check.service /etc/systemd/system/wireproxy-home-check.timer \
    /etc/systemd/system/home-proxy-front.service /etc/systemd/system/home-proxy-check.service /etc/systemd/system/home-proxy-check.timer \
    /usr/local/sbin/home-proxy-check
  systemctl daemon-reload
  rm -rf /etc/wireproxy /etc/home-proxy /var/lib/home-proxy
fi

