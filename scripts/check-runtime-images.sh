#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "!! pass at least one runtime image to inspect" >&2
  exit 1
fi

archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
docker image save --output "$archive" "$@"

mapfile -t sensitive_vars < <(compgen -A variable | grep '^FLAG_')
sensitive_vars+=(
  CTFD_ADMIN_PASSWORD
  CTFD_DB_PASSWORD
  CTFD_SECRET_KEY
  GITEA_ADMIN_PASSWORD
  DEPLOY_PASSWORD
)

for variable in "${sensitive_vars[@]}"; do
  value="${!variable-}"
  [ -n "$value" ] || continue
  if grep -aFq -- "$value" "$archive"; then
    echo "!! runtime image contains the configured value of $variable" >&2
    exit 1
  fi
done

echo "Runtime image leak check passed ($# image(s))."
