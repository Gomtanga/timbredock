# TimbreDock v0.4.0 릴리스 후보 검증

2026-09-23. 최종 후보 앱·문서·ZIP과 원격 저장소 정리를 완료했다. 아래에 명시한 인수 검증 한계가 남아 있어 전체 지원 환경의 검증 완료를 뜻하지 않는다. 사용자의 요청에 따라 정식 태그·릴리스 게시와 PR 병합은 수행하지 않았다.

## 후보와 산출물

| 항목 | 값 |
|---|---|
| 앱 소스 커밋 | `1bf8fed68383a0869cc78c758f50eca975ddc1c4` |
| 앱 빌드 ID | `1bf8fed · 2026-09-22T18:40:37Z` (2026-09-23 03:40:37 KST) |
| 버전 / 플랫폼 | 0.4.0 / macOS arm64, 최소 실행 버전 14.4 |
| 빌드·로컬 검사 환경 | macOS 27 / Apple Silicon / SDK 27 |
| 서명 | ad-hoc 서명 검증 완료. Developer ID 서명·공증은 수행하지 않음 |
| 저장소 / PR | [Gomtanga/timbredock](https://github.com/Gomtanga/timbredock), [초안 PR #26](https://github.com/Gomtanga/timbredock/pull/26) |
| 로컬 후보 | `build/release-candidate/TimbreDock.app` |
| 로컬 ZIP | `build/release-candidate/TimbreDock-v0.4.0-rc1-macOS-arm64.zip` |
| ZIP SHA-256 | `6b459fcaa1c7fbd30a72f3522b2324a3dc4353deb71d37e12b329c4dc314f6bd` |

ZIP을 압축 해제하여 서명을 다시 검증하고 원본 앱과 모든 파일이 동일함을 확인했다. `manifest.json`, `SHA256SUMS.txt`, 소스 파일별 `source-sha256.json`을 같은 로컬 디렉터리에 보관한다. 일반 빌드 출력 경로의 앱도 이 후보와 동기화했고 이전 앱은 별도 보존했다. 이후 문서·이미지 기록 커밋은 이 앱 소스 식별자와 구분한다.

영어·한국어 사용 안내의 Sound/Monitor 이미지 4장을 이 후보에서 다시 생성했다. 총 56개 렌더링은 두 언어, 밝은/어두운 모드, 기본/최소 창과 각 화면을 포함한다. 이는 격리된 설정의 오프라인 UI 렌더링이며 실제 음악 측정 이미지가 아니다. 실제 Liquid Glass/SceneKit 합성은 실행 앱 관찰로 별도 확인했다.

## 자동 검증

| 검사 | 결과와 범위 |
|---|---|
| 최종 Release 빌드 | 서명된 실제 실행 파일의 오프라인 DSP·분석·장치 전환·수명·CLI 검사 통과 |
| Core Debug / Release | 각각 CTest 9/9 통과 |
| 번역·패키징 | en/ko 463개 키와 형식 일치, 번들 자원·실패 시 기존 앱 보존 검사 통과 |
| 최종 로컬 UI, 영어·한국어 각각 | 창·레이아웃 233, Output 표시 99, 라이브 편집 69, GUI 수명 13개 사례/111개 검증 통과 |
| Treble 전달 경로 | UI → manager → 등록 IOProc → DSP → 출력 링 34,903개 검증. 모의 하드웨어 |
| macOS 15 원격 UI | 창 210, Output 99, GUI 수명 111 등 통과. 실제 사용자 조작 검사를 대신하지 않음 |

원격 CI에서 기본 Xcode 16.4 / SDK 15.5로 Liquid Glass API를 찾지 못하는 컴파일 실패를 발견했다. 설치된 Xcode 26.3 / macOS 26.2 SDK를 명시하고, macOS 15에서 Release UI 대체 경로를 실행하는 단계를 추가했다.

- 최종 앱 소스 [macOS Native and Core CI](https://github.com/Gomtanga/timbredock/actions/runs/35768746802): 통과.
- 최종 앱 소스 [Core CI](https://github.com/Gomtanga/timbredock/actions/runs/35768746809): 통과.
- 앞선 SDK 수정 확인 실행: [35768233298](https://github.com/Gomtanga/timbredock/actions/runs/35768233298), 통과.

## 실제 Fosi Audio ZH3 검사

음악은 사용자가 재생했다. 합성 테스트음을 출력하지 않았다. 초기 후보 `8ab3a2d`와 표시 수정 후 최종 `1bf8fed`를 구분한다. 두 후보 사이의 앱 변경은 중지 상태 진단 표시 갱신과 그 회귀 검사이며 DSP 변경은 없다.

| 실제 검사 | 관찰 결과 |
|---|---|
| 초기 96 kHz 입력에서 2× 요청 | 지원 범위를 벗어난 상태를 표시하고 Standard PCM 유지 |
| 초기 후보, 48 kHz 기준에서 2× 적용 | Tap 48 / Engine 96 / DAC 96 kHz, 실제 입력·출력 데이터 확인 |
| 초기 후보 Gain 0 → −6 → −12 → 0 dB | 사용자 확인: 음량이 줄고 복원됐으며 지속적인 무음·끊김·심한 왜곡 없음 |
| 초기 후보 안정 재생 | 시작 이후 underrun 15,360이 후속 관찰까지 증가하지 않음. output drop / analysis drop 0, restart 1 |
| 초기 후보 모델 편집 | Treble Drive 50 / Added 15.79의 실제 콜백 수신 확인. 원래 Treble 값 복원, Off/Bass 전환 확인 |
| 초기 후보 Spatial | 35% ON, Planar/3D, 청취자 키보드 X 0.01 이동 후 0.00 복원, OFF/3D/All 복원 |
| 초기 후보 Stop | DAC가 검사 기준 48 kHz로 복원됨 |
| 최종 후보 재검사 | 동일 Fosi에서 Tap 48 / Engine 96 / DAC 96 kHz, 실제 입력·출력 확인. Stop 후 48 kHz 복원 |
| 최종 후보 안정 재생 | 첫 진단 관찰 시 underrun 843,776, 후속 관찰에서 동일. output drop / analysis drop 0, restart 1 |
| 검사 종료 | DAC를 작업 시작 당시 96 kHz / 24-bit 설정으로 수동 복원. Output Standard / Gain 0 / Spatial OFF 유지 |

XRuns 0 또는 무음 전환이 없었다고 주장하지 않는다. 두 실행의 초기 underrun 수치가 달랐으며, 후속 관찰에서 누적 증가하지 않았다는 범위의 결과다. 장시간 재생과 시작 전환 지연 분포는 추가 측정 대상이다. Gain 청취 확인은 초기 후보에서 받았고, 최종 후보에서는 장치 활성·데이터 흐름·중지·표시 복원을 재검증했다.

## 수동 UI와 수정 사항

- 실제 다섯 페이지, Spatial 2D/3D 색상 및 선택, 모델·슬라이더 변경, 도움말 팝오버와 Escape 닫기, Tab/Space 탐색과 Spatial 화살표 이동을 확인했다.
- 초기 및 최종 후보에서 영어 → 한국어 재실행을 확인했다. 마지막에 영어로 복원했다.
- 사이드바의 `SYSTEM AUDIO` 보조 문구가 제거된 최신 앱을 확인했다.
- 발견한 결함: Stop 후 2× → Standard로 바꾸면 Settings 진단에 이전 `PCM 2x pending`이 남았다. `outputRateModeChanged()`에서 공통 진단 갱신을 호출하도록 수정하고 8개 회귀 검증을 추가했다. 최종 앱의 동일 순서를 직접 재현해 진단 `Off`를 확인했다.
- VoiceOver 스위치를 실제로 켜서 확인했고, 사용자가 앱 내용이 읽혔다고 최종 확인했다. 기본 앱 판독은 확인됐으며 VoiceOver는 다시 OFF임을 확인했다. 모든 화면과 조작을 VoiceOver만으로 수행한 전체 접근성 검증과는 구분한다.
- 수동 검사 종료 무렵 선택된 Soft Bass(30 / 8 / −2 dB)는 새 선택으로 보존했다. 검사 전 설정 전체를 덮어쓰지 않았다.

## 저장소와 안정판 보존

저장소를 `Gomtanga/timbredock`으로 변경하고 기존 API 주소의 리다이렉트와 이전 v0.3.0 다운로드 URL의 최종 HTTP 200을 확인했다. v0.3.0 ZIP을 실제로 다시 다운로드하여 공개 체크섬과 비교했다.

- 안정판 SHA-256: `ef78da0e69c7a8558fd4e767322bad5571c9de6a81285ac8a559c40c792b6c43`.
- 오래된 원격 브랜치 6개는 검증된 전체 이력 Git bundle 보존 후 정확한 SHA 조건과 원자적 push로 정리했다. PR #11/#12는 현재 구현으로 대체되어 닫았다.
- `main`, Windows 브랜치 2개와 PR #24/#25, 이번 개편 브랜치와 초안 PR #26을 보존했다. [정리 기록](branch-cleanup-v0.4.0.md).
- README의 공개 다운로드는 v0.3.0을 유지한다. v0.4.0 공개 릴리스·태그·PR 병합은 수행하지 않았다.

## 남은 인수 검증 범위

다음은 현재 완료로 판정할 수 없으며 정식 게시 판단 전에 확인하거나 지원 범위와 수용 여부를 명시해야 한다.

- 모든 화면의 VoiceOver 작업 흐름과 전체 키보드 작업 흐름. 기본 VoiceOver 앱 판독은 사용자 확인을 받았고, 자동화 및 직접 조작은 일부 탐색·조작에 한정된다.
- 모든 페이지/언어의 실제 1×·2× 디스플레이 이동·배율 조합. 생성된 이미지에는 1×/2× 해상도가 포함되지만 물리 환경 전체 검사를 대신하지 않는다.
- macOS 14.4 실장치, 기존 설치에서의 TCC 권한 유지. macOS 15 CI의 실행 성공은 이 검증을 대신하지 않는다.
- Bluetooth 무선 출력 및 장치 분리·재연결·경로 전환의 실장치 행렬. 이번 명시적 청취 검사는 Fosi USB 출력이다.
- 44.1→88.2 kHz 실장치 전환, Match Source의 실제 샘플레이트 변경, 장시간 연속 재생 및 전환 실패·복구의 반복 측정. 모의 장치 회귀 검사는 통과했다.

Treble 처리 대역·강도 곡선 개선은 0.4.1의 별도 범위다. 위 검증 한계와 구분한다. 이 문서는 정식 릴리스 게시 승인을 의미하지 않는다.
