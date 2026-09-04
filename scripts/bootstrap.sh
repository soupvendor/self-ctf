#!/usr/bin/env bash
# Drive CTFd's first-run setup wizard headlessly and mint an API token for
# ctfcli. CTFd has no headless setup path, so this posts the same form a human
# would - which couples it to the CTFd version pinned in compose.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CTFD_URL:?set CTFD_URL in .env}"
: "${CTFD_NAME:?set CTFD_NAME in .env}"
: "${CTFD_ADMIN_NAME:?set CTFD_ADMIN_NAME in .env}"
: "${CTFD_ADMIN_EMAIL:?set CTFD_ADMIN_EMAIL in .env}"
: "${CTFD_ADMIN_PASSWORD:?set CTFD_ADMIN_PASSWORD in .env}"

JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

echo "==> Waiting for CTFd at $CTFD_URL"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "$CTFD_URL/setup" 2>/dev/null; then break; fi
  [ "$i" = "60" ] && {
    echo "!! CTFd never answered"
    exit 1
  }
  sleep 2
done

# /setup 302s to / once setup has completed.
setup_code="$(curl -s -o /dev/null -w '%{http_code}' "$CTFD_URL/setup")"

if [ "$setup_code" = "200" ]; then
  echo "==> Running first-time setup"
  nonce="$(curl -s -c "$JAR" "$CTFD_URL/setup" \
    | grep -oE 'name="nonce"[^>]*value="[^"]+"' \
    | grep -oE 'value="[^"]+"' | cut -d'"' -f2 | head -1)"
  [ -n "$nonce" ] || {
    echo "!! Could not read setup nonce"
    exit 1
  }

  curl -fsS -b "$JAR" -c "$JAR" -o /dev/null "$CTFD_URL/setup" \
    -F "nonce=$nonce" \
    -F "ctf_name=$CTFD_NAME" \
    -F "ctf_description=Self-hosted CTF" \
    -F "user_mode=teams" \
    -F "challenge_visibility=private" \
    -F "account_visibility=private" \
    -F "score_visibility=private" \
    -F "registration_visibility=public" \
    -F "verify_emails=false" \
    -F "social_shares=false" \
    -F "ctf_theme=core-beta" \
    -F "name=$CTFD_ADMIN_NAME" \
    -F "email=$CTFD_ADMIN_EMAIL" \
    -F "password=$CTFD_ADMIN_PASSWORD" \
    -F "_submit=Finish"
  echo "    Admin '$CTFD_ADMIN_NAME' created."
else
  echo "==> Already set up (/setup returned $setup_code), logging in"
  nonce="$(curl -s -c "$JAR" "$CTFD_URL/login" \
    | grep -oE 'name="nonce"[^>]*value="[^"]+"' \
    | grep -oE 'value="[^"]+"' | cut -d'"' -f2 | head -1)"
  curl -fsS -b "$JAR" -c "$JAR" -o /dev/null "$CTFD_URL/login" \
    -F "nonce=$nonce" -F "name=$CTFD_ADMIN_NAME" -F "password=$CTFD_ADMIN_PASSWORD"
fi

# CTFd only honours an Authorization header when the request is JSON, so any
# API call made with this token must send Content-Type: application/json.
echo "==> Minting an API token"
csrf="$(curl -s -b "$JAR" -c "$JAR" "$CTFD_URL/settings" \
  | grep -oE "'csrfNonce':[[:space:]]*\"[^\"]+\"" \
  | grep -oE '"[^"]+"$' | tr -d '"')"
[ -n "$csrf" ] || {
  echo "!! Could not read csrfNonce - is the admin session valid?"
  exit 1
}

token="$(curl -fsS -b "$JAR" -X POST "$CTFD_URL/api/v1/tokens" \
  -H "Content-Type: application/json" \
  -H "CSRF-Token: $csrf" \
  -d '{"description":"ctfcli (self-ctf bootstrap)"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["value"])')"
[ -n "$token" ] || {
  echo "!! Token request returned nothing"
  exit 1
}

echo "==> Writing .ctf/config"
python3 scripts/ctfconfig.py --url "$CTFD_URL" --token "$token"
