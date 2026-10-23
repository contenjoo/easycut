# 녹화 MCP 로컬 검증 — 2026-10-23

기존 main 기준: 3abdee38070f5d95a5a314fa9f9bdedc03ca0da1. 아래 기록은 커밋 전 로컬 검증 결과다. 이후 GitHub 반영·맥미니 설치 검증은 별도로 기록한다.

설치된 /Applications/EasyCut.app v1.12.0의 tools/list는 36개였고 녹화 도구가 없었다.
이번 로컬 빌드는 40개이며 list_recording_targets, start_recording, get_recording_status, stop_recording을 포함한다.
기존 ScreenRecorder를 사용하며 UI 설정과 편집 프로젝트를 변경하지 않는 별도 세션을 구현했다.

## 실제 확인

- swift build 성공. 기존 코드의 Swift 6 전환 경고는 남아 있다.
- 기존 앱을 교체하지 않은 분리 테스트 앱의 codesign --verify --deep --strict 성공.
- 테스트 실행 파일 SHA256: 8345060fd73075fc05b510a5672bbda0e429f454be870660f67f25b9a9eeac18
- 실제 무해한 QuickTime 창을 MCP stdio로 시작 → 10초 경과 상태 조회 → 24초 후 정지.
- 저장: 24.050초, 1920×1080, H.264, 오디오 스트림 없음.
- 요청 30fps / AVFoundation nominal fps 27.826. 화면 변경에 따른 가변 프레임 기록이며 재생 속도는 1.
- 전체 667프레임 decode 오류 없음. 고유 프레임 667개로 실제 움직임 확인.
- QuickTime에서 최종 파일 재생을 직접 확인. 차트 시각 00:00:01.900 → 00:00:10.833 및 도형 이동 확인.
- 별도 영역 300×200 포인트 → 600×400 픽셀, 3.158초 저장·전체 decode 성공.
- 입력/세션/보존 회귀 검사 13개 모두 통과: 없는 창, 음수 ID, boolean ID, 잘못된 fps/boolean,
  화면 누락, 화면 밖 영역, 중복 시작, 다른 세션 정지, 세션 ID 누락, 다른 세션 조회, 반복 정지, 프로젝트 보존.
- UUID별 새 디렉터리, 파일 저장 완료 뒤 결과 JSON 기록. 기존 녹화 파일을 사용하거나 덮어쓰지 않았다.

주 영상 절대 경로: `/Users/contenjoo/Movies/EasyCut 녹화/C9FC97A5-2868-4220-BB45-AE8BBF638BF7/screen.mp4`
증거: `/tmp/easycut-recording-mcp/accepted/` (started.json, during.json, stopped.json, checks.json, media.json, frames.md5).
영역 증거: `/tmp/easycut-recording-mcp/area.json`, `area-frames.md5`.
재검증 명령: scripts/recording_mcp_smoke.py. 호출 순서와 연결 설정: [recording-mcp.md](recording-mcp.md).

## 미확인과 적용 범위

이번 신규 MCP 경로에서는 카메라·마이크·컴퓨터 소리·클릭 기록을 켠 실촬영,
권한 거절 및 디스크 저장 실패 주입, 전체 화면 캡처와 Windows를 검증하지 않았다.
음성·클릭 옵션은 구현되어 있으나 이번 무음 창 촬영 검증과 구분해야 한다.
실제 Canva 조작/맥미니 환경은 별도 확인이 필요하다.

배포·릴리스·맥미니 설치를 하지 않았다. 현재 공개 릴리스에는 이 기능이 없다.
맥미니 적용은 승인 후 새 코드 전달·동일 빌드 앱과 MCP 등록·해당 Mac 권한·30초 실촬영 재검증이 필요하다.

## 후속 결과

같은 날 사용자 승인 후 GitHub 반영과 맥미니 설치·실제 Chrome Canva 녹화·저장본 재생 검증까지
진행했다. 위 미확인 항목 중 맥미니/Canva의 최신 결과는
[맥미니 검증 보고서](recording-mcp-macmini-validation.md)를 따른다. 이 문서의 본문은 당시 로컬 검증 기록이다.
