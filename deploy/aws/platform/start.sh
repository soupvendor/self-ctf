#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${AWS_REGION:?}"
: "${PLATFORM_SECRET_ARN:?}"
: "${ECR_REGISTRY:?}"
: "${CTFD_IMAGE:?}"
: "${DOCKER_CONFIG:?}"
: "${SELF_CTF_RUN_DIR:?}"
: "${SELF_CTF_LIB_DIR:?}"
: "${PLATFORM_DATA_DIR:?}"

mountpoint --quiet "$PLATFORM_DATA_DIR"
for volume in ctfd-logs ctfd-uploads ctfd-db ctfd-cache; do
  mkdir -p "$PLATFORM_DATA_DIR/$volume"
done
mkdir -p "$DOCKER_CONFIG"
version_file="$PLATFORM_DATA_DIR/platform-secret-version"
if [[ -f "$version_file" ]]; then
  mapfile -t secret_metadata <"$version_file"
  [[ ${#secret_metadata[@]} == 2 && "${secret_metadata[0]}" == "$PLATFORM_SECRET_ARN" ]] || {
    echo "Restored platform secret does not match this host configuration." >&2
    exit 1
  }
  secret_version="${secret_metadata[1]}"
else
  secret_version="$(aws secretsmanager get-secret-value --secret-id "$PLATFORM_SECRET_ARN" \
    --query VersionId --output text)"
fi
[[ "$secret_version" =~ ^[a-zA-Z0-9-]{32,64}$ ]] || {
  echo "Invalid secret version." >&2
  exit 1
}
aws secretsmanager get-secret-value --secret-id "$PLATFORM_SECRET_ARN" \
  --version-id "$secret_version" --query SecretString --output text >"$SELF_CTF_RUN_DIR/platform.env"

declare -A seen=()
while IFS='=' read -r key value; do
  [[ -n "$key$value" ]] || continue
  case "$key" in
    CTFD_DB_PASSWORD | CTFD_SECRET_KEY) ;;
    *)
      echo "Unexpected key in platform secret." >&2
      exit 1
      ;;
  esac
  [[ "$value" =~ ^[a-f0-9]{64}$ && -z "${seen[$key]:-}" ]] || {
    echo "Platform secrets must be unique keys with 64-character lowercase hex values." >&2
    exit 1
  }
  seen["$key"]=1
done <"$SELF_CTF_RUN_DIR/platform.env"
[[ ${#seen[@]} == 2 ]] || {
  echo "Platform secret is incomplete." >&2
  exit 1
}
printf '%s\n%s\n' "$PLATFORM_SECRET_ARN" "$secret_version" >"$version_file.new"
mv "$version_file.new" "$version_file"

aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_REGISTRY"
"$SELF_CTF_LIB_DIR/compose.sh" pull --policy missing
docker run --rm -i --network none --entrypoint python "$CTFD_IMAGE" - \
  <"$SELF_CTF_LIB_DIR/configure_ctfd.py" >"$SELF_CTF_RUN_DIR/ctfd.ini"
chmod 644 "$SELF_CTF_RUN_DIR/ctfd.ini"
"$SELF_CTF_LIB_DIR/compose.sh" up -d --wait --wait-timeout 240
