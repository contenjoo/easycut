# AI에서 EasyCut 원본 녹화하기 (macOS)

로컬 개발 기능. 기존 공개 릴리스 v1.12.0에는 녹화 제어 MCP가 없습니다.
이 소스에서 빌드한 앱과 **같은 빌드의 실행 파일**을 MCP 서버로 사용하세요.
Windows 녹화 MCP는 이 변경에 포함되지 않습니다.

## 연결

앱을 먼저 실행하고 macOS 화면 녹화 권한을 허용합니다. MCP 설정:

```json
{
  "mcpServers": {
    "easycut": {
      "command": "/absolute/path/EasyCut.app/Contents/MacOS/EasyCut",
      "args": ["--mcp"]
    }
  }
}
```

Claude Code에서는 `claude mcp add easycut -- /absolute/path/EasyCut.app/Contents/MacOS/EasyCut --mcp`,
Codex에서는 `codex mcp add easycut -- /absolute/path/EasyCut.app/Contents/MacOS/EasyCut --mcp`로
같은 stdio 서버를 등록할 수 있습니다. CLI 버전에 따라 등록 옵션은 해당 클라이언트 도움말을 확인하세요.
로컬 인증 토큰은 앱이 관리합니다. 복사·출력·문서화하지 마세요.

분리된 테스트 앱(`EasyCutTestInstance=true`)은 포트 47823과 OS 임시 폴더의
`EasyCut-NaturalEdit-Dev`를 씁니다. stdio 서버에도 `EASYCUT_CONTROL_PORT=47823`과
동일한 **절대** `EASYCUT_SUPPORT_DIR`를 전달해야 합니다. 일반 앱은 기본 포트 47821입니다.

## 촬영 순서

1. `list_recording_targets({})`로 현재 창 ID·제목·앱을 확인합니다. 의도한 Canva 창을 정확히 선택합니다.
2. 아래 요청으로 시작하고 반환된 `session_id`를 보관합니다. ID는 예시이므로 조회 결과로 바꾸세요.
3. Canva를 정상 속도로 조작하며 `get_recording_status`를 호출해 `recording` 상태와 증가하는 시간을 확인합니다.
4. `stop_recording`을 호출하고 `completed` 및 `result.files`를 확인합니다.
5. `kind=screen`의 절대 MP4 경로를 Remotion으로 전달하고 실제 재생을 확인합니다.

```json
{"name":"start_recording","arguments":{"target":"window","window_id":123,"fps":30,"camera":false,"microphone":false,"system_audio":false,"highlight_clicks":false}}
{"name":"get_recording_status","arguments":{"session_id":"반환된-ID"}}
{"name":"stop_recording","arguments":{"session_id":"반환된-ID"}}
```

모든 장치·클릭 옵션 기본값은 false입니다. 카메라/마이크를 켜면 목록에서 얻은
`camera_id`/`microphone_id`로 장치를 지정하세요. 생략하면 첫 장치입니다.
마이크는 screen.mp4에, 카메라는 camera.mp4에, 컴퓨터 소리는 system-audio.m4a에 저장됩니다.
`highlight_clicks=true`는 클릭 시각·정규화 좌표를 clicks.json에 기록합니다.
원본 MP4에는 강조를 굽지 않으며 Remotion이 이 좌표로 표시해야 합니다.
클릭 수집은 OS의 이벤트 모니터 권한과 해당 앱의 입력 전달 방식에 영향을 받습니다.

영역 녹화는 `target=area`, `display_id`, `x`, `y`, `width`, `height`를 지정합니다.
좌표는 해당 화면 왼쪽 위 기준 포인트입니다. 전체 화면은 `target=display`, `display_id`를 씁니다.
화면 경계를 넘는 영역, 사라진 창, 잘못된 장치 ID는 오류이며 다른 대상으로 대체하지 않습니다.

녹화 중 작은 “EasyCut MCP 녹화” 창의 정지 버튼 또는 파일 메뉴의 녹화 정지로도 저장할 수 있습니다.
앱을 강제 종료하면 저장 완료를 보장할 수 없습니다.

## 결과와 오류

세션마다 `~/Movies/EasyCut 녹화/<UUID>/`를 새로 만들며 기존 파일은 덮어쓰지 않습니다.
원본 파일과 result.json을 보존하고, 현재 프로젝트·자막·AI 작업을 변경하지 않습니다.
결과에는 각 파일의 절대 경로, 실제 길이, 영상 크기, AVFoundation의 실제 nominal fps가 들어갑니다.
ScreenCaptureKit은 화면이 바뀐 프레임만 쓰므로 실제 fps는 요청한 24/30/60보다 낮을 수 있습니다.
`requested_fps`와 실제 `fps`를 구분하세요. 재생 속도는 1입니다.
원본 픽셀 크기를 유지하되 인코더에 맞춰 홀수 크기는 아래 짝수로 맞춥니다.
긴 변 4096 초과는 축소하지 않고 오류를 반환하므로 작은 영역을 선택하세요.

중복 시작은 `already_recording`, 잘못된 세션은 `unknown_session`, 권한·캡처 불가는
`screen_capture_unavailable`/`permission_denied`로 반환됩니다.
시작/저장 오류는 MCP `isError=true`입니다. `failed` 상태의 파일은 완성본으로 사용하지 마세요.
저장 중 재정지는 `busy`로 반환하므로 상태를 조회한 뒤 재시도합니다.
완료된 세션의 정지는 같은 결과를 반환합니다. 새 녹화 전 마지막 결과는 메모리에 남으며,
앱 재시작 후에는 세션 폴더의 result.json에서 완료 정보를 확인하세요.
UI에서 시작한 녹화는 이 MCP 세션의 정지 대상으로 취급하지 않습니다.

## 로컬 회귀 검증

무해한 애니메이션 창을 재생하고 ID/제목을 확인한 뒤 실행합니다.
실제 24초를 녹화하므로 개인 자료 창을 지정하지 마세요. ffmpeg/ffprobe는 검증 도구이며 앱 의존성이 아닙니다.

```sh
python3 scripts/recording_mcp_smoke.py \
  --executable /absolute/path/EasyCut.app/Contents/MacOS/EasyCut \
  --window-id 123 --expected-title harmless-motion.mp4 \
  --evidence-dir /tmp/easycut-recording-evidence-unique
```

이 스크립트는 입력 오류, 중복 시작, 세션 불일치, 반복 정지, 프로젝트 보존,
실제 길이·무음 스트림·전체 프레임 decode·움직임을 검사합니다.
마지막으로 별도 플레이어에서 원본을 재생하여 화면이 맞는지 사람이 확인합니다.
맥미니에는 승인 후 이 변경으로 빌드한 앱·MCP를 함께 적용하고 해당 Mac의 화면 권한과 실제 녹화를 다시 검증해야 합니다.
