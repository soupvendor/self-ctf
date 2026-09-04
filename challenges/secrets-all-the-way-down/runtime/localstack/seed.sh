#!/usr/bin/env bash
# PLANTED VULNERABILITY: the deploy identity can enumerate the break-glass flag.
set -euo pipefail

: "${FLAG_CLOUD:?}"

echo "[seed] populating internal cloud account..."

awslocal secretsmanager create-secret \
  --name "staging/db/password" \
  --secret-string "hunter2-not-the-flag" >/dev/null

awslocal secretsmanager create-secret \
  --name "platform/deploy/legacy-token" \
  --secret-string "expired-do-not-use" >/dev/null

awslocal secretsmanager create-secret \
  --name "platform/break-glass/root-recovery" \
  --description "emergency access - restricted" \
  --secret-string "$FLAG_CLOUD" >/dev/null

awslocal ssm put-parameter \
  --name "/platform/notes/ops-todo" \
  --type String \
  --value "rotate the break-glass secret in secretsmanager, it predates IAM scoping" >/dev/null

awslocal ssm put-parameter \
  --name "/platform/config/region" \
  --type String \
  --value "us-east-1" >/dev/null

awslocal s3 mb s3://internal-terraform-state >/dev/null
echo "terraform state placeholder" \
  | awslocal s3 cp - s3://internal-terraform-state/staging.tfstate >/dev/null

echo "[seed] done."
