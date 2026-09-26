# CLAUDE.md — e2e-pipeline

Shared CI for AEGIS projects. The first consumer is myGuardForce
(`AEGIS-Security-Investigations/license-verification`).

- **Consumers pin by SHA.** A change here reaches nobody until a consumer bumps
  its pin, so every behavior change needs a note in the PR on what consumers
  must do.
- **No app knowledge.** Nothing here may name a consumer's paths, secrets,
  labels, or services. Anything app-specific is an input or a command hook.
- **Cross-action calls go through `${{ github.action_path }}/../<action>/`.**
  Never `uses: ./…` (it resolves in the caller's workspace).
- **Keep the history.** Moved code keeps its `AEG-####` comments; they explain
  why each guard exists.
- Run `bun run test` and `bun run lint:shell` before pushing.
- Branch from `main` and open a draft PR. Titles start with the Linear ticket
  ID when there is one.
