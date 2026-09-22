# v0.2.3 to v0.3.0 Roadmap

> Historical design: this document records an earlier migration plan. Current v0.4.0 work is tracked in [the redesign plan](redesign-v0.4.0.md). The released app is macOS; Windows exploration continues separately on its existing branches.


## v0.2.3 Stabilization

- Keep the macOS Native Swift DSP as the default sound path.
- Ship diagnostic counters for output underruns, output/analysis drops, engine
  restarts, and resolved per-app capture targets.
- Run Swift checks, portable Core tests, and Native Debug/Release builds in CI.
- Validate device and sample-rate transitions on real hardware before release.

## v0.3.0 Beta

- Compare impulse, sine, and deterministic noise fixtures between the
  established Swift implementation and portable Core.
- Record output delta, CPU use, crest factor, and HighExciter alias energy.

## v0.3.0

- Make portable Core the default only after numeric and listening acceptance.
- Keep Spatial Stage and analysis platform-native until equivalent portable
  implementations and tests exist.
