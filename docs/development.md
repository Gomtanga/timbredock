# 개발 가이드

[← 홈](../README.md) · [English](development.en.md)

이 문서는 v0.4.0 개발 소스를 기준으로 합니다. [v0.3.0 배포 파일](https://github.com/Gomtanga/timbredock/releases/tag/v0.3.0)은 기존 앱과 파일 이름을 유지합니다.

## 소스에서 빌드

### TimbreDock

Xcode 26 / macOS 26 SDK 이상이 필요합니다. Liquid Glass 화면은 `NSGlassEffectView`·`NSGlassEffectContainerView`와 `.glass`를 사용하므로 이 SDK가 포함된 Xcode로 컴파일해야 합니다. 생성된 앱의 최소 실행 버전은 macOS 14.4이며, macOS 26 미만에서는 기존 대체 화면 경로를 사용합니다.

```sh
git clone https://github.com/Gomtanga/timbredock.git
cd timbredock
./scripts/build-native-system-audio-app.sh
open "build/LowEndCircuit_artefacts/Release/NativeSystemAudio/TimbreDock.app"
```

명령줄에서 전체 시스템 또는 특정 앱 모드를 시험할 때는 다음 도구를 사용할 수 있습니다.

```sh
./scripts/run-system-wide-lowend.sh
./scripts/list-audio-apps.sh
./scripts/run-app-lowend.sh com.spotify.client
```

## 검증

이 저장소의 CI는 휴대용 C++ Core, Swift 지원 검사, Swift·C++ DSP 비교, TimbreDock 빌드를 나누어 검사합니다. 로컬에서는 필요한 범위에 맞춰 다음 명령을 사용할 수 있습니다.

```sh
cmake -S Source/Core -B build/core-tests -DCMAKE_BUILD_TYPE=Release -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build/core-tests --parallel
ctest --test-dir build/core-tests --output-on-failure
```

macOS에서는 다음 검사도 실행할 수 있습니다.

```sh
swift run --package-path SystemAudioProcessor -c release LowEndSupportChecks
swift run --package-path SystemAudioProcessor -c release SystemAudioProcessor --self-test
```

`--self-test`는 빠른 오프라인 회귀 검사입니다. CPU 처리량 벤치마크는 `--benchmark-output-conditioning`으로 별도 실행합니다. `RateMatchBench`는 기본적으로 `--dry-run`이며 장치의 지원율과 제안만 읽습니다. 실제 변경에는 `--execute --device ID`가 필요하고 다른 앱의 오디오가 끊길 수 있습니다. 이 수동 도구는 일반 빌드·CI에서 실행하지 않습니다.

빌드 스크립트는 Release 지원 검사와 서명된 최종 실행 파일의 self-test·CLI 인수 회귀 검사를 통과한 임시 앱만 기존 앱과 교체합니다. CLI 검사는 잘못된 인수의 거절과 도움말 출력을 확인합니다. SwiftPM shader resource bundle과 애드혹 서명도 검사합니다. 별도 경로에서 QA할 때는 다음처럼 실행합니다.

```sh
LOWEND_BUILD_DIR=/tmp/lowend-build-qa \
LOWEND_APP_DIR="/tmp/lowend-app-qa/TimbreDock.app" \
./scripts/build-native-system-audio-app.sh
```

선택적으로 `LOWEND_SWIFT_SCRATCH_DIR`와 숫자 `LOWEND_BUILD_NUMBER`를 지정할 수 있습니다. 경로는 절대 경로를 사용합니다. 빌드 번호는 배포용 식별값이며 shallow clone의 commit 수를 전역 단조 증가 번호로 취급하지 않습니다. `--self-test` 통과는 Process Tap 권한, 실제 DAC 전환, 청취·VoiceOver QA 완료를 의미하지 않습니다.

특정 개발 도구 조합을 검증할 때는 `LOWEND_SWIFT_SDK`에 설치된 macOS SDK 경로, `LOWEND_SWIFT_BUILD_SYSTEM`에 해당 Swift가 지원하는 빌드 시스템 이름을 지정할 수 있습니다. 두 product 빌드와 실행 파일 경로 조회에 같은 값이 전달됩니다. 생략하면 Swift의 기본값을 사용하며 시스템의 developer directory를 변경하지 않습니다.

실시간 오디오 콜백은 메모리 할당, 잠금, 로그 및 파일 입출력, UI 접근, 필터 계수 계산을 하지 않도록 설계되어 있습니다. 자세한 구조는 소스와 [Cross-Platform Core Architecture](cross-platform-core-architecture.md)를 참고하세요.

## 현재 소스의 처리 구현과 실험 범위

Native live callback은 `TonalDSP.swift`의 Swift Circuit/HighExciter와 `SpatialDSP.swift`를 실행합니다. C++ `Source/Core`는 portable DSP 및 parity 비교 경로이며, 공간 geometry는 C++ 순수 계산을 C ABI로 공유합니다. 두 언어의 출력 일치는 동일한 오류를 배제하지 않으므로 독립 impulse·주파수 응답·DC·전환 fixture도 검사합니다.

Output 화면은 Standard, 2× Upsampling, Match Source Sample Rate를 제공합니다. 실제 출력 변환 범위는 PCM 2×입니다. 4×/8×, dither/noise shaping, DSD/DoP는 live 출력에 연결되어 있지 않습니다. offline DoP packer는 채널별 16 DSD bits와 8-bit marker를 32-bit little-endian container `[payloadLow, payloadHigh, marker, 0]`에 담으며, block 사이의 marker phase와 잔여 bits를 보존합니다. 이 형식 검사는 완성된 DSD64/128/256 transport 또는 DAC 호환성 검증을 뜻하지 않습니다.

현재 구현·완료 조건은 [v0.4.0 개편 기록](redesign-v0.4.0.md)에서 확인하세요. v0.3.0의 날짜가 붙은 검증 기록은 새 빌드의 실제 장치 검증을 대신하지 않습니다.

## 저장소 구조

```text
Source/Core/                    테스트 가능한 휴대용 Circuit·HighExciter DSP
SystemAudioProcessor/           macOS Native Swift·C 엔진
SystemAudioProcessor/Shaders/   Metal 스펙트럼 셰이더
SystemAudioProcessor/Assets/    Native 앱 아이콘
scripts/                        빌드 및 실행 도구
docs/                           사용법, 설계, 검증 기록
```

[기여 안내](../CONTRIBUTING.md) · [라이선스](../LICENSE)

## 참고 문서

| 문서 | 내용 |
|---|---|
| [System-Wide and Per-App Use](system-wide-and-per-app.md) | macOS 전체 시스템 및 특정 앱 처리 |
| [Rate Matching](rate-matching.md) | 자동 샘플레이트 전환과 복구 흐름 |
| [HighExciter Oversampling](high-exciter-oversampling.md) | 배율 정책, 필터, 실시간 처리 규칙 |
| [Source Format Validation](source-format-validation-2026-06-11.md) | Apple Music·TIDAL 소스 감지 검증 기록 |
| [Source Rate Tracking and Device Lock Plan](source-rate-and-device-lock-plan.md) | Source, 자동 전환, Device Lock 설계 |
| [Cross-Platform Core Architecture](cross-platform-core-architecture.md) | Swift·C++ DSP 코어 통합 설계와 이행 계획 |
| [GitHub Releases](https://github.com/Gomtanga/timbredock/releases) | 버전별 변경 사항, 배포 파일, 검증 결과 |

설계 문서와 날짜가 붙은 검증 기록은 작성 당시의 상태를 담고 있습니다. 현재 동작을 확인할 때는 최신 코드와 릴리스 노트를 함께 보세요.
