# Contributing

Contributions are welcome — bug reports, fixes, and improvements to the Docker stack or
documentation are all useful.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml). Include:
- Host OS and NVIDIA driver version (`nvidia-smi`)
- Docker and Docker Compose versions
- Relevant `docker compose logs` output
- Steps to reproduce

## Suggesting changes

Open a [feature request](.github/ISSUE_TEMPLATE/feature_request.yml) before implementing
non-trivial changes, so the approach can be agreed on first.

## Pull requests

1. Fork the repo and create a branch from `main`
2. Test your changes on a working stack (`docker compose up -d`, run the verification commands from
   the README)
3. Keep the diff focused — one concern per PR
4. Update `README.md` if your change affects setup or usage

## Secrets and credentials

Never commit `.env` files, keys, or passwords. The `.gitignore` blocks `.env`, but double-check
`git status` before pushing.
