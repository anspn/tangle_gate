#!/bin/sh

set -e

WALLET_DIR="/wallet"
KEYSTORE_DIR="/root/.iota"

ADDRESS_FILE="$WALLET_DIR/address.txt"
PRIVKEY_FILE="$WALLET_DIR/private_key.txt"

MIN_BALANCE=100000

mkdir -p "$WALLET_DIR"

echo "Bootstrapping IOTA wallet..."


# --------------------------------------------------
# 0. Fast path: if both output files exist, skip everything
# --------------------------------------------------

if [ -f "$ADDRESS_FILE" ] && [ -f "$PRIVKEY_FILE" ]; then

  ADDRESS=$(cat "$ADDRESS_FILE")

  echo "Wallet already initialized"
  echo "Address: $ADDRESS"
  echo "Private key: $PRIVKEY_FILE (exists)"

  # Still check gas and request faucet if needed
  echo "Checking gas coins..."
  GAS_JSON=$(iota client gas --json)
  COIN_COUNT=$(echo "$GAS_JSON" | jq length)
  LOW_BALANCE=false

  if [ "$COIN_COUNT" -eq 0 ]; then
    LOW_BALANCE=true
  else
    # Use jq to check if any coin is below threshold (avoids subshell scoping)
    LOW_COUNT=$(echo "$GAS_JSON" | jq "[.[] | select(.nanosBalance < $MIN_BALANCE)] | length")
    if [ "$LOW_COUNT" -gt 0 ]; then
      LOW_BALANCE=true
    fi
  fi

  if [ "$LOW_BALANCE" = true ]; then
    echo "Balance below threshold. Requesting faucet tokens..."
    iota client faucet
    echo "Faucet request sent"
  else
    echo "Gas balance sufficient"
  fi

  echo ""
  echo "Wallet ready"
  exit 0

fi


# --------------------------------------------------
# 1. Generate address if not existing
# --------------------------------------------------

if [ ! -f "$ADDRESS_FILE" ]; then

  echo "Generating new address..."

  ADDRESS=$(printf "testnet\ned25519\n" | iota client new-address \
      | grep -oE "0x[a-fA-F0-9]+" \
      | head -n1)

  echo "$ADDRESS" > "$ADDRESS_FILE"

  echo "Address generated: $ADDRESS"

else

  ADDRESS=$(cat "$ADDRESS_FILE")

  echo "Using existing address: $ADDRESS"

fi


# --------------------------------------------------
# 2. Check current gas balances
# --------------------------------------------------

echo "Checking gas coins..."

GAS_JSON=$(iota client gas --json)

LOW_BALANCE=false

COIN_COUNT=$(echo "$GAS_JSON" | jq length)

if [ "$COIN_COUNT" -eq 0 ]; then
  echo "No gas coins found"
  LOW_BALANCE=true
else
  # Use jq to check balances (avoids subshell variable scoping issues with pipe)
  echo "$GAS_JSON" | jq -r '.[] | "Coin \(.gasCoinId) balance: \(.nanosBalance)"'

  LOW_COUNT=$(echo "$GAS_JSON" | jq "[.[] | select(.nanosBalance < $MIN_BALANCE)] | length")
  if [ "$LOW_COUNT" -gt 0 ]; then
    LOW_BALANCE=true
  fi
fi


# --------------------------------------------------
# 3. Request faucet tokens if needed
# --------------------------------------------------

if [ "$LOW_BALANCE" = true ]; then

  echo "Balance below threshold. Requesting faucet tokens..."

  iota client faucet

  echo "Faucet request sent"

else

  echo "Gas balance sufficient. Faucet request skipped"

fi


# --------------------------------------------------
# 4. Export private key
# --------------------------------------------------

echo "Exporting private key..."

PRIV_KEY=$(iota keytool export "$ADDRESS" --json | jq -r .exportedPrivateKey)

echo "$PRIV_KEY" > "$PRIVKEY_FILE"

echo "Private key saved to $PRIVKEY_FILE"


# --------------------------------------------------
# 5. Summary
# --------------------------------------------------

echo ""
echo "Wallet ready"
echo "Address: $ADDRESS"
echo "Private key written to shared volume"
echo ""

exit 0
