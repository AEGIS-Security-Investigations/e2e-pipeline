# e2e-pipeline

Shared Playwright E2E pipeline for AEGIS projects: composite actions, reusable
workflows and reporting, extracted from myGuardForce
(`AEGIS-Security-Investigations/license-verification`) so other projects can
use it.

## Using an action

Reference it by path and pin a commit SHA (keep the tag in a comment):

```yaml
- uses: AEGIS-Security-Investigations/e2e-pipeline/actions/playwright-install@<sha> # v0.1.0
  with:
    browsers: chromium
```

This repo is private, so it must have **Settings → Actions → General → Access**
set to "Accessible from repositories in the organization" for other repos to
call it.

## What's here

| Path | What it does |
|---|---|
| `actions/apt-hardening` | Makes apt survive an Ubuntu mirror mid-sync (config in `/etc/apt/apt.conf.d`, retried `apt-get update` for transient failures only). No-op without root. |
| `actions/playwright-install` | Installs Playwright browsers with apt hardening, bounded retries, a cache short-circuit, and a verified no-deps fallback. Needs Bun and a `playwright` package in the caller's workspace. |

## Roadmap

See [docs/ROADMAP.md](docs/ROADMAP.md) for what moves next and in what order.

## Developing

```bash
bun install
bun run test         # unit tests for the action scripts
bun run lint:shell   # shellcheck
```

Actions inside this repo call each other's scripts through
`${{ github.action_path }}/../<action>/…` rather than `uses: ./…`: a relative
`uses:` resolves against the **caller's** workspace, not this repo.
