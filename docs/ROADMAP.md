# Roadmap

Order matters: each step is proven in myGuardForce before the next moves, and
myGuardForce keeps a working local copy until it has run on the shared one.

1. **Hardening actions** *(this PR)*: `apt-hardening`, `playwright-install`.
   myGuardForce switches its callers in a follow-up PR and deletes its copies.
2. **Separate the engine from the app inside myGuardForce** (no move yet). Remove
   the `@/` imports from `scripts/e2e`, and move app bootstrap steps (codegen,
   docker-compose services, Inngest, seed, build, start) behind `e2e:ci:*`
   scripts, so the workflow only calls commands.
3. **Reporting**: S3 blob upload, merge to HTML/JSON, duration metrics,
   PR comment, fallback-DB-timeout rerun. Reusable workflow
   `.github/workflows/playwright-report.yml`.
4. **Selection and sharding**: `determine-e2e-run`, tag-taxonomy selection,
   `plan-playwright-shards`, flaky-first. Test history comes from a pluggable
   provider; myGuardForce keeps its current API until the reporting API below
   exists.
5. **Shard runner + Neon database per shard**: reusable
   `.github/workflows/playwright-e2e.yml` with command hooks (`setup-command`,
   `migrate-command`, `seed-command`, `build-command`, `start-command`,
   `ready-url`).
6. **Lanes** (N app copies per runner) last. They're the most tuned to
   myGuardForce.
7. **Pilot on a second project**, then tag `v1`.

## Runner selection (applies to every step)

Every job in a reusable workflow takes its runner from an input, defaulting to
`ubuntu-latest`. myGuardForce passes its current Blacksmith sizes (for example
`blacksmith-2vcpu-ubuntu-2404` for light jobs, and a lane runner such as
`blacksmith-32vcpu-ubuntu-2404` driven by its `E2E_LANE_RUNNER` variable). Jobs
with different sizing needs get separate inputs (`runner`, `shard-runner`,
`lane-runner`) rather than one shared value. Nothing Blacksmith-specific
(its cache or Docker layer features) may be required. Use it only when it's
detected, with a plain fallback.

## Deferred

- **Report and analytics API** (upload runs, durations, flaky specs) to replace
  myGuardForce's `E2eTestRun` / `E2eTestResult` tables. It lives in this repo
  or TaskVoice, to be decided later.
