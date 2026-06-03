#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=()

while IFS= read -r script; do
  SCRIPTS+=("$script")
done < <(find "$ROOT_DIR/scripts" "$ROOT_DIR/tests" -type f -name '*.sh' | sort)

if [[ -d "$ROOT_DIR/lib" ]]; then
  while IFS= read -r script; do
    SCRIPTS+=("$script")
  done < <(find "$ROOT_DIR/lib" -type f -name '*.sh' | sort)
fi

printf '[INFO] Running Bash syntax checks\n'
for script in "${SCRIPTS[@]}"; do
  bash -n "$script"
  printf '[OK] bash -n %s\n' "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  printf '[INFO] Running ShellCheck\n'
  shellcheck "${SCRIPTS[@]}"
  printf '[OK] ShellCheck passed\n'
else
  printf '[WARN] ShellCheck is not installed; skipping ShellCheck\n'
fi

printf '[OK] Smoke test completed without modifying the system\n'
