<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/hero-light.svg">
  <img src="docs/assets/hero-dark.svg" width="1200" alt="TimbreDock — Bass. Harmonics. Space.">
</picture>

<p align="center">
  <strong>Mac의 소리에 저역의 무게, 고역의 질감, 헤드폰의 공간감을 더하세요.</strong><br>
  전체 시스템 또는 선택한 앱의 오디오를 실시간으로 처리하는 오픈소스 DSP.
</p>

<p align="center">
  <a href="https://github.com/Gomtanga/timbredock/releases/download/v0.3.0/LowEnd-Native-Audio-macOS-v0.3.0.zip"><strong>macOS용 다운로드 ↗</strong></a> ·
  <a href="#quick-start">빠른 시작</a> ·
  <a href="#documentation">문서</a> ·
  <a href="https://github.com/Gomtanga/timbredock/releases/tag/v0.3.0">v0.3.0 릴리스 노트</a>
</p>

[![Release](https://img.shields.io/github/v/release/Gomtanga/timbredock?display_name=tag&sort=semver&color=c68b32)](https://github.com/Gomtanga/timbredock/releases/latest)
[![macOS CI](https://github.com/Gomtanga/timbredock/actions/workflows/macos-native-ci.yml/badge.svg)](https://github.com/Gomtanga/timbredock/actions/workflows/macos-native-ci.yml)
[![Core CI](https://github.com/Gomtanga/timbredock/actions/workflows/cross-platform-core-ci.yml/badge.svg)](https://github.com/Gomtanga/timbredock/actions/workflows/cross-platform-core-ci.yml)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-486b87)](LICENSE)

**한국어** · [English](README.en.md)

> **TimbreDock v0.4.0 개발 중** — LowEnd Circuit의 새 이름입니다. 이 브랜치에서 UI·영어/한국어·신호 분석을 개편하고 있습니다. 아래 다운로드와 기존 화면은 안정 버전 v0.3.0을 기준으로 합니다. [개편 내용과 검증 기준](docs/redesign-v0.4.0.md) · [v0.4.0 guide](docs/timbredock-v0.4.0-guide.md) · [새 소스 빌드](docs/development.md)

## 내 취향에 맞게, 듣는 공간까지

**LowEnd Circuit**의 macOS 앱 **LowEnd Native Audio**는 음악, 브라우저, 게임의 소리를 현재 출력 장치로 전달하기 전에 조절합니다. 저역을 다듬고, 배음을 더하고, 가상 스피커와 청취자의 위치로 헤드폰의 공간감을 바꿔 보세요.

유선 헤드폰뿐 아니라 **Bluetooth 무선 이어폰**에서도 사용할 수 있습니다. 무선 이어폰을 Mac에 연결하고 macOS의 출력 장치로 선택한 뒤, 전체 시스템 또는 특정 앱에 오디오 처리를 적용하세요.

<img src="docs/assets/spatial-stage.png" width="1224" alt="LowEnd Native Audio의 실제 Spatial Stage 화면. 3D 공간에 좌우 가상 스피커와 청취자가 표시되고, 오른쪽에서 위치와 공간 처리 값을 조절합니다.">

<p align="center"><sub>Spatial Stage · 가상 스피커와 청취자 위치를 직접 조절하는 실제 앱 화면</sub></p>

| 저역과 질감 | 공간과 신호 확인 |
|---|---|
| **Circuit** — LowEnd와 Body로 저역의 양감과 포화 질감을 조절합니다. | **Spatial Stage** — 스피커 폭, 청취자 위치, 거리 게인과 크로스피드로 공간감을 조절합니다. |
| **HighExciter** — 고역 성분에서 배음을 만들어 섬세하게 더합니다. 비선형 구간에 자체 오버샘플링을 적용합니다. | **Analysis** — 실시간 스펙트럼, Peak, RMS, Crest Factor로 신호를 확인합니다. |

Spatial Stage는 기하학 기반의 스테레오 공간 처리입니다. 개인화 HRTF나 방 리버브는 제공하지 않습니다.

### 몇 가지 조절로 만드는 나만의 소리

Circuit의 **IEM · Gentle · LowEnd · Deep · Clear**, HighExciter의 **Soft · Air · Detail · Shimmer · Off** 프리셋으로 시작해 세부 값을 조절하세요. 프리셋마다 음량이 다를 수 있으므로 비교할 때는 출력 레벨도 함께 확인하세요.

<img src="docs/assets/circuit.png" width="1080" alt="LowEnd Native Audio의 실제 Circuit 화면. LowEnd, Body, Output 슬라이더와 IEM, Gentle, LowEnd, Deep, Clear 프리셋이 있습니다.">

<p align="center"><sub>Circuit · 모델 선택, 저역 조절, 프리셋을 한 화면에서</sub></p>

<a id="quick-start"></a>

## 다운로드하고 시작하기

| 지원 환경 | 배포 앱 |
|---|---|
| **macOS 14.4 이상 · Apple Silicon** | [LowEnd Native Audio v0.3.0 ZIP 다운로드](https://github.com/Gomtanga/timbredock/releases/download/v0.3.0/LowEnd-Native-Audio-macOS-v0.3.0.zip) |

1. ZIP을 풀고 **LowEnd Native Audio.app**을 **응용 프로그램** 폴더로 옮깁니다.
2. 앱을 실행하고 macOS의 **시스템 오디오 녹음 권한**을 허용합니다.
3. **Circuit → IEM 또는 Gentle**, **HighExciter → Soft 또는 Air**로 시작합니다.
4. **왼쪽 아래 스피커 버튼**(전체 시스템 적용)을 누르고 음악을 재생합니다.

앱은 **애드혹 서명 상태이며 Apple 공증을 받지 않았습니다**. 첫 실행이 차단되면 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**에서 허용하세요. 자세한 안내와 특정 앱 처리 방법은 [설치와 사용 시작](docs/getting-started.md)에 있습니다.

**앱은 하나만 실행하세요.** TIDAL 등의 독점 출력 모드는 끄고, 출력 장치를 바꾸기 전에는 **중지**를 누르세요.

<a id="faq"></a>

## 사용하면서 궁금한 점

<details>
<summary><strong>HighExciter 오버샘플링과 PCM Oversampling 2×는 같은 기능인가요?</strong></summary>

적용 위치가 다릅니다. HighExciter는 배음을 만드는 비선형 구간 내부에서 오버샘플링하고 원래 처리 샘플레이트로 돌아옵니다. 출력 컨디셔닝의 PCM 2×는 톤 모델과 Spatial 처리 이후 출력 샘플레이트를 높입니다. 함께 사용할 수 있으며, 장치가 지원하면 44.1 → 88.2 kHz 또는 48 → 96 kHz로 출력합니다.

</details>

<details>
<summary><strong>헤드룸을 바꿔도 음량이 같아요. 외장 DAC가 필요한가요?</strong></summary>

헤드룸은 **PCM 2×가 실제로 활성화된 상태**에서만 반영됩니다. 설정값과 실제 활성 상태를 구분해 확인하세요. 외장 DAC가 필수인 것은 아니며, 내장 출력도 목표 샘플레이트를 지원하면 사용할 수 있습니다. 자세한 조건은 [오디오 가이드](docs/audio-guide.md)에 정리되어 있습니다.

</details>

<details>
<summary><strong>Clean을 선택하면 모든 처리가 꺼지나요?</strong></summary>

Clean은 Circuit와 HighExciter 톤 모델만 우회합니다. Spatial과 Output Conditioning은 독립적으로 동작하므로 원본과 비교하려면 각각 꺼야 합니다.

</details>

<details>
<summary><strong>적용한 뒤 소리가 나오지 않으면 어떻게 하나요?</strong></summary>

앱이 중복 실행 중인지, 시스템 오디오 녹음 권한이 있는지, 올바른 출력 장치를 선택했는지 확인하세요. 플레이어의 독점 모드를 끄고 **중지 → 다시 적용**합니다. 특정 앱 처리라면 먼저 대상 앱에서 재생을 시작하세요. [설치 가이드의 점검 순서](docs/getting-started.md)를 참고하세요.

</details>

<a id="documentation"></a>

## 더 알아보기

| 문서 | 이런 내용을 찾을 때 |
|---|---|
| [설치와 사용 시작](docs/getting-started.md) | 다운로드, 권한, 전체 시스템·특정 앱 처리, 무음 점검 |
| [오디오 가이드](docs/audio-guide.md) | 모델, 프리셋 수치, PCM 2×, 헤드룸, Source와 Rate Match |
| [개발 가이드](docs/development.md) | 소스 빌드, 검증 명령, Swift·C++ 구조, 상세 설계 문서 |
| [기여 안내](CONTRIBUTING.md) | 버그 신고에 필요한 정보와 변경 제안 방법 |
| [릴리스 노트](https://github.com/Gomtanga/timbredock/releases) | 버전별 변경 사항과 검증 범위 |

Source 표시는 확인 가능한 근거에 따라 제공되며, **자동 Rate Match는 기본값이 꺼진 실험 기능**입니다. 실시간 출력 컨디셔닝은 **PCM 2×**까지 지원합니다. 세부 조건과 실험 범위는 오디오·개발 가이드를 참고하세요.

## 함께 만들기

버그나 아이디어는 [GitHub Issues](https://github.com/Gomtanga/timbredock/issues)에 남겨 주세요. 코드 기여는 [개발 가이드](docs/development.md)와 [기여 안내](CONTRIBUTING.md)에서 시작할 수 있습니다. 이 저장소는 macOS 앱과 휴대용 C++ DSP 코어를 함께 개발합니다.

[GNU AGPL-3.0-or-later](LICENSE) 라이선스로 배포합니다. 독자적으로 설계한 DSP이며 특정 제조사와 제휴하거나 독점 회로의 정확한 재현을 주장하지 않습니다. 제3자의 이름과 상표는 각 소유자에게 귀속됩니다.
