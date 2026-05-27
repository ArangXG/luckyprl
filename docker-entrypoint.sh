#!/usr/bin/env bash
set -e

ALGO="${ALGO:-pearl}"
POOL="${POOL:-stratum+tcp://pearl-eu1.luckypool.io:3360}"
WALLET="${WALLET:-prl1pvxfasasdasda.worker}"

echo "========================================="
echo " lpminer v0.1.7"
echo " Pool   : $POOL"
echo " Wallet : $WALLET"
echo "========================================="

exec ./lpminer \
  --algo "$ALGO" \
  --pool "$POOL" \
  --wallet "$WALLET"
