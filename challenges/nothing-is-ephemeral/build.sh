#!/usr/bin/env bash
# Ships the auditor's console-downloaded access key. It carries no flag; it is
# the story's front door.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p dist
cp seed/auditor_accessKeys.csv dist/
echo "    dist/auditor_accessKeys.csv"
