# Ubuntu First Run Setup

Interactive Ubuntu first-run setup and baseline hardening script.

I built this project to keep the usual post-install Ubuntu setup steps in one place: update packages, configure SSH safely, enable a basic firewall, set up fail2ban, enable security updates, configure logging, apply a small sysctl baseline, and keep enough backup/state information to understand what changed.

The script is intentionally interactive. It asks before major changes, supports dry-run and audit modes, and includes rollback support for managed configuration files.

> This script can change SSH and firewall settings. A wrong SSH port, missing SSH key, or incorrect firewall rule can lock you out of a remote machine. Test it in a VM or disposable VPS before using it on a system you care about.

This is not a replacement for Ansible, cloud-init, Terraform, Puppet, Chef, Salt, or a compliance framework. It is a practical first-run helper for small servers, VPS instances, lab machines, and personal Linux setups.

---

## Features

* Interactive setup profiles:

  * `server`
  * `developer workstation`
  * `desktop`
  * `minimal`
  * `custom`
* APT update, upgrade, package installation, and cleanup
* Hostname, timezone, and locale configuration
* Controlled sudo user creation
* Optional SSH public key installation
* SSH hardening through `/etc/ssh/sshd_config.d/`
* SSH config validation with `sshd -t` before restart
* SSH lockout warnings when running over SSH
* UFW baseline firewall setup
* Consistent SSH port handling across SSH, UFW, and fail2ban
* Extra UFW rule validation, for example `8080/tcp` or `51820/udp`
* fail2ban SSH jail configuration
* unattended security upgrades
* Conservative network `sysctl` hardening
* Persistent journald logging with disk limit
* Optional swap file creation
* Dry-run mode
* Audit/check mode
* Manifest-based rollback
* Pre-rollback safety backups
* Managed run state file
* Local smoke tests
* GitHub Actions workflow with Bash syntax checks and ShellCheck

---

## Supported Ubuntu Versions

Expected targets:

* Ubuntu 20.04 LTS
* Ubuntu 22.04 LTS
* Ubuntu 24.04 LTS
* Ubuntu Server or Desktop

The script checks `/etc/os-release` and exits if the detected distribution is not Ubuntu.

---

## Requirements

* Bash
* Ubuntu package tooling: `apt-get`, `dpkg`
* root privileges for live setup and rollback
* internet access for package installation
* common Ubuntu tools such as:

  * `systemctl`
  * `timedatectl`
  * `locale-gen`
  * `sshd`
  * `ufw`
  * `swapon`

Some commands are only needed when their related section is selected.

---

## Quick Start

Clone the repository:

```bash
git clone https://github.com/Alizrr/ubuntu-first-run-setup.git
cd ubuntu-first-run-setup
```

Make scripts executable:

```bash
chmod +x scripts/setup-ubuntu.sh scripts/rollback.sh tests/*.sh
```

Run a dry-run first:

```bash
sudo ./scripts/setup-ubuntu.sh --dry-run
```

Run an audit:

```bash
sudo ./scripts/setup-ubuntu.sh --audit
```

Start the interactive setup:

```bash
sudo ./scripts/setup-ubuntu.sh
```

Show help:

```bash
./scripts/setup-ubuntu.sh --help
```

---

## Dry-Run Mode

Dry-run mode shows what the script would do without applying changes.

```bash
sudo ./scripts/setup-ubuntu.sh --dry-run
```

Dry-run mode should not:

* install packages
* write configuration files
* write logs
* create backups
* create state files
* restart services
* modify firewall rules

It still goes through the interactive flow so you can review choices before running the live setup.

Expected final message:

```text
[INFO] Dry-run completed.
[INFO] No system, file, log, backup, or state changes were made.
```

---

## Audit / Check Mode

Audit mode inspects the current system and prints a readable status report.

```bash
sudo ./scripts/setup-ubuntu.sh --audit
```

or:

```bash
sudo ./scripts/setup-ubuntu.sh --check
```

Audit mode does not intentionally modify the system. It runs read-only inspection commands and reports areas such as:

* System information
* Pending package upgrades
* SSH configuration
* UFW firewall status
* fail2ban status
* unattended-upgrades status
* journald persistence
* swap status
* sysctl hardening file
* project-managed files
* latest backup/state information

Audit results are best-effort and depend on the commands available on the target system.

---

## SSH, UFW, and fail2ban Port Consistency

The script uses one canonical SSH port during a run.

* If SSH hardening is configured, that section sets the selected SSH port.
* If SSH hardening is skipped, the selected port defaults to `22`.
* UFW uses the same selected port before enabling the firewall.
* fail2ban writes the same selected port into its SSH jail.

The final summary reports whether SSH, UFW, and fail2ban used the same value.

This is mainly to reduce the chance of a common mistake: changing the SSH port but forgetting to allow the same port in the firewall.

---

## Rollback

Live setup creates backups for managed configuration files and records file actions in a manifest.

Manifest path:

```text
/var/backups/ubuntu-first-run-setup/YYYYMMDD-HHMMSS/manifest.tsv
```

Rollback example:

```bash
sudo ./scripts/rollback.sh /var/backups/ubuntu-first-run-setup/YYYYMMDD-HHMMSS
```

Before applying rollback, the rollback script creates a pre-rollback safety backup:

```text
/var/backups/ubuntu-first-run-setup/pre-rollback-YYYYMMDD-HHMMSS/
```

Rollback behavior:

* `modified`: restore the backed-up version
* `created`: remove the file created by setup
* `unchanged`: do nothing
* `skipped`: do nothing

Rollback validates SSH configuration with `sshd -t` before restarting SSH.

### Managed rollback targets

Rollback tracks these managed files when they appear in the manifest:

```text
/etc/ssh/sshd_config.d/99-first-run-hardening.conf
/etc/fail2ban/jail.d/sshd.local
/etc/apt/apt.conf.d/20auto-upgrades
/etc/sysctl.d/99-first-run-hardening.conf
/etc/systemd/journald.conf.d/99-first-run.conf
/etc/fstab
~/.ssh/authorized_keys
```

### Rollback limitations

Rollback only restores or removes managed files recorded in the manifest.

It does not:

* uninstall packages
* undo APT upgrades
* remove users created during setup
* undo password changes
* fully reverse UFW command history
* fully restore every possible system state

If `/etc/fstab` changed, a reboot or manual swap review may be needed.

---

## Files Managed

Depending on selected options, live setup may create or update:

```text
/etc/ssh/sshd_config.d/99-first-run-hardening.conf
/etc/fail2ban/jail.d/sshd.local
/etc/apt/apt.conf.d/20auto-upgrades
/etc/sysctl.d/99-first-run-hardening.conf
/etc/systemd/journald.conf.d/99-first-run.conf
/etc/fstab
~/.ssh/authorized_keys
```

Backup location:

```text
/var/backups/ubuntu-first-run-setup/
```

State location:

```text
/var/lib/ubuntu-first-run-setup/state/
```

Default live log:

```text
/var/log/ubuntu-first-run-setup.log
```

Dry-run and audit mode do not write backup, manifest, state, or log files.

---

## Known Risks

* SSH lockout if SSH or firewall settings are wrong
* Firewall rules may block application traffic if required ports are not allowed
* Rollback does not uninstall packages
* Rollback does not undo user creation
* Rollback does not undo APT upgrades
* Rollback does not fully reverse UFW command history
* Audit mode is best-effort
* This is not a CIS benchmark
* This is not a replacement for configuration management tools

---

## Example Workflows

### Remote VPS

```bash
sudo ./scripts/setup-ubuntu.sh --dry-run
sudo ./scripts/setup-ubuntu.sh --audit
sudo ./scripts/setup-ubuntu.sh
```

After changing SSH or firewall settings:

```bash
ssh -p <selected-port> user@server
sudo ./scripts/setup-ubuntu.sh --audit
```

Keep your current SSH session open until the second login works.

### Rollback

```bash
sudo ./scripts/rollback.sh /var/backups/ubuntu-first-run-setup/<backup-folder>
```

### Local checks

```bash
bash tests/smoke-test.sh
bash tests/help-audit-test.sh
```

---

## Testing

Run the smoke test:

```bash
bash tests/smoke-test.sh
```

The smoke test runs Bash syntax checks on shell scripts under `scripts/`, `tests/`, and optional `lib/`. If ShellCheck is installed, it runs ShellCheck too.

Run help/audit checks:

```bash
bash tests/help-audit-test.sh
```

The help/audit test checks `--help` output for setup and rollback. On Ubuntu, it may also run audit mode when the environment is suitable.

The full interactive dry-run flow is not fully automated because it depends on operator prompts.

---

## CI

The repository includes a GitHub Actions workflow:

```text
.github/workflows/shellcheck.yml
```

It runs on push and pull request using Ubuntu runners. The workflow performs Bash syntax checks, installs ShellCheck, runs ShellCheck, and executes the smoke test.

---

## Limitations

* No non-interactive config file mode yet
* No package uninstall rollback
* No full firewall rule transaction model
* No cloud provider metadata integration
* No CIS compliance claim
* No JSON audit output yet
* Rollback focuses on managed configuration files only

---

## Roadmap

Possible future improvements:

* non-interactive config file mode
* rollback dry-run mode
* Docker host profile
* Nginx or Caddy profile
* WireGuard profile
* audit JSON output
* CIS-inspired audit mode
* Persian language interface
* optional `lib/*.sh` modularization as the project grows

---

# فارسی

## راه‌اندازی اولیه Ubuntu

این پروژه یک اسکریپت Bash تعاملی برای آماده‌سازی اولیه Ubuntu بعد از نصب است.

بعد از نصب Ubuntu معمولاً چند کار تکراری انجام می‌شود: آپدیت سیستم، تنظیم SSH، فعال کردن firewall، راه‌اندازی fail2ban، فعال‌سازی آپدیت‌های امنیتی، تنظیم logging و انجام چند hardening پایه. این پروژه این مراحل را یک‌جا جمع می‌کند و قبل از تغییرات مهم از کاربر تأیید می‌گیرد.

هدف پروژه این نیست که جایگزین Ansible، cloud-init، Terraform، Puppet، Chef یا ابزارهای مدیریت پیکربندی شود. این ابزار برای راه‌اندازی اولیه‌ی ساده، قابل بررسی و نسبتاً امن طراحی شده است.

---

## قابلیت‌ها

* اجرای تعاملی مرحله‌به‌مرحله
* پروفایل‌های `server`، `developer workstation`، `desktop`، `minimal` و `custom`
* آپدیت و نصب پکیج‌های پایه
* تنظیم hostname، timezone و locale
* ساخت کنترل‌شده‌ی کاربر با دسترسی sudo
* نصب اختیاری SSH public key
* تنظیم امن SSH
* بررسی `sshd -t` قبل از restart کردن SSH
* هشدار برای جلوگیری از SSH lockout
* تنظیم UFW با policy پایه
* استفاده از یک SSH port مشترک برای SSH، UFW و fail2ban
* validation برای ruleهای اضافی UFW مثل `8080/tcp`
* تنظیم fail2ban برای SSH
* فعال‌سازی unattended security upgrades
* hardening پایه شبکه با sysctl
* فعال‌سازی persistent journald
* ساخت اختیاری swap file
* حالت dry-run
* حالت audit/check
* rollback بر اساس manifest
* backup قبل از rollback
* تست local
* GitHub Actions برای Bash syntax check و ShellCheck

---

## اجرای سریع

```bash
git clone https://github.com/Alizrr/ubuntu-first-run-setup.git
cd ubuntu-first-run-setup
chmod +x scripts/setup-ubuntu.sh scripts/rollback.sh tests/*.sh
```

اول dry-run بگیر:

```bash
sudo ./scripts/setup-ubuntu.sh --dry-run
```

بعد audit اجرا کن:

```bash
sudo ./scripts/setup-ubuntu.sh --audit
```

اجرای اصلی:

```bash
sudo ./scripts/setup-ubuntu.sh
```

---

## Dry-run چیست؟

در حالت dry-run، اسکریپت فقط نشان می‌دهد چه دستورها و تغییراتی قرار است انجام شوند، اما چیزی را روی سیستم اعمال نمی‌کند.

در این حالت نباید:

* پکیج نصب شود
* فایلی نوشته شود
* backup ساخته شود
* state file ساخته شود
* سرویس restart شود
* ruleهای firewall تغییر کنند

این حالت را قبل از اجرای واقعی، مخصوصاً روی سرور remote، اجرا کن.

---

## Audit چیست؟

حالت audit وضعیت فعلی سیستم را بررسی می‌کند و یک گزارش قابل خواندن نشان می‌دهد.

```bash
sudo ./scripts/setup-ubuntu.sh --audit
```

این حالت عمداً تغییری روی سیستم ایجاد نمی‌کند، اما از commandهای read-only برای بررسی وضعیت SSH، UFW، fail2ban، unattended-upgrades، journald، swap، sysctl و فایل‌های مدیریت‌شده استفاده می‌کند.

---

## Rollback

در اجرای live، اسکریپت برای فایل‌های مدیریت‌شده backup می‌سازد و تغییرات را در یک manifest ثبت می‌کند.

برای rollback:

```bash
sudo ./scripts/rollback.sh /var/backups/ubuntu-first-run-setup/<backup-folder>
```

Rollback می‌تواند فایل‌هایی را که تغییر کرده‌اند restore کند و فایل‌هایی را که توسط setup ساخته شده‌اند حذف کند.

محدودیت مهم: rollback فقط روی فایل‌های مدیریت‌شده کار می‌کند. پکیج‌ها را uninstall نمی‌کند، user ساخته‌شده را حذف نمی‌کند، apt upgrade را برنمی‌گرداند و history کامل UFW را undo نمی‌کند.

---

## هشدار امنیتی

این اسکریپت می‌تواند تنظیمات SSH و firewall را تغییر دهد. اگر پورت SSH اشتباه تنظیم شود، SSH key آماده نباشد یا firewall پورت لازم را باز نکند، ممکن است دسترسی به سرور از بین برود.

قبل از استفاده روی سرور واقعی:

1. روی VM یا VPS آزمایشی تست کن.
2. `--dry-run` اجرا کن.
3. `--audit` اجرا کن.
4. session فعلی SSH را باز نگه دار.
5. قبل از بستن session فعلی، یک login دوم را تست کن.

---

## تست‌ها

```bash
bash tests/smoke-test.sh
bash tests/help-audit-test.sh
```

اگر ShellCheck نصب باشد، smoke test آن را هم اجرا می‌کند.

---

## محدودیت‌ها

* هنوز config file mode غیرتعاملی ندارد
* rollback نصب پکیج‌ها را برنمی‌گرداند
* rollback ساخت user را undo نمی‌کند
* rollback تاریخچه کامل UFW را برنمی‌گرداند
* ادعای CIS compliance ندارد
* جایگزین ابزارهای configuration management نیست

---

## License

Released under the MIT License. See [LICENSE](LICENSE).
