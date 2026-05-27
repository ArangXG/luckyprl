#!/usr/bin/env bash
set -e

ALGO="${ALGO:-pearl}"
POOL="${POOL:-stratum+tcp://pearl-eu1.luckypool.io:3360}"
WALLET="${WALLET:-prl1pvxf2ljgw6xw32fzwjftt660m7jny6hl2lp7n5c3dq6w5a8maekpqwjpge8.sph100x1}"

echo "========================================="
echo " lpminer v0.1.7"
echo " Pool   : $POOL"
echo " Wallet : $WALLET"
echo "========================================="

exec ./lpminer \
  --algo "$ALGO" \
  --pool "$POOL" \
  --wallet "$WALLET"
