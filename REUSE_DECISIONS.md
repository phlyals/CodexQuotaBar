# Reuse Decisions

Record dated evidence for reuse, adaptation, rejection, and build-from-scratch decisions.

## 2026-08-02 — Initial record

- Requirement and constraints: keep the existing native macOS quota viewer, make it Codex-only, and switch
  displayed quota together with the actual file-backed Codex Desktop/CLI system account.
- Search sources and queries: local SwiftPM inventory; CodexBar source/releases; official Codex authentication
  manual; GitHub checks for `codex-profiles` and `codex-switcher`.
- Candidates and versions: existing CodexBarCore pin `3f3e2f4`; CodexBar upstream `41bc014` checked on
  2026-08-02; codex-profiles; codex-switcher.
- Validation commands and results: latest upstream promotion planning/execution/service tests passed 35/35 in
  an isolated clone; QuotaFloat uses `swift test`, `swift run QuotaFloat --self-test`, and packaged-app checks.
- Selected strategy: keep the current Core pin, build a QuotaFloat-owned thin adapter, and bundle the pinned
  `CodexBarCLI` executable only as a local usage-scanning helper; do not embed or run the full CodexBar app.
- Reused components: `UsageFetcher`, `CodexHomeScope`, `CodexAuthFingerprint`, account identity and
  `FileManagedCodexAccountStore`.
- Custom components: Codex login runner, QuotaFloat-specific home paths, safe live-account preservation,
  atomic system auth replacement, dashboard UI, helper JSON adapter, quota refresh and optional Codex restart
  prompt.
- Reasons other candidates were rejected: codex-profiles cannot switch an already open Desktop window;
  codex-switcher adds Bun and a duplicate account registry; full CodexBar application reuse is too broad.
- License and security conclusion: MIT-compatible; upstream license retained. Auth files use `0600`, managed
  directories use `0700`, tokens are not logged, keyring-only mode fails closed, and real credentials are not
  used in automated tests.
- Unverified items: OpenAI does not document hot reload of externally replaced auth for an already-running
  Codex Desktop process, so the app offers an explicit restart instead of claiming live reload.
- Reassessment triggers: Codex changes credential format/storage defaults, CodexBar exports promotion as a
  library API, or upstream account tests fail after a dependency update.

## 2026-08-03 — Reliable Codex desktop restart

- Requirement and constraints: after switching the live Codex account, reliably close and reopen the macOS
  Codex desktop app without adding a runtime or third-party dependency.
- Search sources and queries: existing restart implementation; local macOS SDK headers for
  `NSRunningApplication.terminate`, `isTerminated`, `forceTerminate`, and
  `NSWorkspace.OpenConfiguration.createsNewApplicationInstance`.
- Candidates: extend the existing AppKit APIs; invoke `/usr/bin/open`; launch the app executable directly.
- Validation: local SDK documentation confirms termination is asynchronous and must be observed; four fake
  process tests cover slow exit, forced exit, terminal timeout, and launch failure.
- Selected strategy: reuse AppKit, wait up to 10 seconds for normal exit, force termination only after the
  user-approved warning, wait another 5 seconds, then request a new non-substituted application instance.
- Rejected alternatives: `/usr/bin/open` provides weaker typed error handling; direct executable launch
  bypasses LaunchServices application semantics.
- License and security conclusion: Apple system frameworks only; no new dependency, license notice, network
  permission, credential access, or data collection.
- Reassessment triggers: the Codex bundle identifier changes or macOS changes LaunchServices restart
  behavior.
