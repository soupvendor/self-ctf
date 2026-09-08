#!/usr/bin/env bash
set -euo pipefail
: "${SELF_CTF_BACKUP_DIR:?}"
: "${PLATFORM_DATA_DIR:?}"

backup_action="${1:?pre-script, post-script, or dry-run required}"
execution_id="${2:?execution ID required}"
[[ "$execution_id" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ||
  ("$backup_action" == "dry-run" && "$execution_id" == "None") ]] || {
  echo "Invalid execution ID." >&2
  exit 1
}
marker="$SELF_CTF_BACKUP_DIR/self-ctf-backup"
exec 9>"$SELF_CTF_BACKUP_DIR/self-ctf-backup.lock"
flock --nonblock 9

restore_after_failure() {
  local result=$?
  if [[ "$result" != 0 ]]; then
    echo "Quiescing failed; restoring service without taking a snapshot." >&2
    systemctl start self-ctf.service
  fi
  exit "$result"
}

case "$backup_action" in
  pre-script)
    [[ ! -e "$marker" ]] || {
      echo "Previous backup has not resumed CTFd." >&2
      exit 1
    }
    systemctl is-active --quiet self-ctf.service
    trap restore_after_failure EXIT
    systemctl stop self-ctf.service
    [[ "$(systemctl show --property=Result --value self-ctf.service)" == "success" ]] || {
      echo "Platform shutdown did not finish successfully." >&2
      exit 1
    }
    printf '%s\n' "$execution_id" >"$marker"
    trap - EXIT
    ;;
  post-script)
    [[ -f "$marker" && "$(<"$marker")" == "$execution_id" ]] || {
      echo "Backup execution does not match the stopped platform." >&2
      exit 1
    }
    systemctl start self-ctf.service
    rm "$marker"
    ;;
  dry-run)
    mountpoint --quiet "$PLATFORM_DATA_DIR"
    systemctl is-active --quiet self-ctf.service
    ;;
  *)
    echo "Unknown backup command." >&2
    exit 1
    ;;
esac
