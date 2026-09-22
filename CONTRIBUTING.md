# Contributing to TimbreDock

[한국어 README](README.md) · [English README](README.en.md)

## 한국어

버그와 기능 제안은 [GitHub Issues](https://github.com/Gomtanga/lowend-circuit/issues)에 남겨 주세요. 오디오 문제는 환경에 따라 재현 조건이 달라지므로 가능한 범위에서 다음 정보를 포함하면 좋습니다.

- 운영체제와 버전
- CPU와 앱 버전
- 입력·출력 장치 및 DAC 모델
- 샘플레이트와 버퍼 설정
- 선택한 모델과 프리셋
- 전체 시스템 또는 특정 앱 가운데 사용한 방식
- 독점 모드와 자동 Rate Match 사용 여부
- 재현 순서와 기대한 결과
- 관련 로그 또는 화면 캡처

로그를 첨부하기 전에는 계정 정보, 사용자 이름, 개인 경로, 재생 기록처럼 공개할 필요가 없는 내용을 지우세요.

변경을 제안할 때는 영향을 받는 플랫폼, 실행한 검사, 확인하지 못한 항목을 함께 적어 주세요. Pull Request에서는 저장소의 macOS 및 크로스 플랫폼 CI가 실행됩니다.

빌드와 검증 명령은 [개발 가이드](docs/development.md)를 참고하세요.

## English

Report bugs and feature requests in [GitHub Issues](https://github.com/Gomtanga/lowend-circuit/issues). Audio problems depend heavily on the environment, so include as much of the following as you reasonably can:

- operating system and version
- CPU and application version
- input and output devices, including the DAC model
- sample rate and buffer settings
- selected model and preset
- system-wide or per-application use
- exclusive-mode and Automatic Rate Match state
- reproduction steps and expected result
- relevant logs or screenshots

Before attaching logs, remove account information, user names, private paths, listening history, and anything else that does not need to be public.

When proposing a change, state the affected platform, the checks you ran, and anything you did not verify. Pull requests run the repository's macOS and cross-platform CI workflows.

See [Development](docs/development.en.md) for build and verification commands.
