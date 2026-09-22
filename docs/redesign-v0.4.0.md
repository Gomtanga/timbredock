# TimbreDock v0.4.0 redesign

Status: implementation, candidate packaging and repository cleanup completed; remaining acceptance coverage is recorded explicitly before release. Baseline: `52f745421cf17e5f070c690263ec8d79f51ff3ae`.
This document describes the approved redesign. See [the current candidate report](release-candidate-v0.4.0.md) for device/CI/artifact results and remaining coverage; the [initial validation record](validation-v0.4.0.md) is historical.

## 2026-09-22 UI scope extension

The user requested a black/white Liquid Glass redesign and contextual help instead of static instructional paragraphs. See [the UI implementation record](liquid-glass-v0.4.0.md). Audio behavior remains unchanged; Treble algorithm improvements stay in the v0.4.1 plan.

## Product decisions

- Project/app: TimbreDock. Proposed repository rename: Gomtanga/timbredock, preserving the existing repository, releases and pull requests.
- English is the default regardless of OS language. Korean remains selectable; a language change takes effect on next launch without automatically restarting audio.
- Sound models: Off / Bass Boost / Treble Harmonics. Keep internal clean/circuit/highexciter IDs, parameter values, CLI options, and DSP algorithms.
- Bass controls: Bass Amount / Bass Fullness / Output Trim. Treble controls: Harmonic Drive / Added Harmonics. Treble is additive, not a dry/wet crossfade.
- Pages: Sound / Spatial / Signal Monitor / Output / Settings. Put target selection, Apply, Stop, actual processing status and current output device in a common header.
- New installations default to System Audio. App selection uses an app name/icon picker; bundle ID input is advanced.
- Effects remain editable during processing. Target edits become active only when applied. Start/stop ownership and restoration failure behavior must remain intact.
- Advanced disclosure only changes presentation, never the active audio settings.

## Output

Expose one mutually exclusive Output Rate Mode: Standard (default), 2x Upsampling (Experimental), Match Source Sample Rate (Experimental).
Live 2x is limited to supported devices with tap rates 44.1/48 kHz and target rates 88.2/96 kHz.
Show requested versus actual behavior and a specific unavailable/restoration failure reason.
Keep Short/Long filters; Upsampling Gain is -12...0 dB, default -3 dB. Gain edits on an active 2x path must not restart or renegotiate the device.
Gain may be saved while 2x is selected but inactive, explicitly labeled as not currently applied.
Remove selectable 4x/8x, minimum phase, dither/noise shaping and DSD/DoP from the product UI. Diagnostics may describe their implementation status read-only.
Migrate legacy minimum phase to Short (its existing effective algorithm). Migrate unsupported saved output modes/factors to Standard with a one-time notice. Valid saved 2x takes precedence over a simultaneous automatic-rate flag, matching the current engine.
Do not promise improved sound, bit-perfect playback, hearing safety, or limiting. A sample-peak full-scale indication is not true-peak detection.

## Signal Monitor contract

- Measurement point: after Tone, Spatial, Output; before playback fade and device volume.
- Stereo spectrum: separate L/R FFT, average bin power. Never downmix L+R before FFT.
- 16,384-point Hann FFT, 128 logarithmic bands from 20 Hz to min(20 kHz, Fs/2).
- Correct real-FFT/Hann coherent gain using the actual window sum. Exclude packed DC/Nyquist from ordinary bins.
- Each bar takes the maximum spectral power among enclosed bins and interpolated band edges; not one center-bin sample and not total band energy.
- Fixed relative display range -96...0, no automatic normalization. State that this is relative frequency content, not loudness.
- Mark frequencies outside the available FFT resolution. Tick labels 20/100/1k/10k/20k when in range; Bass/Midrange/Treble boundaries 250 Hz/4 kHz are explanatory categories.
- Peak/RMS/Crest all use the same trailing 300 ms stereo window. Peak=max(abs(L),abs(R)); per-frame energy=(L*L+R*R)/2; RMS=sqrt(mean energy); Crest=peak dBFS-RMS dBFS.
- Process all chunks. Numerical values have no independent release smoothing. Units: Peak/RMS dBFS, Crest dB; full-scale sine RMS=-3.01 dBFS.
- Silence below 1e-5 amplitude: < -100 dBFS, Crest unavailable. No new frames for 250 ms: Waiting for audio, clear stale graphs/numbers. Use a monotonic clock.
- Start/rate/discard/drop/nonfinite input resets measurement history. Show Measuring until each window is ready. Stop invalidates pending publications and clears the display.
- Analysis worker owns buffers and FFT. Preallocate outside ticks. No new callback allocation, locks, UI or FFT.
- Maximum 30 Hz FFT, 15 Hz meter publication. Time-based bar smoothing, zero-height silence bars, fit all bars inside narrow drawables.

## Compatibility and packaging

Preserve bundle identifier com.codexaudiolab.lowendcircuit.systemaudio, capture lease metadata and directory, internal package/library names and CLI options.
Rename the visible app bundle/launcher to TimbreDock; update staged build checks and signed-bundle verification accordingly.
Keep the v0.3.0 release/tag/assets and existing download URLs until a new release artifact is verified.
No assertion that a stable bundle ID guarantees macOS TCC permission continuity; test the upgrade.

## Branch cleanup after validation

Preserve main, feature/windows-port (PR24), feature/windows-virtual-routing (PR25).
Record current tips and verify a private git bundle before deletion of other remote refs.
Merged/equivalent candidates: codex/readme-redesign, codex/release-v0.3.0, docs/bilingual-readme-refresh.
Superseded candidates: fix/rate-match-polling-and-deadlock (PR11), feature/rate-match-as-expert-option (PR12). Document coverage and close, do not blindly merge old code.
Preserve unique historical planning from spike/cross-platform-core before deleting its remote ref.
Keep existing dirty audit worktrees, release worktree, local Windows work and stash untouched.

## Acceptance

- Existing audible DSP fixture results remain unchanged. Model/preset migration preserves numeric settings.
- Both locales, 940x640 minimum window, 1x/2x scale, keyboard and VoiceOver flows.
- Amplitude .5 stereo sine: peak -6.0206, RMS -9.0309, crest 3.0103 dB (0.02 dB tolerance). L-only, square, silence, antiphase, chunk-split and first-chunk transient fixtures.
- FFT coherent-gain, off-bin tones, logarithmic axes, 44.1/48/96/192/384/768 kHz, stale/reset/drop behavior.
- Native support, capture lease process tests, Debug/Release self-tests, CLI checks, staged signed bundle checks; portable C++ Debug/Release tests and hosted CI.
- Actual device: 2x transition, gain 0/-6/-12/0 dB, original-rate restoration, unsupported device and recovery behavior. Historic listening approval is not a new-build test.
- Worker tick p95 target below 20 ms at 30 Hz without sustained backlog; if needed reduce FFT cadence to 15 Hz, retaining all meter samples and completing within the new cadence.
- Final app/archive, localization resources, documentation images/links and renamed repository redirects verified before release completion.

## Follow-up, not v0.4.0 promises

Prioritize device coverage and additional metering needs. Real minimum-phase filtering or live 4x/8x requires measured latency/CPU/filter/device validation. Integer-output dither and transparent DoP transport require separate designs. Windows work stays on its existing branches. File conversion and AI/stem ideas remain separate research.
