# v0.4.0 언어·Treble Harmonics 후속 검증

2026-09-21. 작업 위치 `/Users/geon-yeong/opencode/timbredock-redesign`, 브랜치 `codex/timbredock-redesign`. 로컬 수정이며 커밋·푸시하지 않았다.

## 사용자 보고와 확인 범위

- 사용자: 언어를 바꾸고 재실행해도 반영되지 않음.
- 사용자: Treble Harmonics의 모든 조절값에서 Off 대비 변화가 느껴지지 않음.
- 언어 저장 실패 자체는 이 세션에서 재현되지 않았다. 기존 앱도 한국어 저장, 실제 프로세스 종료, 같은 경로 재실행 후 한국어로 시작했다. 다만 한국어 표에서 주요 Sound 조절 항목과 프리셋이 영어로 남아 있는 것을 확인했다.
- Treble 모델·두 조절값 전달과 출력 샘플 변화는 확인했다. 실제 음악에서 충분히 들리는 효과인지에 대한 사용자 청취 승인은 별도다.

## 수정

- 언어 메뉴 항목을 안정적인 언어 ID로 저장하고 명시적 저장 결과를 확인한다.
- 현재 화면 언어와 다음 실행 언어를 구분해 표시한다. 다음 실행 적용 정책을 유지하며 완전 종료 후 재실행을 안내한다.
- 한국어 주요 조절 항목·프리셋·우회 표시를 번역했다.
- Sound에 실제 오디오 콜백이 받은 모델과 두 조절값을 표시한다. 큐의 lock-free atomic receipt를 읽으며 콜백에는 할당·잠금·문자열 작업을 추가하지 않았다. 처리 종료 시 이전 수신 확인은 숨긴다.
- 프리셋 도움말에서 청감상 효과를 단정하는 표현을 완화했다.
- 기존 Swift/C++ 배음 생성 알고리즘과 프리셋 수치는 유지했다. 처리 대역·강도 곡선 변경은 기존 DSP 보존 방침을 바꾸는 별도 결정이다.

## 자동 검사

- en/ko 459개 키, 테이블 대응 및 서식 인자 검사 통과.
- 독립 프로세스에서 저장한 언어를 읽는 검사, 번들 언어 테이블 검사 통과.
- Debug 및 Release 자체 검사, Release 영어·한국어 UI 검사 통과. 전체 창 검사 151개 항목, 기존 비동기 GUI 생명주기 13개 사례 통과.
- 실제 UI → manager → 등록된 IOProc → DSP → 출력 링 경로를 통과하는 합성 PCM 검사. 하드웨어만 대체했으며 스피커로 테스트음을 재생하지 않았다.
- 44.1/48/88.2/96 kHz에서 1/6/8/12 kHz 입력, Off·제로 조절·기본·Strong·사용자 저장값·최대값·Off 복귀 비교 통과. 모델과 값 수정은 캡처 장치를 재생성하지 않는다. 중지 후 과거 receipt 숨김도 검사했다.
- PCM 2× 44.1→88.2 및 48→96 kHz에서 최대값 변화와 Off 복귀 일치 확인.
- Portable Core Release CTest 9/9, C 큐 ThreadSanitizer 검사 0 failure.

## 효과 크기 해석

현재 HighExciter는 11 kHz 고역 통과 성분에 배음을 더한다. 고역 입력이 작고 Drive와 Added 값이 낮으면 효과가 매우 작아질 수 있다. 다음은 48 kHz, 진폭 0.5의 8 kHz 사인 입력에서 측정한 출력−Off 잔차 RMS다. 일반 음악의 체감 크기나 음질 점수로 해석하면 안 된다.

| 값 | 잔차 RMS |
|---|---:|
| Subtle 12 / 4 | −103.37 dBFS |
| Strong 50 / 16 | −66.51 dBFS |
| 사용자 저장값 근사 66.93 / 15.79 | −61.53 dBFS |
| 최대 100 / 100 | −38.45 dBFS |

같은 입력의 16 kHz 배음 진폭은 Subtle 0.000009593, Strong 0.000665760으로 약 69.4배 차이가 났다. Drive 제곱과 Added 곱에 따른 예측값과 일치했다. PCM 2× 경로의 최대값 잔차는 각각 −43.56/−41.45 dBFS였으며 Off 복귀는 해당 변환 경로의 기준 출력과 일치했다.

## 실제 앱·USB 검사

- 수정 앱이 한국어로 시작하며 주요 조절 항목이 번역된 것을 확인했다.
- Settings에서 English를 저장하자 현재 한국어/다음 영어 표시가 나왔다. ⌘Q 후 프로세스가 종료된 것을 확인하고 같은 앱을 재실행하자 영어로 시작했다.
- 첫 PCM 2× 재시작은 capture/output flow timeout과 복구 실패를 표시했다. Stop으로 정리했다. 원인을 단순히 무음으로 확정하지 않는다.
- 사용자가 음악 재생 중이라고 답한 뒤 Apple Music 48 kHz 원본 정보가 표시됐다. 다시 Apply하자 USB Primary Play Interface에서 처리 상태와 88.2 kHz 출력이 확인됐다. 원본 정보와 실제 탭/출력 샘플레이트는 서로 다를 수 있다.
- 처리 중 Treble 선택 → 기존 66.93/15.79 → 최대 100/100 → Off → Bass Boost 순서에서 실제 콜백 수신 표시를 확인했다. 최대값 증거는 `build/followup-issues/live-treble-max.png`에 저장했다.
- 검사가 끝난 뒤 원래 Bass Boost 54/22/−2.8 dB, 저장된 Treble 66.9318441499086/15.7913905393053, 영어 및 PCM 2× 처리 상태를 복원했다.
- 앱은 한 개만 실행 중이었다. DAC 출력 파형 녹음, 청취 차이 판정, 장시간 안정성 검사는 하지 않았다.

## 산출물

수정 앱: `build/LowEndCircuit_artefacts/Release/NativeSystemAudio/TimbreDock.app`.
후속 ZIP: `build/followup-issues/TimbreDock-v0.4.0-language-treble-preview.zip`.
로그: `build/followup-issues/`의 Release/Debug/UI/Core/TSan 기록.
이전 `build/redesign-evidence/` ZIP·패치는 첫 구현 기록이며 이번 후속 변경의 증거로 사용하지 않는다. 최신 소스 검토 패치는 `build/followup-issues/source.patch`다.
