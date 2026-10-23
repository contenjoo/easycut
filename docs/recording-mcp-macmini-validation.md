# 맥미니 설치·실제 Canva 녹화 검증 — 2026-10-23

설치·실제 Canva 촬영·저장본 끝까지 재생 확인 완료. 실제 사용 브라우저는 **Chrome**이다.
원격 맥미니 대화 ‘첫 과정 각본·촬영 계획 정리’의 실행 로그와 결과 문서를 조회해 확인했다.
내장 브라우저 촬영 성공이나 Canva 강의 최종 영상 제작 완료로 해석하지 않는다.

## 설치와 소스

- 앱: `/Applications/EasyCut.app`, bundle ID `com.contenjoo.easycut`.
- 기준: `6c39d670ae6d3a8004148ad7ec42f0e930625ebd` + 아래 두 파일의 SDK 호환 패치.
- 설치 실행 파일 SHA256: `80206c947b2eeb9dd9cb4396653ad645c06952e20baf06d51daf029219327d22`.
- ad-hoc 서명. `codesign --verify --deep --strict` 통과. 기존 유효 서명 인증서는 없었다.
- `/Applications`, 사용자 Applications 및 실행 목록에서 기존 EasyCut이 발견되지 않았다.
  기존 별도 소스, Canva 디자인과 OBS 원본은 보존했다.
- 설치된 실행 파일의 `--mcp`에서 도구 40개 및 새 녹화 도구 4개 노출 확인.
- 화면 녹화 권한 on 상태에서 앱 정상 재시작 후 대상 조회 성공. 권한 DB 직접 수정 없음.

맥미니 Swift 6.4 / 기본 macOS 27 SDK는 `SwiftUIMacros.StateMacro` 플러그인 누락으로
실패해 설치된 macOS 26.5 SDK를 선택했다. 다음 오류도 두 곳에서 발생했다.

```text
cannot convert value of type 'Unmanaged<MTAudioProcessingTap>?' to expected argument type 'MTAudioProcessingTap?'
```

`AudioMeter.swift`, `SelfTest.swift`의 tap을 `MTAudioProcessingTap?`로 받고
`takeRetainedValue()`를 제거한 설치용 패치로 릴리스 빌드가 통과했다.
이 저장소에는 같은 Swift 6.4 코드 경로를 조건부로 반영하고, 로컬 Swift 6.0.3의
기존 `Unmanaged` 경로를 유지했다. 로컬 변경 후 빌드도 통과했다.
설치본은 기준 커밋 + 패치로 빌드한 위 SHA의 실행 파일이며 후속 커밋에서 다시 빌드한 바이너리는 아니다.
서명 변경에 따른 권한 초기화를 피하기 위해 성공 검증 뒤 앱을 다시 교체하지 않았다.

vendor/bin이 없는 빌드여서 Whisper·ffmpeg는 앱에 내장되지 않았다.
ScreenCaptureKit 원본 녹화는 이 도구에 의존하지 않는다. 영상 검사는 맥미니의 ffmpeg/ffprobe로 실행했다.

## 실제 촬영과 readback

처음 영역 캡처는 설정 창·다른 브라우저가 섞인 대상 불일치로 **실패** 처리했다.
이후 대상 목록의 Chrome 창 ID를 직접 지정해 다시 촬영했다. 실패 산출물도 삭제하지 않았다.

- 대상: Chrome의 가상 ‘햇살반 가을 소풍 안내문’ 실습 사본, 창 ID 8141.
- 성공 세션: `254A1B17-87BA-4D73-A9C4-0A0DBFADA798`.
- camera / microphone / system_audio / highlight_clicks 모두 false, 요청 30fps.
- `get_project_state` → `list_recording_targets` → `start_recording`
  → 약 10초 뒤 `get_recording_status` → 약 25초 뒤 `stop_recording` → 프로젝트 재조회.
- 중간 상태: recording, 10.070738초. 저장 후 completed, 진행 중인 녹화 없음.
- AVFoundation 길이 25.078333초, 1920×960, nominal fps 29.00073, 속도 1.
- ffprobe: H.264, 오디오 스트림 0, 길이 25.068333초, 727프레임.
- 전체 프레임 decode 오류 0, 고유 프레임 169개.
- 접촉 시트에서 실제 글자 변경·다람쥐 그림 이동 확인.
- QuickTime 원본 재생: 00:00 → 00:18 → 00:25, 마지막 타임라인 25.078333초 / 재생 off 확인.
- 녹화 전후 EasyCut 프로젝트 상태 동일(새 빈 프로젝트). 가상 Canva 제목과 그림 위치 복원.

## 맥미니에 보존한 산출물

원본 세션 폴더:

```text
/Users/learntoday/Movies/EasyCut 녹화/254A1B17-87BA-4D73-A9C4-0A0DBFADA798/
```

실제 한글 경로는 파일 시스템에서 분해형으로 저장돼 있다. `stop_recording` 결과에 반환된
절대 경로를 그대로 사용하는 것이 안전하다. 이 폴더의 screen.mp4와 result.json이 원본이다.

프로젝트 안의 결과 폴더(맥미니):

```text
/Users/learntoday/Library/CloudStorage/GoogleDrive-joo@learntoday.kr/내 드라이브/Projects/04_개발_프로젝트/웹프로젝트/캔바교육영상만들기/제작자료/결과물완성_5과정/EasyCut_맥미니검증/
```

보존 파일:

- `결과.md`, `SDK_호환수정.patch`, `build.log`
- `Canva_EasyCut_창지정_원본.mp4`
- `Canva_EasyCut_창지정_개인정보제외.mp4` (상단 헤더 제외, 1900×700, 원본 속도 유지)
- `window_started.json`, `window_during.json`, `window_stopped.json`, `window_frames.md5`

원본에는 상단 아바타·북마크가 있으므로 그대로 공개하지 않는다. 영상 파일은 GitHub에 올리지 않았다.
공개 릴리스를 발행하지 않았다. Remotion 강의 최종 렌더·배포는 이번 검증 범위가 아니다.
