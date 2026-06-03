#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf '[INFO] Checking help output\n'
bash "$ROOT_DIR/scripts/setup-ubuntu.sh" --help >/dev/null
bash "$ROOT_DIR/scripts/rollback.sh" --help >/dev/null
printf '[OK] Help output works\n'

if [[ -r /etc/os-release ]] && grep -q '^ID=ubuntu$' /etc/os-release; then
  printf '[INFO] Ubuntu detected; checking audit mode\n'
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    bash "$ROOT_DIR/scripts/setup-ubuntu.sh" --audit --no-color >/dev/null
    printf '[OK] Audit mode completed\n'
  else
    printf '[WARN] Not running as root; skipping audit invocation to avoid brittle CI behavior\n'
  fi
else
  printf '[WARN] Non-Ubuntu environment detected; skipping audit invocation\n'
fi

printf '[INFO] Interactive dry-run is not executed here because it requires operator prompts.\n'
printf '[OK] Non-destructive help/audit test completed\n'
