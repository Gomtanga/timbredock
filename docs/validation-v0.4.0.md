# TimbreDock v0.4.0 validation record

Local implementation and Release app completed on 2026-09-21. Physical-device/release acceptance is still pending. Baseline `52f745421cf17e5f070c690263ec8d79f51ff3ae`; branch `codex/timbredock-redesign`, separate worktree `/Users/geon-yeong/opencode/timbredock-redesign`. This paragraph records the original local, uncommitted state on that date. The current committed candidate, hosted CI, device checks and repository cleanup are recorded in [the 2026-09-23 candidate report](release-candidate-v0.4.0.md).

## Liquid Glass UI follow-up

[2026-09-22 UI implementation and verification](liquid-glass-v0.4.0.md) supersedes the initial screenshots and layout. The earlier archive and source patch remain historical artifacts.

## Follow-up issue verification

The language and Treble Harmonics follow-up is recorded separately in [the issue report](validation-v0.4.0-language-treble.md). It supersedes the original localization count and manual-session scope below. Older preview screenshots and performance figures describe the first implementation, not a new run of every acceptance check.

## Completed checks

| Check | Result | Scope |
|---|---|---|
| Portable Core Debug and Release | 9/9 each | Existing tone, spatial, DSP and ring-buffer fixtures; Core sources unchanged |
| Native LowEndSupportChecks | Passed | Includes 16 source coordinator assertions |
| CaptureSessionLease process checks | 37 passed | Isolated real child processes and flock; no physical capture |
| Integrated native Debug and Release self-tests | Passed | DSP parity, analysis, output conditioning, rate tracking, manager responsiveness and capture lifecycle |
| Integrated capture session checks | 18 cases, 71 assertions | Actual SAP Start/Stop with isolated locks and simulated devices |
| Native CLI | 13 rejected cases and help passed | Exact packaged executable; no real capture |
| Localization | 459 en/ko keys passed | Four tables, key parity, format arguments, literal source-key coverage and actual bundle loading |
| New whole-window UI checks | 151 assertions | Five pages, 940×640 minimum window, duplicate app names, draft/active target, Advanced and next-launch language |
| Output UI checks | 70 assertions | Exclusive modes, unsupported controls absent, saved/active/failure state, gain explanation, migration dismissal and scroll layout |
| Live control editing | 69 assertions | Actual output samples for gain 0/−6/−12/0 dB; no device recreation for active gain; simulated hardware |
| Async GUI lifecycle | 13 cases, 111 assertions | Pending edits, main-loop responsiveness, duplicate Apply, Stop/Quit ownership, failed cleanup/retry, stale notifications and worker retirement |
| English and Korean Release UI self-tests | Passed | Actual AppKit/SwiftUI controls with isolated preferences; no physical audio session |
| Spatial UI | Passed | Coordinates, keyboard actions, AX proxies, coalescing, resize and rendering policy; does not replace manual VoiceOver |
| Integrated analysis performance | Debug p95 11.817 ms; Release p95 0.534 ms, max 0.572 ms | Fixture worker ticks across 44.1–768 kHz on Apple M5; not callback or end-to-end latency |
| Metal frame ownership | Passed | 36 delayed GPU commands, 1,200 skipped acquisitions, no resource mismatches; actual Metal on Apple M5 |
| Staged bundle failure/replacement tests | Passed | Missing resources preserve the old app; Swift/signing mocked in these fault fixtures |
| Actual Release bundle | Passed | TimbreDock 0.4.0, arm64, unchanged bundle ID, all locale tables, strict codesign verification; ad-hoc signature |
| Extracted preview ZIP | Passed | Strict signature verification of the extracted app and exact executable match |
| Review patch | Passed | All changed/new files apply to the clean baseline and match SHA-256 hashes |
| Documentation links | 75 local targets resolved | Includes actual screenshots in both language guides |
| Manual GUI | Partial acceptance completed | All five pages visually inspected; English→Korean applies on relaunch; original language/Advanced preference restored; no real capture started |

The analysis fixtures include .5-amplitude stereo and one-channel sine, antiphase, square, silence, exact 300 ms transient expiry, sparse quiet crest, chunk partitions, coherent/off-bin FFT, 249/250 ms stale boundary, nonfinite input, drop/backlog discard, rate change and Stop. Peak/RMS/Crest share the same trailing stereo window. The isolated exact-source harness also passed; the integrated checks above validate the final analysis in the app.

Two independent review findings were fixed: output status/gain notes now follow asynchronous lifecycle changes with pending/failure precedence, and duplicate app names retain the correct bundle-ID mapping. Additional fixtures cover these regressions.

## Delivered local artifacts

- `build/LowEndCircuit_artefacts/Release/NativeSystemAudio/TimbreDock.app`
- `build/redesign-evidence/TimbreDock-v0.4.0-macOS-arm64-preview.zip`
- `build/redesign-evidence/`: build/test logs, actual screenshots, source/archive hashes, source patch and branch backup. This directory is ignored by Git.
- [Korean guide](timbredock-v0.4.0-guide.md) and [English guide](timbredock-v0.4.0-guide.en.md) contain actual app screenshots, explicitly showing processing stopped.

The package is a local ad-hoc-signed preview, not a notarized/public release. Its build metadata records the baseline hash, dirty state and build timestamp. New/untracked source files are included in the private review patch.

## Remaining release acceptance

- Actual listening on the new app, long-running processing and wireless route/device changes.
- Physical supported DAC: 2× transition, gain 0/−6/−12/0 dB, original-rate restoration and failure recovery.
- Manual VoiceOver, full keyboard flow, visual 1×/2× display-scale checks, older supported macOS and upgrade permission behavior. Minimum window geometry and Spatial keyboard/AX fixtures passed; these do not replace those manual checks.
- Hosted CI, public release archive, repository rename/redirects and remote branch cleanup.

The default output observed during UI inspection was Galaxy Buds2 at 44.1 kHz. No Fosi DAC was reported by the inventory. Actual processing was not started and device rates were not changed. Previous v0.3.0 listening confirmation does not validate v0.4.0.

## Preservation and publication

The original dirty audit checkout, v0.3.0 release worktree/assets, Windows branches and local stash remain intact. All nine recorded remote tips are included in a verified private Git bundle. No commit, push, public PR, repository rename or remote branch deletion was performed. Those release operations remain gated by the outstanding acceptance checks. See [branch cleanup plan](branch-cleanup-v0.4.0.md).
