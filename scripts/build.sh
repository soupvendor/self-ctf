#!/usr/bin/env bash
# Run each challenge's own build.sh. Challenges that ship no artifact have none.
set -euo pipefail
cd "$(dirname "$0")/.."

found=0
for script in challenges/*/build.sh; do
  [ -f "$script" ] || continue
  found=1
  echo "==> ${script%/build.sh}"
  bash "$script"
done

[ "$found" = "1" ] || echo "No challenge build scripts found."
