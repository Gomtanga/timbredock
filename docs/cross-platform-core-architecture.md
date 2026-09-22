# LowEnd Core — Shared DSP Architecture

> Historical design: this document records an earlier migration plan. Current v0.4.0 work is tracked in [the redesign plan](redesign-v0.4.0.md). The released app is macOS; Windows exploration continues separately on its existing branches.


> 상태: **현재 소스 구조 정정 (2026-09-07)**.
> 원래는 2026-06-08의 "Cross-Platform Core Architecture" 제안이었습니다.
> C++ portable Core와 C 브리지는 존재하지만 Native live DSP는 Swift 경로이며, JUCE Plugin(Phase 3)과
> Windows Adapter(Phase 4)는 2026-08에 공식 폐기되었습니다. 저장소는 이제
> **macOS Native App + portable Core** 단일 플랫폼으로 운영합니다.

---

## 1. 현재 상태

| 구성 요소 | 상태 |
|---|---|
| `Source/Core/` — C++ portable DSP (CircuitBass, HighExciter, Processor) | ✅ 구현 |
| `SystemAudioProcessor/` — macOS Native App | 메인 타깃. 톤 DSP는 `TonalDSP.swift`, 공간 DSP는 `SpatialDSP.swift` |
| `Source/Core/test/` — C++ 단위 테스트 | ✅ CI에서 실행 |
| Swift ↔ C++ DSP parity self-test | ✅ macOS CI에서 실행 |
| JUCE Plugin (Standalone / VST3 / AU) | ❌ 폐기 (2026-08) |
| Windows Adapter / Windows Native | ❌ 폐기 (2026-08) |

---

## 2. DSP 통합 분석 (역사적 기록)

제안 당시 핵심 발견: Swift DSP와 JUCE DSP는 **완전히 다른 알고리즘**이었습니다.

| 특성 | Swift DSP (VirtualCircuitBassDSP) | JUCE DSP (PluginProcessor) |
|---|---|---|
| Bass 처리 | Low-Shelf + RC Bass/Sub-bass pole + feedback | Low-Shelf (JUCE IIR) |
| Saturation | Asymmetric polynomial + pre/de-emphasis | `tanh` 기반 clamp |
| Body | Frequency-weighted injection | `tanh(sub * 2.4) * 0.18 * body` |
| Sub | RC one-pole 38 Hz | Biquad low-pass 135 Hz |
| Output 보호 | Headroom + makeup + wet mix | 고정 headroom + tanh |
| HighExciter | 별도 DSP 클래스 | 없음 |
| Spatializer | Delay line + crossfeed | 없음 |

JUCE 타깃 폐기는 Native의 Swift 톤 DSP와 C++ portable DSP를 하나의 구현으로 합치지 않았습니다. 실제 callback은 `VirtualCircuitBassDSP`와 `HighExciterDSP`를 호출하며 두 클래스는 `TonalDSP.swift`에 있습니다. `SharedDSPCore`/`LowEndDSPCoreC`의 톤 processor는 parity self-test에서 비교합니다. 톤 계산을 수정하면 두 경로와 독립 expected fixture를 함께 갱신해야 합니다.

공간 geometry는 `Source/Core/src/SpatialGeometry.cpp`의 순수 함수를 C ABI로 공유합니다. UI preview와 manager packet precompute는 같은 geometry 계약을 사용하지만, runtime delay/mix는 Swift `SpatialDSP.swift`에서 수행합니다. geometry의 공유와 톤 processor의 공통화는 서로 다른 범위입니다.

---

## 3. Core 설계 원칙

- **Float sample I/O**, 저역 shelf 계수와 상태는 Double — 고율 저역 응답 정밀도 보존
- **생성 후 힙 할당 없음** — realtime-safe
- **샘플레이트 인지** — 모든 계수 생성기가 `sampleRate`를 받음
- **전역 상태 없음** — 모든 인스턴스 독립
- **C ABI 타입** (`AudioRingBufferC.h`)이 데이터 계약
- `process()` 내부에 allocation / locking / logging / 계수 연산 없음
- HighExciter Auto: 실제 tap 측 처리율 44.1/48 kHz에서 4x, 88.2/96 kHz에서 2x, 176.4/192 kHz 이상에서 1x
- Live PCM 2×는 HighExciter 내부 배율과 별도의 후단 출력 변환이다.
- Spectrum FFT/history는 전용 worker가 소유하고, immutable meter 수치만 MainActor로 보낸다. GPU buffer는 command completion 후에만 재사용한다.
- SPSC ring clear/destroy는 생산자와 소비자의 정지가 전제다. 실행 중 분석 데이터 폐기는 consumer가 요청을 처리한다.

---

## 4. 참조

- [`Source/Core/README.md`](../Source/Core/README.md) — 빌드 및 테스트 방법
- [`docs/rate-matching.md`](rate-matching.md) — DAC 레이트 매칭 설계
- [`docs/roadmap-v0.2.3-v0.3.0.md`](roadmap-v0.2.3-v0.3.0.md) — v0.2.3 → v0.3.0 로드맵
