# v0.4.0 Liquid Glass UI

2026-09-22 사용자 요청으로 기존 v0.4.0 개편 범위에 추가한 UI 변경이다. 앱·DSP 기능은 유지하고 화면과 안내 방식만 바꾼다. Treble 처리 대역·강도 곡선 개선은 0.4.1 계획으로 남는다.

## 디자인

- 흰색·검정·중립 회색을 기본으로 사용하며 시스템 밝은/어두운 모드를 따른다. 오류·경고 및 시스템 포커스 색은 상태 구분을 위해 유지할 수 있다.
- macOS 26 이상에서는 AppKit `NSGlassEffectView`와 `NSGlassEffectContainerView`, glass 버튼을 사용한다. sidebar와 공통 header는 실제 glass contentView 아래에 컨트롤을 배치한다.
- macOS 14.4/15에서는 `NSVisualEffectView`로 대체한다. 이 호환 경로는 구현되어 있으나 이번 세션의 실제 OS는 macOS 27이므로 구버전 실기 검증은 별도다.
- 투명도 줄이기는 불투명 표면으로 전환하고, 대비 증가 시 테두리를 강화한다. 팝오버는 동작 줄이기 설정에 맞춰 애니메이션을 제한한다. 접근성 설정의 실제 토글·VoiceOver 전체 검사는 별도다.
- 떠 있는 사이드바·상단 조작부, 둥근 본문, 넓은 여백으로 구성한다. Sound는 모델 → 실제 수신 상태 → 조절값 → 프리셋 순서다.
- Spatial의 스테이지·경로와 Spectrum 그래프도 회색 계열로 통일한다. 좌표·DSP 계산·분석 주기·실행 조건은 바꾸지 않는다.

## 안내 문구

사용자의 추가 요청에 따라 정적인 설명은 `?`에 마우스를 올리면 tooltip, 클릭하면 선택 가능한 텍스트 팝오버로 제공한다. Escape 또는 바깥 클릭으로 닫는다.

| 페이지 | 접은 설명 | 계속 표시하는 정보 |
|---|---|---|
| Sound | 오디오 흐름·적용 범위·독점 모드 안내 | 모델, 조절값, 실제 콜백 수신 상태 |
| Spatial | 기능 소개·스테이지 조작법·좌표 안내 | 위치·폭·효과량·켜짐 상태·입력 오류 |
| Signal Monitor | 측정 위치·고정 범위·대역 해석 | 측정 상태·Peak/RMS/Crest·full-scale 경고 |
| Output | 모드·필터·게인 원리 | 선택값·실제 적용/대기/실패 상태·복원 실패 |
| Settings | 언어 적용 방법·진단 동작 설명 | 현재/다음 실행 언어·저장 실패·진단 값 |

도움말은 native NSButton으로 키보드와 접근성 API에 노출된다. 설명이 갱신되면 tooltip과 accessibility help를 함께 갱신하고 이전 팝오버를 닫는다. Spatial 도움말 focus는 기존 스크롤 노출 경로에 연결했다.

## 검증과 범위

- Release 빌드/서명 및 기존 native self-tests 통과. 전체 창 검사 161개, Output UI 82개, 비동기 GUI 생명주기 13개 사례, Treble 실제 처리 경로 fixture 통과. 한·영 460개 문자열 키 검사 통과. 영어·한국어 Release UI 검사 모두 통과.
- ZIP을 다시 풀어 strict codesign 검사와 원본 실행 파일의 바이트 일치를 확인했다.
- 최소 940×640과 기존 기본 크기에서 header 버튼의 경계·상호 겹침, 페이지 표시, 프리셋 배치를 검사한다.
- 오프스크린 밝은/어두운 5개 페이지 렌더링은 별도 확인 자료다. Metal/SceneKit 및 실제 glass 합성은 bitmap 캐시에 전부 잡히지 않을 수 있으므로 실제 앱 화면도 확인한다.
- 실제 앱에서 Sound/Spatial/Signal Monitor/Output/Settings 전환, 영어·한국어 Sound `?` 팝오버 표시를 확인했다. 언어를 원래 영어로 복원했다. 상단 컨테이너 resize 후 Apply/Stop이 밀리는 문제를 발견해 고쳤다.
- 이번 작업에서는 실물 오디오 처리를 새로 시작하지 않았다. 실제 청취, 장시간 재생, 장치 전환, 구버전 macOS, VoiceOver 전체 순회는 완료로 간주하지 않는다.
- 외부 공개·커밋·푸시는 하지 않았다. 기존 작업 트리의 미커밋 변경을 보존했다.

## 파일

작업 트리: `/Users/geon-yeong/opencode/timbredock-redesign` (`codex/timbredock-redesign`).

- `SystemAudioProcessor/Sources/SystemAudioProcessor/GlassDesign.swift`: 재질·색상·native 도움말 버튼.
- `SystemAudioProcessor/Sources/SystemAudioProcessor/ContextualHelp.swift`: SwiftUI 도움말 연결.
- `main.swift`, `SpatialUI.swift`, `SpectrumShaders.metal`, `AudioAnalysis.swift`의 clear color 및 한·영 문자열: 화면 통합.
- `build/liquid-glass/`: 빌드·UI 검사 로그, 검토 이미지, 패키지·소스 증거.

근거: [Apple Liquid Glass 적용 지침](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), 설치된 macOS SDK의 `NSGlassEffectView.h` 및 `NSButtonCell.h`.

최신 미리보기 ZIP: `build/liquid-glass/TimbreDock-v0.4.0-Liquid-Glass-preview.zip`. 이전 `build/followup-issues/` 패키지는 Liquid Glass 이전 기록이다.
