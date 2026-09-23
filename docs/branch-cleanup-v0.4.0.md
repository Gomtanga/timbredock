# Branch cleanup for v0.4.0

Status: completed 2026-09-23. Historical snapshot date: 2026-09-21. Repository renamed to `Gomtanga/timbredock` (old `Gomtanga/lowend-circuit` API URLs redirect).

A verified private Git bundle retains the nine remote tips below, including full ancestry. Original worktrees, Windows local work and stash remain outside cleanup scope.

## Historical snapshot (2026-09-21)

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

The unique spike planning commit is `589a576507c19738a647d9979f2caa27f5d03c2b`. Its historical roadmap is archived with its full ancestry; it does not define current product support.

## Completion record (2026-09-23)

Six snapshot candidates were deleted from the remote atomically with an exact-SHA `--force-with-lease` per ref. Every live tip matched its snapshot SHA before deletion, so no divergent work was discarded:

- `codex/readme-redesign` — `959d6b2de494943fe586207d22b06b91f3c1a5ef`
- `codex/release-v0.3.0` — `1da18de06633b23aeffec6fe26caa69946ac1556`
- `docs/bilingual-readme-refresh` — `16782429b06fc8c626be386a51c5b150b6417c6e`
- `feature/rate-match-as-expert-option` — `faa25988797cfdf22d8d228a493e1b4510e457d4`
- `fix/rate-match-polling-and-deadlock` — `3c83129b5949e2844e0f1d8af4b50ce8bd141400`
- `spike/cross-platform-core` — `589a576507c19738a647d9979f2caa27f5d03c2b`

Obsolete pull requests were closed as superseded: PR #11 and PR #12. Windows PR #24 and PR #25 were preserved unchanged and are still open with their branches intact.

Remaining remote refs after cleanup:

| Ref | State |
|---|---|
| `main` | `52f745421cf17e5f070c690263ec8d79f51ff3ae` |
| `feature/windows-port` | original SHA `400fa2574472907294b834a97a0985e6cb0f5568`; PR #24 open |
| `feature/windows-virtual-routing` | original SHA `cacb7b0aa43d073a4641b2e079f5772d29279af5`; PR #25 open |
| `codex/timbredock-redesign` | active redesign work; draft PR #26 open, unmerged |

## Evidence retained

- `build/redesign-evidence/remote-branches-before.bundle` — Git bundle of all nine pre-cleanup tips (`bundle verify` reports a complete history; SHA-1 object format). Also `remote-branches-before.json` and `bundle-verify.txt`.
- `build/redesign-evidence/spike-historical-plans/` — archived planning material for the spike commit.
- v0.3.0 published release asset re-downloaded: SHA-256 `ef78da0e69c7a8558fd4e767322bad5571c9de6a81285ac8a559c40c792b6c43`, matching the published checksums. The v0.3.0 tag and its assets are unchanged by this cleanup.
- v0.4.0 candidate draft PR #26 is unmerged; no tag or release was created by cleanup.
