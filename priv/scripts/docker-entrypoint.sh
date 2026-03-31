#!/bin/sh
# ---------------------------------------------------------------------------
# docker-entrypoint.sh — App container entrypoint
# ---------------------------------------------------------------------------
# Reads the IOTA secret key from the wallet-generated file if the
# IOTA_SECRET_KEY environment variable is not already set (e.g. via .env).
# This allows the wallet init container to auto-provision keys while still
# letting manual .env configuration take precedence.
# ---------------------------------------------------------------------------

WALLET_KEY_FILE="/wallet/private_key.txt"

if [ -n "$IOTA_SECRET_KEY" ]; then
  echo "[entrypoint] IOTA_SECRET_KEY set via environment — using env value"

elif [ -f "$WALLET_KEY_FILE" ] && [ -r "$WALLET_KEY_FILE" ]; then
  IOTA_SECRET_KEY=$(cat "$WALLET_KEY_FILE")

  if [ -n "$IOTA_SECRET_KEY" ]; then
    export IOTA_SECRET_KEY
    echo "[entrypoint] IOTA_SECRET_KEY loaded from wallet volume ($WALLET_KEY_FILE)"
  else
    echo "[entrypoint] WARNING: $WALLET_KEY_FILE exists but is empty"
  fi

else
  echo "[entrypoint] WARNING: IOTA_SECRET_KEY not set and $WALLET_KEY_FILE not found"
  echo "[entrypoint] On-chain operations (DID publishing, notarization) will not work"
fi

exec bin/tangle_gate start
