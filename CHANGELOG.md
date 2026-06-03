# Changelog

## Unreleased

### Added
- Manifest-based rollback.
- Pre-rollback safety backups.
- Managed run state tracking.
- Stronger SSH/UFW/fail2ban port consistency checks.
- Extra UFW port validation.
- Improved smoke tests.
- Non-destructive dry-run/help test script.
- CONTRIBUTING.md.
- SECURITY.md.

### Changed
- Improved dry-run summary and safety guarantees.
- Improved audit output with clearer categories.
- Improved user creation flow.
- Improved dry-run user SSH key flow with a safe `/home/<user>` fallback.
- Improved service handling.
- Improved rollback service restarts so only related services are touched.
- Improved README safety documentation.
- Improved tests with clearer help/audit coverage.
- GitHub Actions now runs smoke tests on Ubuntu 22.04 and 24.04.

### Fixed
- Fixed rollback managed target mismatch for `/etc/apt/apt.conf.d/20auto-upgrades`.
- Prevented SSH/UFW/fail2ban port mismatch.
- Prevented invalid extra UFW rules from being passed to UFW.
- Improved rollback behavior for files created by setup.
- Clarified rollback limitations and UFW history behavior.
- SSH restart remains blocked when `sshd -t` fails.
