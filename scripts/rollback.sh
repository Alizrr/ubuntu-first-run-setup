#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SSH_CONFIG="/etc/ssh/sshd_config.d/99-first-run-hardening.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
SYSCTL_CONFIG="/etc/sysctl.d/99-first-run-hardening.conf"
JOURNALD_CONFIG="/etc/systemd/journald.conf.d/99-first-run.conf"
FSTAB="/etc/fstab"

RESTORED=()
REMOVED=()
SKIPPED=()
WARNINGS=()
PRE_ROLLBACK_DIR=""
SSH_TOUCHED=0
FAIL2BAN_TOUCHED=0
JOURNALD_TOUCHED=0
SYSCTL_TOUCHED=0
FSTAB_TOUCHED=0

usage() {
  cat <<'EOF'
Ubuntu First Run Setup rollback

Usage:
  sudo ./scripts/rollback.sh /var/backups/ubuntu-first-run-setup/<backup-folder>

Rollback uses manifest.tsv from a setup run backup directory.
EOF
}

say() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
}

die() {
  say "ERROR" "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"
  local answer
  while true; do
    printf '%s [y/N] ' "$prompt" >&2
    read -r answer
    answer="${answer:-n}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) say "WARN" "Please answer yes or no." >&2 ;;
    esac
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run rollback with sudo or as root."
}

service_restart() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$service" || WARNINGS+=("Could not restart $service")
  else
    service "$service" restart || WARNINGS+=("Could not restart $service")
  fi
}

is_managed_target() {
  case "$1" in
    "$SSH_CONFIG"|"$FAIL2BAN_JAIL"|"$AUTO_UPGRADES"|"$SYSCTL_CONFIG"|"$JOURNALD_CONFIG"|"$FSTAB"|*/.ssh/authorized_keys)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mark_related_service() {
  local target="$1"
  case "$target" in
    "$SSH_CONFIG"|*/.ssh/authorized_keys) SSH_TOUCHED=1 ;;
    "$FAIL2BAN_JAIL") FAIL2BAN_TOUCHED=1 ;;
    "$JOURNALD_CONFIG") JOURNALD_TOUCHED=1 ;;
    "$SYSCTL_CONFIG") SYSCTL_TOUCHED=1 ;;
    "$FSTAB") FSTAB_TOUCHED=1 ;;
  esac
}

validate_manifest() {
  local manifest="$1"
  local line=0
  local action target backup_path timestamp

  while IFS=$'\t' read -r action target backup_path timestamp; do
    line="$((line + 1))"
    if [[ "$line" -eq 1 ]]; then
      [[ "$action" == "action" && "$target" == "target_path" && "$backup_path" == "backup_path" && "$timestamp" == "timestamp" ]] || die "Invalid manifest header"
      continue
    fi
    [[ -n "${action:-}" && -n "${target:-}" && -n "${backup_path:-}" && -n "${timestamp:-}" ]] || die "Invalid manifest row at line $line"
    case "$action" in
      modified|created|unchanged|skipped) ;;
      *) die "Invalid manifest action '$action' at line $line" ;;
    esac
    is_managed_target "$target" || die "Manifest contains unmanaged target at line $line: $target"
    if [[ "$action" == "modified" && ! -e "$backup_path" ]]; then
      die "Backup path for modified file does not exist at line $line: $backup_path"
    fi
  done <"$manifest"
}

safety_backup_current() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  local backup_path="$PRE_ROLLBACK_DIR${target}"
  install -d -m 0755 "$(dirname "$backup_path")"
  cp -a "$target" "$backup_path"
}

restore_modified() {
  local target="$1"
  local backup_path="$2"
  [[ -e "$backup_path" ]] || { WARNINGS+=("Missing backup for $target"); return; }
  safety_backup_current "$target"
  install -d -m 0755 "$(dirname "$target")"
  cp -a "$backup_path" "$target"
  RESTORED+=("$target")
  mark_related_service "$target"
}

remove_created() {
  local target="$1"
  safety_backup_current "$target"
  if [[ -e "$target" ]]; then
    rm -f -- "$target"
    REMOVED+=("$target")
    mark_related_service "$target"
  else
    SKIPPED+=("$target already absent")
  fi
}

print_plan() {
  local manifest="$1"
  say "INFO" "Rollback plan from $manifest"
  while IFS=$'\t' read -r action target backup_path timestamp; do
    [[ "$action" == "action" ]] && continue
    [[ -n "${action:-}" && -n "${target:-}" ]] || continue
    if ! is_managed_target "$target"; then
      printf '  [SKIP] unmanaged target: %s\n' "$target"
      continue
    fi
    case "$action" in
      modified) printf '  [RESTORE] %s from %s (%s)\n' "$target" "$backup_path" "$timestamp" ;;
      created) printf '  [REMOVE]  %s (%s)\n' "$target" "$timestamp" ;;
      unchanged|skipped) printf '  [SKIP]    %s was %s\n' "$target" "$action" ;;
      *) printf '  [WARN]    unknown action %s for %s\n' "$action" "$target" ;;
    esac
  done <"$manifest"
}

apply_manifest() {
  local manifest="$1"
  while IFS=$'\t' read -r action target backup_path _timestamp; do
    [[ "$action" == "action" ]] && continue
    [[ -n "${action:-}" && -n "${target:-}" ]] || continue
    if ! is_managed_target "$target"; then
      SKIPPED+=("unmanaged target: $target")
      continue
    fi
    case "$action" in
      modified) restore_modified "$target" "$backup_path" ;;
      created) remove_created "$target" ;;
      unchanged|skipped) SKIPPED+=("$target was $action") ;;
      *) WARNINGS+=("unknown manifest action '$action' for $target") ;;
    esac
  done <"$manifest"
}

post_rollback_services() {
  if [[ "$SSH_TOUCHED" -eq 1 ]]; then
    if command -v sshd >/dev/null 2>&1; then
      if sshd -t; then
        say "OK" "SSH configuration validation passed"
        service_restart ssh
      else
        WARNINGS+=("SSH validation failed; SSH restart skipped")
      fi
    else
      WARNINGS+=("sshd not available; SSH restart skipped")
    fi
  fi

  if [[ "$FAIL2BAN_TOUCHED" -eq 1 ]] && command -v fail2ban-server >/dev/null 2>&1; then
    service_restart fail2ban
  fi

  if [[ "$SYSCTL_TOUCHED" -eq 1 ]]; then
    sysctl --system || WARNINGS+=("sysctl reload reported an error")
  fi

  if [[ "$JOURNALD_TOUCHED" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-journald || WARNINGS+=("Could not restart systemd-journald")
  fi

  if [[ "$FSTAB_TOUCHED" -eq 1 ]]; then
    WARNINGS+=("/etc/fstab changed; reboot or manual swap review may be needed")
  fi
}

print_summary() {
  local item
  say "WARN" "Rollback only restores/removes managed files recorded in manifest.tsv."
  say "WARN" "Rollback does not uninstall packages, remove users, undo apt upgrades, or fully revert UFW command history."
  say "INFO" "Pre-rollback safety backup: $PRE_ROLLBACK_DIR"
  for item in "${RESTORED[@]}"; do say "OK" "Restored $item"; done
  for item in "${REMOVED[@]}"; do say "OK" "Removed created file $item"; done
  for item in "${SKIPPED[@]}"; do say "SKIP" "$item"; done
  for item in "${WARNINGS[@]}"; do say "WARN" "$item"; done
  say "OK" "Rollback completed."
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ $# -eq 1 ]] || { usage; exit 1; }
  local backup_dir="$1"
  local manifest="$backup_dir/manifest.tsv"
  [[ -d "$backup_dir" ]] || die "Backup directory does not exist: $backup_dir"
  [[ -f "$manifest" ]] || die "Manifest not found: $manifest"

  require_root
  validate_manifest "$manifest"

  PRE_ROLLBACK_DIR="/var/backups/ubuntu-first-run-setup/pre-rollback-$(date '+%Y%m%d-%H%M%S')"
  install -d -m 0755 "$PRE_ROLLBACK_DIR"

  say "WARN" "Rollback only restores/removes managed files recorded in manifest.tsv."
  say "WARN" "It does not uninstall packages, remove users, undo apt upgrades, or fully revert UFW command history."
  print_plan "$manifest"
  confirm "Apply this rollback plan?" || { say "SKIP" "Rollback cancelled."; exit 0; }

  apply_manifest "$manifest"
  post_rollback_services
  print_summary
}

main "$@"
