#!/bin/bash
# =============================================================================
# Backend container runtime configuration
# =============================================================================
# Runs once at boot (before agent/ttyd services) to inject Docker
# environment variables into systemd service config files and set up
# the session user account.
# =============================================================================

set -e

# Source Docker environment variables saved by entrypoint.sh.
# systemd replaces the process environment so Docker env vars are not
# available to systemd services directly.
DOCKER_ENV="/run/docker-env"
if [ -f "$DOCKER_ENV" ]; then
  while IFS= read -r line; do
    # Skip empty lines and comments
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    export "$line"
  done < "$DOCKER_ENV"
fi

ENV_FILE="/etc/tangle_gate_agent/env"
mkdir -p /etc/tangle_gate_agent

# --- Inject Docker env vars into the agent environment file ---
cat > "$ENV_FILE" << EOF
TANGLE_GATE_WS_URL=${TANGLE_GATE_WS_URL:-ws://app:4000/ws/agent}
AGENT_API_KEY=${AGENT_API_KEY:-dev-agent-key}
IOTA_NODE_URL=${IOTA_NODE_URL:-https://api.testnet.iota.cafe}
IOTA_IDENTITY_PKG_ID=${IOTA_IDENTITY_PKG_ID:-}
PORT=${AGENT_PORT:-8800}
HOME=/opt/tangle_gate_agent
EOF

chmod 600 "$ENV_FILE"
chown agent:agent "$ENV_FILE"

# --- Set session user password from env if provided ---
if [ -n "$SESSION_USER_PASSWORD" ]; then
  echo "sessionuser:$SESSION_USER_PASSWORD" | chpasswd
fi

# --- Ensure session directories exist with correct permissions ---
mkdir -p /data/sessions/pending
chmod 777 /data/sessions /data/sessions/pending

# --- Ensure SSH host keys exist ---
ssh-keygen -A 2>/dev/null || true

echo "[configure.sh] Backend configuration complete"
