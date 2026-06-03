# Contributing

Thanks for helping improve Ubuntu First Run Setup.

## Local Checks

Run:

```bash
bash tests/smoke-test.sh
```

If ShellCheck is installed, the smoke test runs it automatically. You can also run it directly:

```bash
shellcheck scripts/setup-ubuntu.sh scripts/rollback.sh tests/*.sh
```

## Safety Expectations

- Keep dry-run mode non-destructive.
- Keep audit/check mode read-only.
- Do not add destructive behavior without explicit confirmation.
- Do not restart SSH unless `sshd -t` passes.
- Do not change firewall behavior in a way that can silently block SSH.
- Do not overwrite managed files without backup and manifest tracking.
- Keep rollback behavior conservative and easy to inspect.

## Code Style

- Prefer readable Bash over clever Bash.
- Add comments only for safety decisions or non-obvious behavior.
- Keep direct usage working:

```bash
sudo ./scripts/setup-ubuntu.sh
```

## SSH And Firewall Changes

Test SSH and firewall changes in a VM or disposable VPS before opening a pull request. Always consider lockout risk.
