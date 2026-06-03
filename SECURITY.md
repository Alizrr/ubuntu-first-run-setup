# Security Policy

## Supported Versions

This project is early-stage. Security fixes are expected to target the current `main` branch unless release branches are introduced later.

## Reporting Security Issues

If you find a security issue, avoid publishing exploit details publicly before a fix is available. Report it to the project maintainer through the preferred private channel listed on the GitHub repository.

## Scope

Ubuntu First Run Setup provides baseline hardening and operational guardrails. It is not a complete compliance framework, not a CIS benchmark implementation, and not a replacement for a security review.

## Safety Guidance

Test the script in a VM or disposable VPS before running it on important systems. Pay particular attention to SSH, UFW, fail2ban, user creation, and rollback behavior.

The script attempts to reduce SSH lockout risk, but no automation can remove that risk entirely.
