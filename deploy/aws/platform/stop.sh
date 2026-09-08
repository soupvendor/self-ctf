#!/usr/bin/env bash
set -euo pipefail
: "${SELF_CTF_LIB_DIR:?}"
: "${PLATFORM_DATA_DIR:?}"
"$SELF_CTF_LIB_DIR/compose.sh" stop --timeout 60
for service in ctfd db cache; do
  container_id="$("$SELF_CTF_LIB_DIR/compose.sh" ps --all --quiet "$service")"
  [[ -n "$container_id" ]] || {
    echo "$service container is missing." >&2
    exit 1
  }
  [[ "$(docker inspect --format '{{.State.ExitCode}}' "$container_id")" == "0" ]] || {
    echo "$service did not stop cleanly; do not snapshot this state." >&2
    exit 1
  }
done
sync -f "$PLATFORM_DATA_DIR"
