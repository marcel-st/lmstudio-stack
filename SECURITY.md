# Security Policy

## Scope

This project is a Docker Compose stack intended for local or private network use. It does not
include a reverse proxy or TLS by default. Do not expose ports 1234 or 4000 to the public internet
without placing an authenticated TLS-terminating proxy in front.

## Supported versions

Security fixes are applied to the `main` branch only.

## Reporting a vulnerability

Please do **not** open a public GitHub issue for security vulnerabilities.

Report privately via GitHub's [private vulnerability reporting](../../security/advisories/new) or
by emailing the maintainer directly (see git log for contact).

Include:
- Description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept
- Any suggested fix, if you have one

You can expect an acknowledgement within 5 business days.

## Keeping your deployment secure

- Rotate `LITELLM_MASTER_KEY` if it is ever exposed; note that rotating `LITELLM_SALT_KEY`
  **invalidates all existing virtual keys** and cannot be undone without re-issuing keys.
- The LM Studio API (port 1234) has no authentication. Bind it only to the Docker network —
  do not publish it externally.
- LiteLLM (port 4000) uses the master key for authentication. Use a strong, unique value.
