<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/hero-light.svg">
  <img src="docs/assets/hero-dark.svg" width="1200" alt="TimbreDock — Bass. Harmonics. Space.">
</picture>

<p align="center">
  <strong>Shape your Mac's sound and listening space.</strong><br>
  Open-source macOS audio processing for the whole system or one app, with bass, harmonics and stereo space.
</p>

<p align="center">
  <a href="https://github.com/Gomtanga/timbredock/releases/tag/v0.3.0"><strong>Download the current stable version</strong></a> ·
  <a href="#features">Preview v0.4.0</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#documentation">Documentation</a>
</p>

<p align="center">
  <a href="https://github.com/Gomtanga/timbredock/releases/latest"><img src="https://img.shields.io/github/v/release/Gomtanga/timbredock?display_name=tag&amp;sort=semver&amp;color=111111" alt="Latest public release"></a>
  <a href="https://github.com/Gomtanga/timbredock/actions/workflows/macos-native-ci.yml"><img src="https://github.com/Gomtanga/timbredock/actions/workflows/macos-native-ci.yml/badge.svg" alt="macOS CI"></a>
  <a href="https://github.com/Gomtanga/timbredock/actions/workflows/cross-platform-core-ci.yml"><img src="https://github.com/Gomtanga/timbredock/actions/workflows/cross-platform-core-ci.yml/badge.svg" alt="Core CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--or--later-444444" alt="AGPL-3.0-or-later license"></a>
</p>

[한국어](README.md) · **English**

> **Release status** — v0.4.0 **TimbreDock** is a release candidate. The new interface and features below describe that candidate. The current public stable release is **LowEnd Native Audio v0.3.0**, under the earlier app name, and the download link still points to it. [Candidate results and remaining coverage (Korean)](docs/release-candidate-v0.4.0.md)

<a id="features"></a>

## Shape sound and space in one app

TimbreDock processes macOS audio before it reaches the selected output device. Use **System Audio** for most system sound or select one running app. Sound, Spatial and Output have independent settings, and effect values remain editable while processing.

<img src="docs/assets/v0.4.0-sound-en.png" width="1180" alt="TimbreDock v0.4.0 Sound page showing Bass Boost, three controls and presets.">

<p align="center"><sub>v0.4.0 Sound page · offline UI image captured without audio playback</sub></p>

| Page | What it does |
|---|---|
| **Sound** | Bass Boost controls bass amount and fullness; Treble Harmonics controls harmonic generation and the amount added. Off bypasses only the tone model. |
| **Spatial** | Move virtual speakers and the listener in planar or 3D views, then set the spatial amount. |
| **Signal Monitor** | See relative frequency content and Peak, RMS and Crest of the processed signal. These are not sound-pressure or true-peak measurements. |
| **Output** | Choose one of Standard, experimental PCM 2× Upsampling or experimental Match Source Sample Rate. |
| **Settings** | Choose English or Korean and inspect diagnostics. A saved language change takes effect after fully quitting and reopening the app. |

<img src="docs/assets/v0.4.0-spatial-en.png" width="1122" alt="Actual TimbreDock v0.4.0 Spatial 3D page showing left and right virtual speakers, the listener and spatial controls.">

<p align="center"><sub>Spatial 3D in the running release candidate · English interface</sub></p>

Spatial uses stereo distance, timing and crossfeed. It does not provide individualized HRTF rendering or room reverb. [Learn how to adjust it](docs/timbredock-v0.4.0-guide.en.md)

<a id="quick-start"></a>

## Download and quick start

| Version | App name | How to get it |
|---|---|---|
| **v0.3.0 · current public stable release** | LowEnd Native Audio | [Download the macOS ZIP from the release page](https://github.com/Gomtanga/timbredock/releases/tag/v0.3.0) · [Previous setup guide](docs/getting-started.en.md) |
| **v0.4.0 · release candidate** | TimbreDock | Not publicly released yet. [Candidate user guide](docs/timbredock-v0.4.0-guide.en.md) · [Build from source](docs/development.en.md) |

The distributed app targets **Apple Silicon Macs running macOS 14.4 or later**. No Intel Mac or Windows app is provided. Building the v0.4.0 source requires **Xcode 26 with the macOS 26 SDK or later**.

Once you have the v0.4.0 TimbreDock app:

1. Select the desired macOS output device and grant TimbreDock **system-audio recording** permission.
2. Select **System Audio** in the header, or use **Choose app…** to select a running application.
3. Open **Sound**, choose Bass Boost or Treble Harmonics, and start with modest settings.
4. Press **Apply**, then check the actual processing state and output device in the header. Apply again after changing the target app.
5. Press **Stop** before changing output devices or ending processing, and check that the device rate is restored.

Mac speakers, wired headphones and **Bluetooth wireless earbuds** can be selected as macOS outputs; an external DAC is optional. Wireless codecs, latency and supported sample rates vary by device, and not every device can run 2× output. The [candidate report (Korean)](docs/release-candidate-v0.4.0.md) identifies wireless-device testing that remains open for v0.4.0.

Run one copy of the app at a time. Exclusive-output modes in players can bypass the macOS processing path. The app is ad-hoc signed and is not notarized by Apple. If macOS blocks first launch, verify its source and follow the [setup guide](docs/getting-started.en.md).

## Understand the output and meters

```text
Playing app → macOS audio capture → Sound → Spatial → Output → selected device
                                                 └─ Signal Monitor
```

- Sound **Off** leaves Spatial and Output independent. For a dry comparison, turn Spatial off and choose Standard output.
- Treble Harmonics **Harmonic Oversampling** acts inside harmonic generation. Output **2× Upsampling** raises the output rate after tone and Spatial processing. They serve different purposes.
- **Upsampling Gain** attenuates the signal only when PCM 2× output is actually active. A saved value alone does not change the level, and this control is not a limiter.
- Signal Monitor observes audio after Sound, Spatial and Output, but before playback fade and device volume. Its values are not listening sound-pressure measurements.

The Treble processing band and strength curve are planned for improvement in **v0.4.1**. In v0.4.0, material with little high-frequency energy may produce only a subtle change. [Measurement and verification notes](docs/validation-v0.4.0-language-treble.md)

<a id="documentation"></a>

## Documentation and development

| Document | What you will find |
|---|---|
| [v0.4.0 user guide](docs/timbredock-v0.4.0-guide.en.md) | Five pages, presets, output modes, language changes and troubleshooting |
| [Release-candidate report (Korean)](docs/release-candidate-v0.4.0.md) | Hardware, UI and CI results, plus remaining verification |
| [v0.3.0 setup guide](docs/getting-started.en.md) | Installation and permissions for the current public stable release |
| [Development guide](docs/development.en.md) | Source builds, offline checks and the Swift/C++ architecture |
| [Contributing](CONTRIBUTING.md) | What to include in an issue or change proposal |

The macOS app runs on the Swift and C engine in `SystemAudioProcessor/`. `Source/Core/` contains a separately testable portable C++ DSP core; it does not imply a distributed Windows app. From the v0.4.0 source checkout, build the macOS app with the following command. See [Development](docs/development.en.md) for full requirements and verification commands.

```sh
./scripts/build-native-system-audio-app.sh
```

Report bugs and ideas through [GitHub Issues](https://github.com/Gomtanga/timbredock/issues). This project is released under [GNU AGPL-3.0-or-later](LICENSE). Its DSP is an original design, without manufacturer affiliation or claims of exact proprietary-circuit reproduction.
