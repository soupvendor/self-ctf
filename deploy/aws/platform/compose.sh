#!/usr/bin/env bash
set -euo pipefail
: "${SELF_CTF_CONFIG_DIR:?}"
: "${SELF_CTF_RUN_DIR:?}"
: "${SELF_CTF_PROJECT_NAME:?}"
exec docker compose --project-name "$SELF_CTF_PROJECT_NAME" \
  --env-file "$SELF_CTF_CONFIG_DIR/images.env" --env-file "$SELF_CTF_RUN_DIR/platform.env" \
  -f "$SELF_CTF_CONFIG_DIR/compose.yaml" -f "$SELF_CTF_CONFIG_DIR/compose.aws.yaml" "$@"
