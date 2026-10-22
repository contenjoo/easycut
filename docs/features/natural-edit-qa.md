# 말·파일명 편집 출시 검증 (2026-10-22)

## Mac 실제 흐름

- 테스트용 QuickTime 합성 영상 창만 ScreenCaptureKit으로 실제 녹화. 카메라/마이크는 끄고 해당 앱 시스템 오디오만 녹음.
- 별도 bundle ID의 TCC 승인이 설정상 켜져도 실제 API는 -3801을 반환했다. 기존 EasyCut과 같은 서명의 테스트 앱으로 검증하되 Info.plist `EasyCutTestInstance`로 복구 파일·AI 작업 폴더·제어 포트는 격리했다.
- 메인 창이 투명해진 상태에서 UI 도구가 떠 있는 정지 패널을 선택하지 못해 사용자가 정지 버튼을 눌렀다. 이를 보완할 녹화 정지 메뉴도 추가했다.
- 실제 녹음 186.327초를 Whisper로 인식. 실제 지시: `편집아, 이 영상의 소리를 꺼주어` (9.170–13.000초).
- 처음에는 뒤의 `설명을 이어갑니다`까지 후보에 포함됐다. 한국어 지시 종결어/0.55초 쉼 처리를 추가하고 같은 실제 인식 결과를 Mac/Windows 파서 회귀 검사에 넣었다.
- 실제 ChatGPT/Codex 계정으로 지시를 적용. MCP의 `set_clip_properties`, `delete_time_ranges`, `edit_captions` 실행과 실제 프로젝트를 대조했다.
- 결과: 화면/오디오 모두 volume=0, 원본 9.170–13.000초만 제거. 정상 설명 자막은 수정된 타임라인 9.82–11.28초에 남음.
- 원본 미디어 SHA-256 동일. MP4 내보내기 길이 182.500초, 음소거 결과에 오디오 트랙 없음. 10.5초 렌더 프레임에서 `설명을 이어갑니다.` 자막 확인.
- `초안 이전 복원` 클릭 후 프로젝트 JSON 전체가 편집 전과 동일함을 확인.
- 음성 지시를 끄고 `검증_전체클립볼륨50퍼센트로.mp4` 파일명 요청으로 실제 AI 편집. 두 클립 volume=0.5, 다른 프로젝트 내용은 편집 전과 동일.
- 포인터가 타임라인 하단에 없어도 고정 스크롤바가 표시되는 실제 앱 화면 확인.

## Windows 검증 범위

- 파서 검사: 일반 설명 제외, 호출어 구분, 실제 Mac 녹음 회귀, 파일명 해석.
- Rust 전체 검사 및 여러 편집 단계를 한 번에 복원/복원 실행취소하는 검사.
- GitHub Windows runner의 실제 설치/Whisper/MCP/내보내기 검사.
- 새 native 검사는 실제 WebView2의 MediaRecorder에서 합성 canvas와 테스트 음성을 녹화하고, 실제 Tauri rec_begin/chunk/finish → MP4 → Whisper → 검토 UI → native 프로젝트 복원을 확인한다. 실제 데스크탑/마이크 장치 선택과 유료 AI 계정은 이 CI 검사에서 사용하지 않는다.
- 최초 native 실행은 CDP 연결 포트가 열리지 않아 실패했다. 별도 WebView2 사용자 데이터 폴더와 기존 runner 테스트 프로세스 정리를 추가했다. 최종 CI 결과는 출시 전 확인한다.

## 임시 증거

Mac 테스트 자료: `/tmp/easycut-natural-e2e/`의 원본 해시, 편집 전/후 프로젝트, 실제 AI 로그, 내보낸 MP4 및 프레임.
Windows 화면: CI의 `natural-edit-native-evidence` artifact. 실제 AI 서비스의 의미 해석 검증은 Mac에서 수행했으며, CI의 native 검사를 Windows 실사용 계정 테스트로 표현하지 않는다.
