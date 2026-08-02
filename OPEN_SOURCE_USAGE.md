# Open Source Usage

Track every direct dependency, Fork, vendored module, and copied source fragment used by this project.

## Dependency inventory

| Project/package | Version/commit | Official source | Purpose | Integration | License | Last verified |
|---|---|---|---|---|---|---|
| CodexBar / CodexBarCore / CodexBarCLI | `3f3e2f4a112aa504c493ad5636c94e45df85fd03` | https://github.com/steipete/CodexBar | Codex quota fetching, account identity, secure metadata store, and local token/cost estimates | SwiftPM revision pin plus a bundled local CLI helper; QuotaFloat owns the menu and account orchestration adapter | MIT | 2026-08-02 |

## Upgrade and replacement notes

- Upgrade in an isolated branch with `swift test` and `swift run QuotaFloat --self-test`; do not move the
  revision pin directly to current `main` because the upstream Core surface has changed substantially.
- Roll back by restoring the previous `Package.swift`/`Package.resolved` revision. QuotaFloat account homes
  remain app-owned and replaceable because orchestration is isolated in `CodexAccountManager.swift`.
## CodexBar helper

QuotaFloat reuses the MIT-licensed `CodexBarCore` package for Codex quota access and bundles the
`CodexBarCLI` executable as a local helper for device-side token and estimated cost summaries.
Both come from the pinned revision `3f3e2f4a112aa504c493ad5636c94e45df85fd03` of
https://github.com/steipete/CodexBar. The helper runs locally and its values are estimates derived
from local Codex session logs, not subscription billing records.
