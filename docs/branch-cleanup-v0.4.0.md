# Branch cleanup for v0.4.0

Status: prepared; no remote branches deleted. Snapshot date: 2026-09-21.

A verified private Git bundle contains the nine remote tips below. Original worktrees, Windows local work and stash are outside cleanup scope.

| Branch | Snapshot SHA | Disposition |
|---|---|---|
| `codex/readme-redesign` | `959d6b2de494943fe586207d22b06b91f3c1a5ef` | Ancestor of main; remove remote ref after validation |
| `codex/release-v0.3.0` | `1da18de06633b23aeffec6fe26caa69946ac1556` | Ancestor of main; keep tag/assets/local release worktree |
| `docs/bilingual-readme-refresh` | `16782429b06fc8c626be386a51c5b150b6417c6e` | Patch-equivalent squash; remove remote ref after validation |
| `feature/rate-match-as-expert-option` | `faa25988797cfdf22d8d228a493e1b4510e457d4` | Review rate/UI policy and close PR #12 before deletion |
| `feature/windows-port` | `400fa2574472907294b834a97a0985e6cb0f5568` | Keep; PR #24 |
| `feature/windows-virtual-routing` | `cacb7b0aa43d073a4641b2e079f5772d29279af5` | Keep; PR #25 |
| `fix/rate-match-polling-and-deadlock` | `3c83129b5949e2844e0f1d8af4b50ce8bd141400` | Review superseding tracker/bench and close PR #11 before deletion |
| `main` | `52f745421cf17e5f070c690263ec8d79f51ff3ae` | Keep |
| `spike/cross-platform-core` | `589a576507c19738a647d9979f2caa27f5d03c2b` | First three commits patch-equivalent; preserve unique historical planning commit |

## Superseded work

PR #11 separates sample-rate listener work and adds a rate bench. Current HardwareSampleRateTracker already separates listener work and serializes confirmation; its stale/race protections are newer. Current RateMatchBench defaults to dry-run, requires explicit device/execute for changes, and restores the original rate. Do not merge the old branch wholesale.

PR #12 couples automatic rate matching to an expert-mode checkbox. The redesigned UI exposes a mutually exclusive output-rate mode and keeps Advanced disclosure independent of behavior. Preserve automatic matching itself, not the old display/behavior coupling.

The unique spike planning commit is `589a576507c19738a647d9979f2caa27f5d03c2b`. Its historical roadmap is archived with its full ancestry; it does not define current product support.

## Execution gates

1. Re-read each remote tip and abort its deletion if it changed from the snapshot.
2. Keep both Windows branches and their pull requests open.
3. Record validation and supersession links before closing obsolete pull requests.
4. Delete only the six named cleanup candidates; keep main and active redesign work.
5. Verify remaining remote refs and accessible v0.3.0 release assets.
