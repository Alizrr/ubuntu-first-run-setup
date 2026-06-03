#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

APP_NAME="Ubuntu First Run Setup"
APP_VERSION="0.4.0"

DRY_RUN=0
AUDIT_MODE=0
NO_COLOR=0
LOG_FILE="/var/log/ubuntu-first-run-setup.log"
BACKUP_DIR=""
RUN_ID=""
STATE_DIR="/var/lib/ubuntu-first-run-setup/state"
STATE_FILE=""
MANIFEST_FILE=""
SSH_CONFIG_VALIDATED="not-run"
SELECTED_SSH_PORT="22"
SELECTED_PROFILE=""
SSH_PORT_SOURCE="default"
SSH_HARDENING_PORT_USED=""
UFW_SSH_PORT_USED=""
FAIL2BAN_SSH_PORT_USED=""
SSH_PUBLIC_KEY_INSTALLED_THIS_RUN=0
REBOOT_REQUIRED="unknown"

SUMMARY_DONE=()
SUMMARY_SKIPPED=()
SUMMARY_WARNINGS=()

CORE_PACKAGES=(ca-certificates curl wget gnupg lsb-release software-properties-common apt-transport-https)
BASE_PACKAGES=(git unzip zip tar rsync htop ncdu tree vim nano tmux jq ufw openssh-server unattended-upgrades apt-listchanges)
SERVER_PACKAGES=(fail2ban needrestart net-tools dnsutils chrony logrotate)
DEVELOPER_PACKAGES=(build-essential make cmake pkg-config python3 python3-pip python3-venv shellcheck)
DESKTOP_PACKAGES=(fonts-firacode gnome-tweaks gufw)

SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/99-first-run-hardening.conf"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/sshd.local"
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
SYSCTL_HARDENING_FILE="/etc/sysctl.d/99-first-run-hardening.conf"
JOURNALD_FILE="/etc/systemd/journald.conf.d/99-first-run.conf"

# -----------------------------
# CLI and output helpers
# -----------------------------

usage() {
  cat <<EOF
$APP_NAME $APP_VERSION

Usage:
  sudo ./scripts/setup-ubuntu.sh [options]

Examples:
  sudo ./scripts/setup-ubuntu.sh
  sudo ./scripts/setup-ubuntu.sh --dry-run
  sudo ./scripts/setup-ubuntu.sh --audit
  sudo ./scripts/setup-ubuntu.sh --check --no-color

Options:
  --dry-run              Print actions without applying changes
  --audit, --check       Inspect current system status without changes
  --log-file PATH        Use a custom log file in live mode
  --no-color             Disable terminal colors
  -h, --help             Show this help

Rollback:
  sudo ./scripts/rollback.sh /var/backups/ubuntu-first-run-setup/<backup-folder>
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --audit|--check) AUDIT_MODE=1 ;;
      --log-file)
        [[ $# -ge 2 ]] || die "--log-file requires a path"
        LOG_FILE="$2"
        shift
        ;;
      --no-color) NO_COLOR=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

color() {
  local code="$1"
  if [[ "$NO_COLOR" -eq 1 || ! -t 1 ]]; then
    return
  fi
  printf '\033[%sm' "$code"
}

reset_color() {
  color "0"
}

label() {
  local level="$1"
  case "$level" in
    OK) color "1;32" ;;
    WARN) color "1;33" ;;
    ERROR) color "1;31" ;;
    FAIL) color "1;31" ;;
    SKIP) color "1;90" ;;
    INFO) color "1;34" ;;
  esac
  printf '[%s]' "$level"
  reset_color
}

say() {
  local level="$1"
  shift
  label "$level"
  printf ' %s\n' "$*"
}

section() {
  printf '\n'
  color "1;34"
  printf '==> %s\n' "$1"
  reset_color
}

banner() {
  color "1;36"
  cat <<'EOF'
 __  __ __                 __          _____      __
/ / / // /  __ __  ___    / /_ __ __  / ___/___  / /_ __ __ ___
/ /_/ // _ \/ // / / _ \  / __// // /  \__ \/ -_)/ __// // // _ \
\____//_.__/\_,_/ /_//_/  \__/ \_,_/  /____/\__/ \__/ \_,_// .__/
                                                           /_/
EOF
  reset_color
  printf '%s %s\n' "$APP_NAME" "$APP_VERSION"
}

warn() {
  say "WARN" "$*" >&2
}

die() {
  say "ERROR" "$*" >&2
  exit 1
}

record_done() {
  SUMMARY_DONE+=("$1")
}

record_skipped() {
  SUMMARY_SKIPPED+=("$1")
}

record_warning() {
  SUMMARY_WARNINGS+=("$1")
}

log() {
  [[ "$DRY_RUN" -eq 1 || "$AUDIT_MODE" -eq 1 ]] && return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
}

run_cmd() {
  log "$*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    label "INFO"; printf ' dry-run command: '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

state_set() {
  local key="$1"
  local value="$2"
  [[ "$DRY_RUN" -eq 1 || "$AUDIT_MODE" -eq 1 || -z "$STATE_FILE" ]] && return 0
  printf '%s=%s\n' "$key" "$value" >>"$STATE_FILE"
}

manifest_record() {
  local action="$1"
  local target="$2"
  local backup_path="${3:--}"
  [[ "$DRY_RUN" -eq 1 || "$AUDIT_MODE" -eq 1 || -z "$MANIFEST_FILE" ]] && return 0
  printf '%s\t%s\t%s\t%s\n' "$action" "$target" "$backup_path" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$MANIFEST_FILE"
}

backup_file() {
  local path="$1"
  [[ "$DRY_RUN" -eq 1 || "$AUDIT_MODE" -eq 1 ]] && return 0
  [[ -e "$path" && -n "$BACKUP_DIR" ]] || return 0

  local backup_path="$BACKUP_DIR${path}"
  install -d -m 0755 "$(dirname "$backup_path")"
  cp -a "$path" "$backup_path"
  log "backup $path -> $backup_path"
  printf '%s' "$backup_path"
}

write_file() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local content="$4"

  log "write $path"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "dry-run write file: $path"
    printf '%s\n' "$content"
    return 0
  fi

  install -d -m 0755 "$(dirname "$path")"
  local action backup_path="-"
  if [[ -e "$path" ]]; then
    if printf '%s\n' "$content" | cmp -s - "$path"; then
      manifest_record "unchanged" "$path" "-"
      say "INFO" "No change needed for $path"
      return 0
    fi
    action="modified"
    backup_path="$(backup_file "$path")"
  else
    action="created"
  fi

  printf '%s\n' "$content" >"$path"
  chmod "$mode" "$path"
  chown "$owner" "$path"
  manifest_record "$action" "$path" "${backup_path:-"-"}"
  state_set "changed_file" "$path"
}

append_line_once() {
  local path="$1"
  local line_value="$2"

  log "append-once $path: $line_value"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "dry-run append to $path: $line_value"
    return 0
  fi

  if grep -Fqx "$line_value" "$path" 2>/dev/null; then
    manifest_record "unchanged" "$path" "-"
    say "INFO" "No change needed for $path"
    return 0
  fi

  local action backup_path="-"
  if [[ -e "$path" ]]; then
    action="modified"
    backup_path="$(backup_file "$path")"
  else
    action="created"
  fi
  printf '%s\n' "$line_value" >>"$path"
  manifest_record "$action" "$path" "${backup_path:-"-"}"
  state_set "changed_file" "$path"
}

install_authorized_key() {
  local username="$1"
  local key="$2"
  local home_dir="$3"
  local ssh_dir="$home_dir/.ssh"
  local authorized_keys="$ssh_dir/authorized_keys"

  log "install SSH public key for $username"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "dry-run install SSH key for $username"
    SSH_PUBLIC_KEY_INSTALLED_THIS_RUN=1
    return 0
  fi

  install -d -m 0700 -o "$username" -g "$username" "$ssh_dir"
  local action backup_path="-"
  if [[ -e "$authorized_keys" ]]; then
    if grep -Fqx "$key" "$authorized_keys"; then
      manifest_record "unchanged" "$authorized_keys" "-"
      chmod 0600 "$authorized_keys"
      chown "$username:$username" "$authorized_keys"
      return 0
    fi
    action="modified"
    backup_path="$(backup_file "$authorized_keys")"
  else
    action="created"
  fi

  touch "$authorized_keys"
  printf '%s\n' "$key" >>"$authorized_keys"
  manifest_record "$action" "$authorized_keys" "${backup_path:-"-"}"
  state_set "changed_file" "$authorized_keys"
  chmod 0600 "$authorized_keys"
  chown "$username:$username" "$authorized_keys"
  SSH_PUBLIC_KEY_INSTALLED_THIS_RUN=1
}

# -----------------------------
# Prompt helpers
# -----------------------------

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local answer suffix

  if [[ "$default" == "y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    printf '%s %s ' "$prompt" "$suffix" >&2
    read -r answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

prompt_value() {
  local prompt="$1"
  local default="$2"
  local value
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read -r value
  printf '%s' "${value:-$default}"
}

prompt_required() {
  local prompt="$1"
  local value
  while true; do
    printf '%s: ' "$prompt" >&2
    read -r value
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    warn "This value cannot be empty."
  done
}

prompt_validated() {
  local prompt="$1"
  local default="$2"
  local validator="$3"
  local message="$4"
  local value

  while true; do
    value="$(prompt_value "$prompt" "$default")"
    if "$validator" "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "$message"
  done
}

prompt_required_validated() {
  local prompt="$1"
  local validator="$2"
  local message="$3"
  local value

  while true; do
    value="$(prompt_required "$prompt")"
    if "$validator" "$value"; then
      printf '%s' "$value"
      return
    fi
    warn "$message"
  done
}

prompt_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local choice

  printf '%s\n' "$prompt" >&2
  local i
  for i in "${!options[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&2
  done

  while true; do
    printf 'Choose [1-%d]: ' "${#options[@]}" >&2
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#options[@]}" ]]; then
      printf '%s' "${options[$((choice - 1))]}"
      return
    fi
    warn "Invalid selection."
  done
}

# -----------------------------
# Validation helpers
# -----------------------------

is_int_range() {
  local value="$1"
  local min="$2"
  local max="$3"
  [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge "$min" ]] && [[ "$value" -le "$max" ]]
}

is_valid_port() {
  is_int_range "$1" 1 65535
}

is_valid_max_auth_tries() {
  is_int_range "$1" 1 10
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

is_valid_duration() {
  [[ "$1" =~ ^[1-9][0-9]*([smhdw])?$ ]]
}

is_valid_size() {
  [[ "$1" =~ ^[1-9][0-9]*[KMG]$ ]]
}

is_valid_swap_size() {
  [[ "$1" =~ ^[1-9][0-9]*[MG]$ ]]
}

size_to_mib() {
  local value="$1"
  local number unit
  number="${value%[MG]}"
  unit="${value: -1}"
  if [[ "$unit" == "G" ]]; then
    printf '%s' "$((number * 1024))"
  else
    printf '%s' "$number"
  fi
}

is_valid_hostname() {
  local value="$1"
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

is_valid_username() {
  local value="$1"
  [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

is_valid_ssh_public_key() {
  local value="$1"
  [[ "$value" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

is_valid_ufw_port_rule() {
  local value="$1"
  local port protocol
  [[ "$value" =~ ^([0-9]+)/([a-z]+)$ ]] || return 1
  port="${BASH_REMATCH[1]}"
  protocol="${BASH_REMATCH[2]}"
  is_valid_port "$port" && [[ "$protocol" == "tcp" || "$protocol" == "udp" ]]
}

is_valid_timezone() {
  local value="$1"
  timedatectl list-timezones 2>/dev/null | grep -Fqx "$value"
}

normalize_locale() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/g'
}

is_valid_locale() {
  local value="$1"
  local normalized
  normalized="$(normalize_locale "$value")"

  if locale -a 2>/dev/null | while read -r loc; do normalize_locale "$loc"; printf '\n'; done | grep -Fqx "$normalized"; then
    return 0
  fi

  grep -Eq "^#?[[:space:]]*${value//./\\.}[[:space:]]" /etc/locale.gen 2>/dev/null
}

prompt_port() {
  prompt_validated "$1" "$2" is_valid_port "Port must be an integer between 1 and 65535."
}

# -----------------------------
# Environment checks
# -----------------------------

is_over_ssh() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]
}

require_root_for_live() {
  if [[ "$AUDIT_MODE" -eq 1 ]]; then
    return 0
  fi
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run this script with sudo or as root."
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Detected '${PRETTY_NAME:-unknown}'. This script is intended for Ubuntu."
}

prepare_runtime() {
  if [[ "$AUDIT_MODE" -eq 1 ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "Dry-run mode: no commands, files, logs, or backups will be written."
    return 0
  fi

  RUN_ID="$(date '+%Y%m%d-%H%M%S')"
  touch "$LOG_FILE" 2>/dev/null || die "Cannot write log file: $LOG_FILE"
  BACKUP_DIR="/var/backups/ubuntu-first-run-setup/$RUN_ID"
  MANIFEST_FILE="$BACKUP_DIR/manifest.tsv"
  STATE_FILE="$STATE_DIR/$RUN_ID.state"
  install -d -m 0755 "$BACKUP_DIR"
  install -d -m 0755 "$STATE_DIR"
  printf 'action\ttarget_path\tbackup_path\ttimestamp\n' >"$MANIFEST_FILE"
  printf 'run_timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$STATE_FILE"
  state_set "app_version" "$APP_VERSION"
  state_set "mode" "live"
  state_set "backup_dir" "$BACKUP_DIR"
  state_set "manifest_file" "$MANIFEST_FILE"
  log "$APP_NAME $APP_VERSION started"
}

system_snapshot() {
  section "System Snapshot"
  say "INFO" "Host: $(hostname)"
  say "INFO" "Kernel: $(uname -r)"
  say "INFO" "Ubuntu: ${PRETTY_NAME:-unknown}"
  say "INFO" "User: ${SUDO_USER:-${USER:-root}}"
  if [[ "$AUDIT_MODE" -eq 1 ]]; then
    say "INFO" "Mode: audit"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "Mode: dry-run"
  else
    say "INFO" "Mode: live"
    say "INFO" "Log: $LOG_FILE"
    say "INFO" "Backup dir: $BACKUP_DIR"
  fi
}

ssh_lockout_warning() {
  local context="$1"
  is_over_ssh || return 0

  record_warning "Running over SSH while configuring $context"
  section "SSH Lockout Warning"
  warn "This session appears to be connected over SSH."
  warn "SSH_CONNECTION: ${SSH_CONNECTION:-not set}"
  warn "SSH_CLIENT: ${SSH_CLIENT:-not set}"
  warn "Selected SSH port: $SELECTED_SSH_PORT"
  warn "Keep this SSH session open until a second login has been tested successfully."
  warn "Changing SSH or firewall settings can lock you out of the host."

  if ! confirm "Continue with $context changes while connected over SSH?" "n"; then
    record_skipped "$context skipped due to SSH lockout risk"
    return 1
  fi
}

# -----------------------------
# Audit mode
# -----------------------------

audit_status() {
  local status="$1"
  local message="$2"
  say "$status" "$message"
}

audit_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

audit_service_active() {
  local service="$1"
  service_is_active "$service"
}

service_is_active() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$service" 2>/dev/null
  else
    service "$service" status >/dev/null 2>&1
  fi
}

service_enable() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl enable "$service"
  else
    say "INFO" "Service enable skipped for $service; systemctl is unavailable"
  fi
  state_set "enabled_service" "$service"
}

service_restart() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl restart "$service"
  else
    run_cmd service "$service" restart
  fi
  state_set "restarted_service" "$service"
}

service_reload_or_restart() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl reload-or-restart "$service"
  else
    run_cmd service "$service" restart
  fi
  state_set "reloaded_or_restarted_service" "$service"
}

audit_ssh_effective() {
  local key="$1"
  if command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk -v k="$key" '$1 == k {print $2; exit}'
    return
  fi

  case "$key" in
    port) grep -RihE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -n1 | awk '{print $2}' ;;
    permitrootlogin) grep -RihE '^[[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -n1 | awk '{print tolower($2)}' ;;
    passwordauthentication) grep -RihE '^[[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -n1 | awk '{print tolower($2)}' ;;
  esac
}

run_audit() {
  banner
  section "System"
  audit_status "INFO" "Ubuntu: ${PRETTY_NAME:-unknown}"
  audit_status "INFO" "Hostname: $(hostname)"
  audit_status "INFO" "Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || printf unknown)"
  audit_status "INFO" "Locale: ${LANG:-unknown}"

  section "Packages"
  if command -v apt-get >/dev/null 2>&1; then
    if apt-get -s upgrade 2>/dev/null | grep -q '^Inst '; then
      audit_status "WARN" "Package upgrades appear to be available"
    else
      audit_status "OK" "No package upgrades detected by apt simulation"
    fi
  else
    audit_status "WARN" "apt-get not found"
  fi

  section "Firewall"
  if audit_command_exists ufw; then
    audit_status "OK" "UFW is installed"
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      audit_status "OK" "UFW is active"
    else
      audit_status "WARN" "UFW is installed but not active"
    fi
    local audit_ssh_port
    audit_ssh_port="$(audit_ssh_effective port)"
    audit_ssh_port="${audit_ssh_port:-22}"
    if ufw status 2>/dev/null | grep -Eq "${audit_ssh_port}/tcp|${audit_ssh_port}[[:space:]]"; then
      audit_status "OK" "UFW appears to allow or rate-limit SSH port $audit_ssh_port"
    else
      audit_status "WARN" "UFW rules do not clearly show SSH port $audit_ssh_port"
    fi
    audit_status "INFO" "Current UFW rules:"
    ufw status numbered 2>/dev/null || true
  else
    audit_status "WARN" "UFW is not installed"
  fi

  section "fail2ban"
  if audit_command_exists fail2ban-server; then
    audit_status "OK" "fail2ban is installed"
    if audit_service_active fail2ban; then
      audit_status "OK" "fail2ban service is active"
    else
      audit_status "WARN" "fail2ban service is not active"
    fi
    if [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
      audit_status "INFO" "fail2ban SSH jail port: $(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$FAIL2BAN_JAIL_FILE")"
    fi
  else
    audit_status "WARN" "fail2ban is not installed"
  fi

  section "SSH"
  local ssh_port permit_root password_auth
  ssh_port="$(audit_ssh_effective port)"
  permit_root="$(audit_ssh_effective permitrootlogin)"
  password_auth="$(audit_ssh_effective passwordauthentication)"
  audit_status "INFO" "SSH port: ${ssh_port:-22}"
  if [[ "${permit_root:-}" == "no" ]]; then
    audit_status "OK" "SSH root login is disabled"
  else
    audit_status "WARN" "SSH root login is not fully disabled: ${permit_root:-unknown}"
  fi
  if [[ "${password_auth:-}" == "no" ]]; then
    audit_status "OK" "SSH password authentication is disabled"
  else
    audit_status "WARN" "SSH password authentication is not disabled: ${password_auth:-unknown}"
  fi

  section "Updates"
  if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    audit_status "OK" "unattended-upgrades is installed"
  else
    audit_status "WARN" "unattended-upgrades is not installed"
  fi
  if [[ -f "$AUTO_UPGRADES_FILE" ]] && grep -q 'Unattended-Upgrade "1"' "$AUTO_UPGRADES_FILE"; then
    audit_status "OK" "automatic security upgrades are enabled"
  else
    audit_status "WARN" "automatic security upgrades are not confirmed enabled"
  fi

  section "Logging"
  if [[ -f "$JOURNALD_FILE" ]] && grep -q '^Storage=persistent' "$JOURNALD_FILE"; then
    audit_status "OK" "persistent journald configuration exists"
  else
    audit_status "WARN" "persistent journald configuration was not found"
  fi

  section "Swap"
  if swapon --show 2>/dev/null | grep -q '^'; then
    audit_status "OK" "swap is active"
  else
    audit_status "WARN" "swap is not active"
  fi

  section "Sysctl"
  if [[ -f "$SYSCTL_HARDENING_FILE" ]]; then
    audit_status "OK" "basic sysctl hardening file exists"
  else
    audit_status "WARN" "basic sysctl hardening file was not found"
  fi

  section "Project-managed Files"
  local managed
  for managed in "$SSH_HARDENING_FILE" "$FAIL2BAN_JAIL_FILE" "$AUTO_UPGRADES_FILE" "$SYSCTL_HARDENING_FILE" "$JOURNALD_FILE"; do
    if [[ -f "$managed" ]]; then
      audit_status "OK" "Managed file exists: $managed"
    else
      audit_status "INFO" "Managed file not present: $managed"
    fi
  done

  local latest_state latest_backup
  latest_state="$(find "$STATE_DIR" -maxdepth 1 -type f -name '*.state' 2>/dev/null | sort | tail -n1 || true)"
  latest_backup="$(find /var/backups/ubuntu-first-run-setup -maxdepth 1 -type d 2>/dev/null | sort | tail -n1 || true)"
  audit_status "INFO" "Latest state file: ${latest_state:-not found}"
  audit_status "INFO" "Latest backup directory: ${latest_backup:-not found}"
}

# -----------------------------
# Setup sections
# -----------------------------

choose_profile() {
  prompt_menu "Select the closest system role:" \
    "server" \
    "developer workstation" \
    "desktop" \
    "minimal" \
    "custom"
}

build_package_list() {
  local profile="$1"
  local packages=("${CORE_PACKAGES[@]}" "${BASE_PACKAGES[@]}")

  case "$profile" in
    "server") packages+=("${SERVER_PACKAGES[@]}") ;;
    "developer workstation") packages+=("${SERVER_PACKAGES[@]}" "${DEVELOPER_PACKAGES[@]}") ;;
    "desktop") packages+=("${DESKTOP_PACKAGES[@]}") ;;
    "minimal") packages=("${CORE_PACKAGES[@]}" ufw openssh-server unattended-upgrades) ;;
    "custom") ;;
  esac

  printf '%s\n' "${packages[@]}" | awk '!seen[$0]++'
}

apt_update_upgrade() {
  section "APT Update"
  if ! confirm "Update package lists and upgrade installed packages?" "y"; then
    record_skipped "APT update and upgrade"
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update || die "apt-get update failed. Check network connectivity and APT repositories."
  run_cmd apt-get upgrade -y || die "apt-get upgrade failed. Review APT output before retrying."
  if [[ "$DRY_RUN" -eq 0 && -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED="yes"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    REBOOT_REQUIRED="dry-run-unknown"
  else
    REBOOT_REQUIRED="no"
  fi
  record_done "APT package lists updated and packages upgraded"
}

install_packages() {
  local profile="$1"
  section "Packages"
  if ! confirm "Install packages for '$profile' profile?" "y"; then
    record_skipped "Package installation"
    return
  fi

  local default_list package_input
  default_list="$(build_package_list "$profile" | paste -sd ' ' -)"
  package_input="$(prompt_value "Packages, separated by spaces" "$default_list")"

  # shellcheck disable=SC2206
  local packages=($package_input)
  [[ "${#packages[@]}" -gt 0 ]] || { warn "No packages selected."; record_skipped "No packages selected"; return; }

  run_cmd apt-get install -y "${packages[@]}" || die "Package installation failed for selected '$profile' package set."
  record_done "Installed ${#packages[@]} packages"
}

configure_identity() {
  section "System Identity"
  if confirm "Configure hostname?" "y"; then
    local current_hostname new_hostname
    current_hostname="$(hostname)"
    new_hostname="$(prompt_validated "Hostname" "$current_hostname" is_valid_hostname "Invalid hostname format.")"
    if [[ "$new_hostname" != "$current_hostname" ]]; then
      run_cmd hostnamectl set-hostname "$new_hostname"
      record_done "Hostname set to $new_hostname"
    else
      record_skipped "Hostname unchanged"
    fi
  else
    record_skipped "Hostname configuration"
  fi

  if confirm "Configure timezone?" "y"; then
    if ! command -v timedatectl >/dev/null 2>&1; then
      warn "timedatectl is not available; skipping timezone configuration."
      record_skipped "Timezone configuration missing timedatectl"
    else
    local current_timezone timezone
    current_timezone="$(timedatectl show -p Timezone --value 2>/dev/null || printf 'UTC')"
    timezone="$(prompt_validated "Timezone" "${current_timezone:-UTC}" is_valid_timezone "Timezone must exist in timedatectl list-timezones.")"
    run_cmd timedatectl set-timezone "$timezone"
    record_done "Timezone set to $timezone"
    fi
  else
    record_skipped "Timezone configuration"
  fi

  if confirm "Configure locale?" "n"; then
    if ! command -v locale-gen >/dev/null 2>&1 || ! command -v update-locale >/dev/null 2>&1; then
      warn "locale-gen or update-locale is unavailable; skipping locale configuration."
      record_skipped "Locale configuration missing required commands"
    else
    local locale_value
    locale_value="$(prompt_validated "Locale" "en_US.UTF-8" is_valid_locale "Locale must be available in locale -a or /etc/locale.gen.")"
    run_cmd locale-gen "$locale_value"
    run_cmd update-locale "LANG=$locale_value"
    record_done "Locale set to $locale_value"
    fi
  else
    record_skipped "Locale configuration"
  fi
}

configure_user() {
  section "Users"
  if ! confirm "Create or update a sudo user?" "n"; then
    record_skipped "Sudo user configuration"
    return
  fi

  local username
  username="$(prompt_validated "Username" "admin" is_valid_username "Username must start with a lowercase letter or underscore and contain only lowercase letters, digits, underscore, or dash.")"
  if id "$username" >/dev/null 2>&1; then
    warn "User '$username' already exists."
  else
    run_cmd adduser --disabled-password --gecos "" "$username"
    record_done "User '$username' created"
    if confirm "Set a password for '$username' now?" "n"; then
      run_cmd passwd "$username"
    else
      record_warning "User '$username' was created with password login disabled until a password is set"
    fi
  fi

  if confirm "Add '$username' to sudo group?" "y"; then
    run_cmd usermod -aG sudo "$username"
    record_done "User '$username' is in sudo group"
  else
    record_skipped "sudo group membership for '$username'"
  fi

  if confirm "Install an SSH public key for this user?" "n"; then
    local key home_dir
    key="$(prompt_required_validated "Paste SSH public key" is_valid_ssh_public_key "SSH public key must start with ssh-ed25519, ssh-rsa, or ecdsa-sha2-nistp*.")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      home_dir="/home/$username"
    else
      home_dir="$(getent passwd "$username" 2>/dev/null | cut -d: -f6 || true)"
      home_dir="${home_dir:-"/home/$username"}"
    fi
    install_authorized_key "$username" "$key" "$home_dir"
    record_done "SSH public key installed for '$username'"
  fi
}

validate_sshd_config() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    SSH_CONFIG_VALIDATED="dry-run"
    say "INFO" "dry-run would run: sshd -t"
    return 0
  fi

  if sshd -t; then
    SSH_CONFIG_VALIDATED="passed"
    say "OK" "SSH configuration validation passed"
    return 0
  fi

  SSH_CONFIG_VALIDATED="failed"
  warn "SSH configuration validation failed. SSH will not be restarted."
  return 1
}

configure_ssh() {
  section "SSH Hardening"
  if ! confirm "Configure SSH server hardening?" "y"; then
    if confirm "Keep canonical SSH port as 22 for firewall/fail2ban?" "y"; then
      SELECTED_SSH_PORT="22"
      SSH_PORT_SOURCE="default"
    else
      warn "Only override this if SSH is already listening on the selected port."
      SELECTED_SSH_PORT="$(prompt_port "Canonical SSH port for firewall/fail2ban" "$SELECTED_SSH_PORT")"
      SSH_PORT_SOURCE="global-override"
      record_warning "Canonical SSH port was overridden without managing SSH config"
    fi
    record_skipped "SSH hardening"
    return
  fi
  ssh_lockout_warning "SSH" || return

  command -v sshd >/dev/null 2>&1 || run_cmd apt-get install -y openssh-server

  local port password_auth permit_root max_auth
  port="$(prompt_port "SSH port" "$SELECTED_SSH_PORT")"
  SELECTED_SSH_PORT="$port"

  if confirm "Disable root SSH login?" "y"; then
    permit_root="no"
  else
    permit_root="prohibit-password"
  fi

  if confirm "Disable password authentication? Only choose yes when key login is already working." "n"; then
    warn "Password authentication will be disabled. SSH key access must already work."
    if [[ "$SSH_PUBLIC_KEY_INSTALLED_THIS_RUN" -eq 0 ]]; then
      warn "No SSH public key was installed during this run."
    fi
    if ! confirm "I have tested SSH key login successfully. Disable password authentication?" "n"; then
      password_auth="yes"
      record_warning "SSH password authentication disable request was cancelled"
    else
      password_auth="no"
    fi
  else
    password_auth="yes"
  fi

  max_auth="$(prompt_validated "MaxAuthTries" "3" is_valid_max_auth_tries "MaxAuthTries must be an integer between 1 and 10.")"
  SSH_HARDENING_PORT_USED="$SELECTED_SSH_PORT"
  SSH_PORT_SOURCE="ssh-hardening"

  write_file "$SSH_HARDENING_FILE" "0644" "root:root" \
"Port $port
PermitRootLogin $permit_root
PasswordAuthentication $password_auth
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries $max_auth
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
UseDNS no"

  validate_sshd_config || { record_warning "SSH config validation failed; restart skipped"; return; }

  service_enable ssh
  service_restart ssh
  record_done "SSH hardened on port $port"
}

configure_firewall() {
  section "Firewall"
  if ! confirm "Configure UFW firewall?" "y"; then
    record_skipped "UFW firewall"
    return
  fi
  ssh_lockout_warning "firewall" || return

  command -v ufw >/dev/null 2>&1 || run_cmd apt-get install -y ufw

  local extra_ports port
  UFW_SSH_PORT_USED="$SELECTED_SSH_PORT"

  if confirm "Reset existing UFW rules before applying baseline?" "n"; then
    run_cmd ufw --force reset
    record_warning "Existing UFW rules were reset by user request"
  fi

  run_cmd ufw default deny incoming
  run_cmd ufw default allow outgoing
  run_cmd ufw limit "${SELECTED_SSH_PORT}/tcp"

  if confirm "Allow HTTP 80/tcp?" "n"; then
    run_cmd ufw allow 80/tcp
  fi
  if confirm "Allow HTTPS 443/tcp?" "n"; then
    run_cmd ufw allow 443/tcp
  fi

  extra_ports="$(prompt_value "Extra allowed ports. Examples: 8080/tcp 51820/udp. Use '-' for none" "-")"
  if [[ "$extra_ports" != "-" ]]; then
    # shellcheck disable=SC2206
    local ports=($extra_ports)
    for port in "${ports[@]}"; do
      if is_valid_ufw_port_rule "$port"; then
        run_cmd ufw allow "$port"
      else
        warn "Skipping invalid UFW rule: $port"
        record_warning "Invalid UFW rule skipped: $port"
      fi
    done
  fi

  run_cmd ufw --force enable
  say "INFO" "UFW rules summary:"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "dry-run would run: ufw status numbered"
  else
    ufw status numbered || true
    if ! ufw status 2>/dev/null | grep -Eq "${SELECTED_SSH_PORT}/tcp|${SELECTED_SSH_PORT}[[:space:]]"; then
      warn "UFW is active but selected SSH port $SELECTED_SSH_PORT is not clearly visible in rules."
      record_warning "Selected SSH port not clearly visible in UFW status"
    fi
  fi
  record_done "UFW enabled with SSH rate-limit on port $SELECTED_SSH_PORT"
}

configure_fail2ban() {
  section "Intrusion Protection"
  if ! confirm "Install and configure fail2ban for SSH?" "y"; then
    record_skipped "fail2ban"
    return
  fi

  command -v fail2ban-server >/dev/null 2>&1 || run_cmd apt-get install -y fail2ban
  local bantime findtime maxretry
  bantime="$(prompt_validated "Ban time" "1h" is_valid_duration "Ban time must be a positive integer or duration like 10m, 1h, 1d.")"
  findtime="$(prompt_validated "Find time" "10m" is_valid_duration "Find time must be a positive integer or duration like 10m, 1h, 1d.")"
  maxretry="$(prompt_validated "Max retries" "5" is_positive_int "Max retries must be a positive integer.")"
  FAIL2BAN_SSH_PORT_USED="$SELECTED_SSH_PORT"

  write_file "$FAIL2BAN_JAIL_FILE" "0644" "root:root" \
"[sshd]
enabled = true
port = $SELECTED_SSH_PORT
bantime = $bantime
findtime = $findtime
maxretry = $maxretry"

  service_enable fail2ban
  service_restart fail2ban
  record_done "fail2ban enabled for SSH on port $SELECTED_SSH_PORT"
}

configure_unattended_upgrades() {
  section "Security Updates"
  if ! confirm "Enable unattended security upgrades?" "y"; then
    record_skipped "Unattended upgrades"
    return
  fi

  run_cmd apt-get install -y unattended-upgrades apt-listchanges
  write_file "$AUTO_UPGRADES_FILE" "0644" "root:root" \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";'

  run_cmd dpkg-reconfigure -f noninteractive unattended-upgrades
  record_done "Automatic security upgrades enabled"
}

configure_sysctl() {
  section "Kernel Network Hardening"
  if ! confirm "Apply conservative sysctl network hardening?" "y"; then
    record_skipped "sysctl hardening"
    return
  fi

  write_file "$SYSCTL_HARDENING_FILE" "0644" "root:root" \
'net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1'

  run_cmd sysctl --system
  record_done "Conservative network hardening applied"
}

configure_journald() {
  section "System Logs"
  if ! confirm "Configure persistent journald logs with size limit?" "y"; then
    record_skipped "journald configuration"
    return
  fi

  local max_use
  max_use="$(prompt_validated "SystemMaxUse" "1G" is_valid_size "SystemMaxUse must be a size like 100M or 1G.")"
  write_file "$JOURNALD_FILE" "0644" "root:root" \
"[Journal]
Storage=persistent
SystemMaxUse=$max_use
Compress=yes"

  service_restart systemd-journald
  record_done "journald persistence enabled"
}

configure_git() {
  section "Git"
  if ! confirm "Configure global Git name and email for a user?" "n"; then
    record_skipped "Git configuration"
    return
  fi

  local target_user git_name git_email
  target_user="$(prompt_value "Linux user for Git config" "${SUDO_USER:-${USER:-root}}")"
  git_name="$(prompt_required "Git user.name")"
  git_email="$(prompt_required "Git user.email")"

  if id "$target_user" >/dev/null 2>&1; then
    run_cmd sudo -u "$target_user" git config --global user.name "$git_name"
    run_cmd sudo -u "$target_user" git config --global user.email "$git_email"
    run_cmd sudo -u "$target_user" git config --global init.defaultBranch main
    record_done "Git configured for '$target_user'"
  else
    warn "User '$target_user' not found."
    record_skipped "Git configuration"
  fi
}

create_swap() {
  section "Swap"
  if ! confirm "Create a swap file if swap is not active?" "n"; then
    record_skipped "Swap file"
    return
  fi

  if swapon --show | grep -q '^'; then
    warn "Swap is already active."
    record_skipped "Swap already active"
    return
  fi

  if ! command -v fallocate >/dev/null 2>&1 || ! command -v mkswap >/dev/null 2>&1 || ! command -v swapon >/dev/null 2>&1; then
    warn "fallocate, mkswap, or swapon is unavailable; skipping swap creation."
    record_skipped "Swap creation missing required commands"
    return
  fi

  local size
  size="$(prompt_validated "Swap size, for example 512M, 1G, 2G" "2G" is_valid_swap_size "Swap size must be a positive size like 512M, 1G, or 2G.")"

  if [[ -e /swapfile ]]; then
    warn "/swapfile already exists. It will not be overwritten."
    record_skipped "Swap file exists"
    return
  fi

  if command -v df >/dev/null 2>&1; then
    local requested_mib available_mib
    requested_mib="$(size_to_mib "$size")"
    available_mib="$(df -Pm / | awk 'NR == 2 {print $4}')"
    if [[ "$available_mib" =~ ^[0-9]+$ && "$available_mib" -le "$requested_mib" ]]; then
      warn "Not enough free disk space for requested swap size $size."
      record_skipped "Swap file skipped due to insufficient disk space"
      return
    fi
  fi

  run_cmd fallocate -l "$size" /swapfile
  run_cmd chmod 600 /swapfile
  run_cmd mkswap /swapfile || { warn "mkswap failed. Remove /swapfile manually after inspection if needed."; return; }
  run_cmd swapon /swapfile || { warn "swapon failed. Check /swapfile and /etc/fstab before retrying."; return; }
  append_line_once "/etc/fstab" "/swapfile none swap sw 0 0"
  record_done "Swap file created: $size"
}

cleanup_apt() {
  section "Cleanup"
  if ! confirm "Run apt autoremove and autoclean?" "y"; then
    record_skipped "APT cleanup"
    return
  fi

  run_cmd apt-get autoremove -y
  run_cmd apt-get autoclean -y
  record_done "APT cleanup completed"
}

final_service_status() {
  local service="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run'
    return
  fi

  if service_is_active "$service"; then
    printf 'active'
  else
    printf 'unknown/inactive'
  fi
}

final_ufw_status() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run'
    return
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    printf 'active'
  elif command -v ufw >/dev/null 2>&1; then
    printf 'inactive'
  else
    printf 'not installed'
  fi
}

print_summary() {
  section "Summary"
  local item

  say "OK" "Changed sections: ${#SUMMARY_DONE[@]}"
  for item in "${SUMMARY_DONE[@]}"; do
    say "OK" "$item"
  done

  if [[ "${#SUMMARY_SKIPPED[@]}" -gt 0 ]]; then
    printf '\n'
    for item in "${SUMMARY_SKIPPED[@]}"; do
      say "SKIP" "$item"
    done
  fi

  if [[ "${#SUMMARY_WARNINGS[@]}" -gt 0 ]]; then
    printf '\n'
    for item in "${SUMMARY_WARNINGS[@]}"; do
      say "WARN" "$item"
    done
  fi

  printf '\n'
  say "INFO" "SSH config validation: $SSH_CONFIG_VALIDATED"
  say "INFO" "Profile: ${SELECTED_PROFILE:-unknown}"
  say "INFO" "Selected SSH port: $SELECTED_SSH_PORT"
  if [[ -n "$SSH_HARDENING_PORT_USED" ]]; then
    say "OK" "SSH hardening uses port $SSH_HARDENING_PORT_USED"
  else
    say "SKIP" "SSH hardening did not manage the SSH port"
  fi
  if [[ -n "$UFW_SSH_PORT_USED" ]]; then
    say "OK" "UFW allows/rate-limits port $UFW_SSH_PORT_USED/tcp"
  else
    say "SKIP" "UFW was not configured by this run"
  fi
  if [[ -n "$FAIL2BAN_SSH_PORT_USED" ]]; then
    say "OK" "fail2ban jail uses port $FAIL2BAN_SSH_PORT_USED"
  else
    say "SKIP" "fail2ban was not configured by this run"
  fi
  say "INFO" "UFW state: $(final_ufw_status)"
  say "INFO" "fail2ban service state: $(final_service_status fail2ban)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "INFO" "Dry-run completed."
    say "INFO" "No system, file, log, backup, or state changes were made."
  else
    say "INFO" "Log file: $LOG_FILE"
    say "INFO" "Backup dir: $BACKUP_DIR"
    say "INFO" "State file: $STATE_FILE"
  fi

  if [[ "$REBOOT_REQUIRED" == "yes" ]]; then
    say "WARN" "Reboot required: yes"
  elif [[ "$REBOOT_REQUIRED" == "dry-run-unknown" ]]; then
    say "INFO" "Reboot required: unknown in dry-run"
  else
    say "INFO" "Reboot required: ${REBOOT_REQUIRED:-unknown}"
  fi
  say "INFO" "Next: test a second SSH login before closing this session if SSH or UFW changed."
}

main() {
  parse_args "$@"
  require_ubuntu

  if [[ "$AUDIT_MODE" -eq 1 ]]; then
    run_audit
    exit 0
  fi

  require_root_for_live
  prepare_runtime
  banner
  system_snapshot

  local profile
  section "Profile"
  profile="$(choose_profile)"
  SELECTED_PROFILE="$profile"
  state_set "selected_profile" "$SELECTED_PROFILE"

  apt_update_upgrade
  install_packages "$profile"
  configure_identity
  configure_user
  configure_ssh
  configure_firewall
  configure_fail2ban
  configure_unattended_upgrades
  configure_sysctl
  configure_journald
  configure_git
  create_swap
  cleanup_apt
  state_set "selected_ssh_port" "$SELECTED_SSH_PORT"
  state_set "ssh_port_source" "$SSH_PORT_SOURCE"
  state_set "ssh_config_validation" "$SSH_CONFIG_VALIDATED"
  state_set "reboot_required" "$REBOOT_REQUIRED"
  print_summary
}

main "$@"
