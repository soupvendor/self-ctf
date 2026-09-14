#!/usr/bin/env bash
# Runs every challenge's LocalStack seed once the API is up. Sequential and
# fail-fast: one broken seed marks the whole init as failed, which seeds-ready
# turns into an unhealthy container rather than a puzzle with no answer in it.
set -euo pipefail
shopt -s nullglob

scripts=(/opt/self-ctf/seeds/*/seed/localstack/*.sh)
[ ${#scripts[@]} -gt 0 ] || {
  echo "!! no challenge seeds were baked into this image" >&2
  exit 1
}

for script in "${scripts[@]}"; do
  challenge="${script#/opt/self-ctf/seeds/}"
  echo "==> seeding ${challenge%%/*}"
  bash "$script"
done
echo "==> all seeds complete"
