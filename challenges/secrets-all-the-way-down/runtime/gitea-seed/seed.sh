#!/usr/bin/env bash
# Seeds Gitea from runtime values so the image stays reusable and flag-free.
set -euo pipefail

: "${GITEA_INTERNAL_URL:?}" "${REPO_NAME:?}"
: "${GITEA_ADMIN_NAME:?}" "${GITEA_ADMIN_PASSWORD:?}" "${GITEA_ADMIN_EMAIL:?}"
: "${CI_USER:?}" "${CI_PASS:?}" "${FLAG_PIPELINE:?}" "${LOCALSTACK_PORT:?}"

mkdir -p "${TMPDIR:-/tmp}"

HOME="$(mktemp -d)"
export HOME

user_exists() {
  gitea admin user list | awk 'NR > 1 { print $2 }' | grep -qx "$1"
}

ensure_user() {
  local username=$1 password=$2 email=$3
  shift 3
  if user_exists "$username"; then
    gitea admin user change-password --username "$username" --password "$password" \
      --must-change-password=false
    return
  fi
  gitea admin user create --username "$username" --password "$password" \
    --email "$email" --must-change-password=false "$@"
}

echo "==> Creating accounts"
ensure_user "$GITEA_ADMIN_NAME" "$GITEA_ADMIN_PASSWORD" "$GITEA_ADMIN_EMAIL" --admin
ensure_user "$CI_USER" "$CI_PASS" "$CI_USER@internal.local"

echo "==> Pushing $CI_USER/$REPO_NAME"
host="${GITEA_INTERNAL_URL#*://}"
host="${host%%[:/]*}"
printf 'machine %s\nlogin %s\npassword %s\n' "$host" "$CI_USER" "$CI_PASS" >"$HOME/.netrc"
chmod 600 "$HOME/.netrc"

work="$(mktemp -d)"
cp -a /opt/self-ctf/repo/. "$work/"

workflow_template="$work/.gitea/workflows/deploy.yml.template"
workflow="$(<"$workflow_template")"
[[ "$workflow" == *"__FLAG_PIPELINE__"* ]] || {
  echo "!! pipeline flag placeholder is missing" >&2
  exit 1
}
[[ "$workflow" == *"__LOCALSTACK_PORT__"* ]] || {
  echo "!! LocalStack port placeholder is missing" >&2
  exit 1
}
workflow="${workflow//__FLAG_PIPELINE__/$FLAG_PIPELINE}"
workflow="${workflow//__LOCALSTACK_PORT__/$LOCALSTACK_PORT}"
printf '%s\n' "$workflow" >"${workflow_template%.template}"
rm "$workflow_template"

cd "$work"
git init -q -b main
git add -A
git -c user.email="$CI_USER@internal.local" -c user.name="$CI_USER" \
  commit -q -m "initial deploy automation"
git push -q --force "$GITEA_INTERNAL_URL/$CI_USER/$REPO_NAME.git" main

echo "==> Seed complete"
