#!/usr/bin/env bash
# Builds the leaky image and exports the player-facing artifact.
# Players receive only dist/internal-deployer.tar - never build/, which holds
# the flag in plaintext.
set -euo pipefail
cd "$(dirname "$0")"

[ -f build/deploy-creds.env ] || {
  echo "!! build/deploy-creds.env missing - run: mise run render" >&2
  exit 1
}

mkdir -p dist
docker build -q -f artifact.Dockerfile -t internal-deployer:challenge . >/dev/null
docker save internal-deployer:challenge -o dist/internal-deployer.tar
echo "    dist/internal-deployer.tar ($(du -h dist/internal-deployer.tar | cut -f1))"
