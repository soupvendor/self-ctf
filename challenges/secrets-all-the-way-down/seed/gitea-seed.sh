#!/usr/bin/env bash
# Seeds Gitea with the account players recover in stage 1 and the repository
# that leaks stage 3's credentials.
#
# Runs as a one-shot service on every `up`. The push is forced so a restarted or
# tampered-with stack converges back to the same content - replacing a broken
# team stack is the recovery plan, so seeding cannot be a step someone runs by
# hand.
set -euo pipefail

: "${GITEA_INTERNAL_URL:?}" "${REPO_NAME:?}"
: "${GITEA_ADMIN_NAME:?}" "${GITEA_ADMIN_PASSWORD:?}" "${GITEA_ADMIN_EMAIL:?}"
# From seed/deploy-creds.env, the same file baked into the stage 1 image.
: "${CI_USER:?}" "${CI_PASS:?}"

# The image points TMPDIR at a directory its own entrypoint creates, which this
# container never runs.
mkdir -p "${TMPDIR:-/tmp}"

HOME="$(mktemp -d)"
export HOME

user_exists() {
  gitea admin user list | awk 'NR > 1 { print $2 }' | grep -qx "$1"
}

create_user() {
  local username=$1 password=$2 email=$3
  shift 3
  if user_exists "$username"; then
    echo "    $username already exists"
    return
  fi
  gitea admin user create --username "$username" --password "$password" \
    --email "$email" --must-change-password=false "$@"
}

echo "==> Creating accounts"
# The admin has to exist first: Gitea makes the very first user an
# administrator, and the account players log in with must not be one.
create_user "$GITEA_ADMIN_NAME" "$GITEA_ADMIN_PASSWORD" "$GITEA_ADMIN_EMAIL" --admin
create_user "$CI_USER" "$CI_PASS" "$CI_USER@internal.local"

echo "==> Pushing $CI_USER/$REPO_NAME"
host="${GITEA_INTERNAL_URL#*://}"
host="${host%%[:/]*}"
printf 'machine %s\nlogin %s\npassword %s\n' "$host" "$CI_USER" "$CI_PASS" >"$HOME/.netrc"
chmod 600 "$HOME/.netrc"

work="$(mktemp -d)"
cp -a /seed/repo/. "$work/"
# The rendered file is what ships; its template would sit next to it in the
# repo showing players a ${FLAG_...} placeholder.
find "$work" -name '*.tmpl' -delete

cd "$work"
git init -q -b main
git add -A
git -c user.email="$CI_USER@internal.local" -c user.name="$CI_USER" \
  commit -q -m "initial deploy automation"
git push -q --force "$GITEA_INTERNAL_URL/$CI_USER/$REPO_NAME.git" main

echo "==> Seed complete"
