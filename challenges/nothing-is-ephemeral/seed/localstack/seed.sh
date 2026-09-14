#!/usr/bin/env bash
# PLANTED VULNERABILITY - do not "fix" this.
#
# The flaw: Terraform writes every attribute to state, sensitive or not. The
# team "remediated" a leaked Secrets Manager value by switching to a write-only
# argument and re-applying, which wrote a new state version and left the old one
# in the versioned bucket. The RDS master password was never noticed and is
# still in the current version. Do not disable versioning, scrub the prior
# version, or remove the password.
#
# Intended solve: list buckets, read the current state, then list object
# versions and read the previous one.
set -euo pipefail
rm -f /tmp/self-ctf-seeded

: "${FLAG_STATE_CURRENT:?}" "${FLAG_STATE_PRIOR:?}"

bucket="data-platform-tfstate"
key="env/prod/terraform.tfstate"

fail() {
  echo "!! $*" >&2
  exit 1
}

# Serial 41: the state as it was before the ticket. Both secrets in plaintext,
# and Terraform knows they are sensitive - that is what sensitive_attributes is.
prior="$(
  cat <<'STATE'
{
  "version": 4,
  "terraform_version": "1.9.8",
  "serial": 41,
  "lineage": "9c4b7e2a-31d6-4f0e-9b8a-5e2c7d1a6f43",
  "outputs": {
    "warehouse_endpoint": {
      "value": "dp-warehouse-prod.c9x2k1q7m3ab.us-east-1.rds.amazonaws.com:5432",
      "type": "string"
    }
  },
  "resources": [
    {
      "mode": "managed",
      "type": "random_password",
      "name": "warehouse",
      "provider": "provider[\"registry.terraform.io/hashicorp/random\"]",
      "instances": [
        {
          "schema_version": 3,
          "attributes": {
            "bcrypt_hash": "$2a$10$Xq1yv0Z9nKcW3fE7rTbH8eJ5LmPaQ2sVdUoR4wYt6ZiBgNhCkFjDl",
            "id": "none",
            "keepers": null,
            "length": 32,
            "lower": true,
            "min_lower": 0,
            "min_numeric": 0,
            "min_special": 0,
            "min_upper": 0,
            "number": true,
            "numeric": true,
            "override_special": null,
            "result": "__FLAG_STATE_CURRENT__",
            "special": false,
            "upper": true
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "bcrypt_hash"}],
            [{"type": "get_attr", "value": "result"}]
          ]
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_db_instance",
      "name": "warehouse",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 2,
          "attributes": {
            "address": "dp-warehouse-prod.c9x2k1q7m3ab.us-east-1.rds.amazonaws.com",
            "allocated_storage": 200,
            "arn": "arn:aws:rds:us-east-1:210987654321:db:dp-warehouse-prod",
            "db_name": "warehouse",
            "engine": "postgres",
            "engine_version": "16.3",
            "id": "db-K7QX2PJ4MNZ6TAB3WR5LC9YV8E",
            "identifier": "dp-warehouse-prod",
            "instance_class": "db.r6g.xlarge",
            "multi_az": true,
            "password": "__FLAG_STATE_CURRENT__",
            "port": 5432,
            "publicly_accessible": false,
            "storage_encrypted": true,
            "username": "warehouse_admin"
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "password"}]
          ],
          "dependencies": ["random_password.warehouse"]
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_secretsmanager_secret",
      "name": "api_signing_key",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "arn": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "description": "HMAC key for the ingest API",
            "id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "name": "data-platform/api/signing-key",
            "recovery_window_in_days": 30,
            "tags": {"team": "data-platform"}
          },
          "sensitive_attributes": []
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_secretsmanager_secret_version",
      "name": "api_signing_key",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "arn": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx|3f0d6b2e-8a51-4c7e-9d2b-1e6f5a9c0b47",
            "secret_binary": null,
            "secret_id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "secret_string": "__FLAG_STATE_PRIOR__",
            "version_id": "3f0d6b2e-8a51-4c7e-9d2b-1e6f5a9c0b47",
            "version_stages": ["AWSCURRENT"]
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "secret_string"}]
          ],
          "dependencies": ["aws_secretsmanager_secret.api_signing_key"]
        }
      ]
    }
  ]
}
STATE
)"

# Serial 42: after the ticket. The signing key moved to a write-only argument,
# so its value is gone from this version. The database password was never part
# of the ticket and is exactly where it was.
current="$(
  cat <<'STATE'
{
  "version": 4,
  "terraform_version": "1.11.4",
  "serial": 42,
  "lineage": "9c4b7e2a-31d6-4f0e-9b8a-5e2c7d1a6f43",
  "outputs": {
    "warehouse_endpoint": {
      "value": "dp-warehouse-prod.c9x2k1q7m3ab.us-east-1.rds.amazonaws.com:5432",
      "type": "string"
    }
  },
  "resources": [
    {
      "mode": "managed",
      "type": "random_password",
      "name": "warehouse",
      "provider": "provider[\"registry.terraform.io/hashicorp/random\"]",
      "instances": [
        {
          "schema_version": 3,
          "attributes": {
            "bcrypt_hash": "$2a$10$Xq1yv0Z9nKcW3fE7rTbH8eJ5LmPaQ2sVdUoR4wYt6ZiBgNhCkFjDl",
            "id": "none",
            "keepers": null,
            "length": 32,
            "lower": true,
            "min_lower": 0,
            "min_numeric": 0,
            "min_special": 0,
            "min_upper": 0,
            "number": true,
            "numeric": true,
            "override_special": null,
            "result": "__FLAG_STATE_CURRENT__",
            "special": false,
            "upper": true
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "bcrypt_hash"}],
            [{"type": "get_attr", "value": "result"}]
          ]
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_db_instance",
      "name": "warehouse",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 2,
          "attributes": {
            "address": "dp-warehouse-prod.c9x2k1q7m3ab.us-east-1.rds.amazonaws.com",
            "allocated_storage": 200,
            "arn": "arn:aws:rds:us-east-1:210987654321:db:dp-warehouse-prod",
            "db_name": "warehouse",
            "engine": "postgres",
            "engine_version": "16.3",
            "id": "db-K7QX2PJ4MNZ6TAB3WR5LC9YV8E",
            "identifier": "dp-warehouse-prod",
            "instance_class": "db.r6g.xlarge",
            "multi_az": true,
            "password": "__FLAG_STATE_CURRENT__",
            "port": 5432,
            "publicly_accessible": false,
            "storage_encrypted": true,
            "username": "warehouse_admin"
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "password"}]
          ],
          "dependencies": ["random_password.warehouse"]
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_secretsmanager_secret",
      "name": "api_signing_key",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "arn": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "description": "HMAC key for the ingest API",
            "id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "name": "data-platform/api/signing-key",
            "recovery_window_in_days": 30,
            "tags": {"team": "data-platform"}
          },
          "sensitive_attributes": []
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_secretsmanager_secret_version",
      "name": "api_signing_key",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "arn": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "has_secret_string_wo": true,
            "id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx|a81c4e97-2d63-4b0f-8e15-7c9d2f4a6b30",
            "secret_binary": null,
            "secret_id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform/api/signing-key-Qm7Ztx",
            "secret_string": null,
            "secret_string_wo": null,
            "secret_string_wo_version": 2,
            "version_id": "a81c4e97-2d63-4b0f-8e15-7c9d2f4a6b30",
            "version_stages": ["AWSCURRENT"]
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "secret_string"}]
          ],
          "dependencies": ["aws_secretsmanager_secret.api_signing_key"]
        }
      ]
    }
  ]
}
STATE
)"

# Staging never had the database and was migrated at the same time. It is in
# the bucket so the listing has more than one thing in it.
staging="$(
  cat <<'STATE'
{
  "version": 4,
  "terraform_version": "1.11.4",
  "serial": 17,
  "lineage": "2b8e5f1c-7a94-4d36-b0e2-c6f3a9d84e15",
  "outputs": {},
  "resources": [
    {
      "mode": "managed",
      "type": "aws_secretsmanager_secret",
      "name": "api_signing_key",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "arn": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform-staging/api/signing-key-Lp3Wvq",
            "description": "HMAC key for the ingest API (staging)",
            "id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform-staging/api/signing-key-Lp3Wvq",
            "name": "data-platform-staging/api/signing-key",
            "recovery_window_in_days": 7,
            "tags": {"team": "data-platform"}
          },
          "sensitive_attributes": []
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_secretsmanager_secret_version",
      "name": "api_signing_key",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "arn": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform-staging/api/signing-key-Lp3Wvq",
            "has_secret_string_wo": true,
            "id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform-staging/api/signing-key-Lp3Wvq|c4d9e2f7-1b58-4a03-9e6c-8d2f5b7a1c94",
            "secret_binary": null,
            "secret_id": "arn:aws:secretsmanager:us-east-1:210987654321:secret:data-platform-staging/api/signing-key-Lp3Wvq",
            "secret_string": null,
            "secret_string_wo": null,
            "secret_string_wo_version": 1,
            "version_id": "c4d9e2f7-1b58-4a03-9e6c-8d2f5b7a1c94",
            "version_stages": ["AWSCURRENT"]
          },
          "sensitive_attributes": [
            [{"type": "get_attr", "value": "secret_string"}]
          ],
          "dependencies": ["aws_secretsmanager_secret.api_signing_key"]
        }
      ]
    }
  ]
}
STATE
)"

prior="${prior//__FLAG_STATE_CURRENT__/$FLAG_STATE_CURRENT}"
prior="${prior//__FLAG_STATE_PRIOR__/$FLAG_STATE_PRIOR}"
current="${current//__FLAG_STATE_CURRENT__/$FLAG_STATE_CURRENT}"

echo "[seed] creating the data-platform state bucket..."
awslocal s3 mb "s3://$bucket" >/dev/null
awslocal s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
printf '%s\n' "$prior" | awslocal s3 cp - "s3://$bucket/$key" >/dev/null
printf '%s\n' "$current" | awslocal s3 cp - "s3://$bucket/$key" >/dev/null
printf '%s\n' "$staging" | awslocal s3 cp - "s3://$bucket/env/staging/terraform.tfstate" >/dev/null

# The puzzle needs exactly this shape, so check it rather than trust the calls.
count="$(awslocal s3api list-object-versions --bucket "$bucket" --prefix "$key" \
  --query 'length(Versions)' --output text)"
[ "$count" = "2" ] || fail "expected 2 versions of $key, found $count"

latest="$(awslocal s3 cp "s3://$bucket/$key" -)"
[[ "$latest" == *"$FLAG_STATE_CURRENT"* ]] || fail "current state is missing its flag"
[[ "$latest" != *"$FLAG_STATE_PRIOR"* ]] || fail "current state still holds the prior flag"

old_id="$(awslocal s3api list-object-versions --bucket "$bucket" --prefix "$key" \
  --query 'Versions[?!IsLatest].VersionId | [0]' --output text)"
old="$(mktemp)"
awslocal s3api get-object --bucket "$bucket" --key "$key" --version-id "$old_id" "$old" >/dev/null
grep -Fq "$FLAG_STATE_PRIOR" "$old" || fail "prior state version is missing its flag"
rm -f "$old"

echo "[seed] done."

touch /tmp/self-ctf-seeded
