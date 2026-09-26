# CLAUDE.md — e2e-pipeline

Shared CI for AEGIS projects. The first consumer is myGuardForce
(`AEGIS-Security-Investigations/license-verification`).

- **Consumers pin by SHA.** A change here reaches nobody until a consumer bumps
  its pin, so every behavior change needs a note in the PR on what consumers
  must do.
- **No app knowledge.** Nothing here may name a consumer's paths, secrets,
  labels, or services. Anything app-specific is an input or a command hook.
- **The caller picks the runner.** Composite actions never assume
  GitHub-hosted runners: probe for sudo/apt/tools instead of relying on
  `ubuntu-latest` image contents. Every reusable workflow takes a `runner`
  input (default `ubuntu-latest`) for each job, wired as
  `runs-on: ${{ startsWith(inputs.runner, '[') && fromJSON(inputs.runner) || inputs.runner }}`
  so it accepts a single label or a JSON array of labels. That lets a
  consumer choose Blacksmith (`blacksmith-4vcpu-ubuntu-2404`) or a self-hosted
  label set. The smoke tests run
  on both GitHub-hosted and Blacksmith runners.
- **Cross-action calls go through `${{ github.action_path }}/../<action>/`.**
  Never `uses: ./…` (it resolves in the caller's workspace).
- **Keep the history.** Moved code keeps its `AEG-####` comments; they explain
  why each guard exists.
- Run `bun run test` and `bun run lint:shell` before pushing.
- Branch from `main` and open a draft PR. Titles start with the Linear ticket
  ID when there is one.
