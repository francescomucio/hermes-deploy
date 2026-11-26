#!/bin/bash
set -euo pipefail

# dario router container (optional, DARIO_API_KEY).
# Run by Terraform (null_resource, see main.tf) after setup-hermes.sh; re-runs
# only when this script or its own env file (/tmp/hermes-dario.env) changes.

set -a
source /tmp/hermes-dario.env
set +a
rm -f /tmp/hermes-dario.env

# dario: local OpenAI/Anthropic-compatible router for non-Claude backends
# (ChatGPT subscription via `dario add altman`, API-key backends via
# `dario backend add`). Opt-in: only installed when DARIO_API_KEY is set.
# Own standalone container like Camofox; gateway reaches it over the host
# network at 127.0.0.1:3456 (DARIO_URL), loopback only.
#
# --no-claude-auth: the Claude OAuth pool is never loaded, so claude-* models
# return an auth error — routing a Claude subscription through a third-party
# proxy is against Anthropic's terms. Never run `dario login` here.
#
# Accounts/backends live in /opt/dario-data, outside /root/.hermes on
# purpose: that tree is mounted into the agents' container, and they must
# not be able to read the OAuth tokens. Not backed up to R2 — re-add the
# accounts after a fresh deploy (see README "dario").
DARIO_IMAGE="ghcr.io/askalf/dario:v6.12.25"
# Bump when the `docker run` flags/env below change (see CAMOFOX_RUN_REV).
DARIO_RUN_REV="1"
if [ -n "${DARIO_API_KEY:-}" ]; then
  mkdir -p /opt/dario-data
  if docker ps -a --format '{{.Names}}' | grep -qx dario; then
    NEEDS_RECREATE=false
    [ "$(docker inspect dario --format '{{.Config.Image}}')" = "$DARIO_IMAGE" ] || NEEDS_RECREATE=true
    [ "$(docker inspect dario --format '{{index .Config.Labels "hermes.dario.run-rev"}}')" = "$DARIO_RUN_REV" ] || NEEDS_RECREATE=true
    CURRENT_DARIO_KEY=$(docker inspect dario --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^DARIO_API_KEY=//p')
    [ "$CURRENT_DARIO_KEY" = "$DARIO_API_KEY" ] || NEEDS_RECREATE=true
    if [ "$NEEDS_RECREATE" = true ]; then
      echo "dario container outdated (image/flags/API key), recreating..."
      docker rm -f dario
    fi
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx dario; then
    docker start dario >/dev/null 2>&1 || true
  else
    # DARIO_HOST=127.0.0.1: the image binds 0.0.0.0 by default; with host
    # networking that would be every interface (Hetzner firewall aside).
    # DARIO_NO_LIVE_CAPTURE=1: the Claude Code template capture is pointless
    # without Claude auth. Docker reports the container "unhealthy" until a
    # ChatGPT account is added, and stays so with API-key backends only
    # (/health only counts Codex accounts under --no-claude-auth). Harmless:
    # plain `docker run` never restarts on health; check /livez instead.
    docker run -d --restart unless-stopped --name dario \
      --network host \
      --memory=256m --memory-swap=512m \
      --label hermes.dario.run-rev="$DARIO_RUN_REV" \
      -v /opt/dario-data:/home/dario/.dario \
      -e DARIO_HOST=127.0.0.1 \
      -e DARIO_PORT=3456 \
      -e DARIO_API_KEY="$DARIO_API_KEY" \
      -e DARIO_NO_LIVE_CAPTURE=1 \
      "$DARIO_IMAGE" proxy --no-claude-auth
  fi
elif docker ps -a --format '{{.Names}}' | grep -qx dario; then
  echo "DARIO_API_KEY unset, removing dario container (accounts kept in /opt/dario-data)..."
  docker rm -f dario
fi

