#!/usr/bin/env bash
set -euo pipefail

: "${DATA_DEVICE:?}"
: "${INITIALIZE_NEW_VOLUME:?}"

[[ -b "$DATA_DEVICE" ]] || {
  echo "Data volume is missing: $DATA_DEVICE" >&2
  exit 1
}
signature="$(wipefs --no-act --noheadings --output TYPE "$DATA_DEVICE")"
if [[ -z "$signature" ]]; then
  [[ "$INITIALIZE_NEW_VOLUME" == "true" ]] || {
    echo "Refusing to format an empty restore volume." >&2
    exit 1
  }
  mkfs.ext4 -L self-ctf-data "$DATA_DEVICE"
else
  [[ "$(blkid -s TYPE -o value "$DATA_DEVICE")" == "ext4" ]] || {
    echo "Refusing an unexpected filesystem or partitioned volume." >&2
    exit 1
  }
  [[ "$(blkid -s LABEL -o value "$DATA_DEVICE")" == "self-ctf-data" ]] || {
    echo "Refusing a volume without the self-ctf-data label." >&2
    exit 1
  }
fi
