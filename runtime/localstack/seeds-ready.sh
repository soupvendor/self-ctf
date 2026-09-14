#!/usr/bin/env bash
# Health check. LocalStack's init endpoint answers 200 with "completed": true
# even when a ready.d script failed - the failure is only in the per-script
# state - so this reads that state instead of trusting the status code.
set -euo pipefail

curl -fsS http://localhost:4566/_localstack/init/ready | python3 -c '
import json, sys
status = json.load(sys.stdin)
scripts = status.get("scripts", [])
ok = status.get("completed") and scripts and all(s.get("state") == "SUCCESSFUL" for s in scripts)
sys.exit(0 if ok else 1)
'
