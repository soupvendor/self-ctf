#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for terraform_root in deploy/aws/terraform/foundation deploy/aws/terraform/platform deploy/aws/terraform/teams; do
  export TF_DATA_DIR="$PWD/$terraform_root/.terraform-check"
  terraform -chdir="$terraform_root" init -backend=false -input=false -lockfile=readonly
  terraform -chdir="$terraform_root" validate
  terraform -chdir="$terraform_root" test
done
