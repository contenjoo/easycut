# EasyCut macOS 영상 생성 개발 검증 — 2026-10-30

사용자 요청: Claude Opus CLI와 협업해 EasyCut에서 Remotion 모션그래픽과 Canvas 멤피스 스타일 도시 애니메이션을 생성한다. 멤피스는 시각 스타일이며 Manim을 의미하지 않는다.

## 구현

- 상단 **영상 만들기** 또는 **파일 › 영상 만들기…**, AI 탭의 **영상 만들기** → 설명·크기·길이·fps 입력 → **설명으로 미리보기 만들기**.
- Claude Opus는 도구 없는 CLI 호출로 장면 소스를 JSON으로 반환한다. 개인 설정·MCP·파일·명령 도구를 연결하지 않는다.
- Canvas는 `frame(i)`와 `audio(t)`를 생성한다. 샘플 4장은 10%, 35%, 60%, 85% 시점이며, 전체 렌더링은 별도 사용자 확인 버튼 뒤에 실행한다. 합성 음악과 효과음은 44.1kHz stereo WAV → AAC로 저장한다.
- Remotion은 React 장면 하나를 생성하며 앱이 컴포지션 크기·길이·fps와 렌더 명령을 결정한다. 기본 생성물은 무음이다.
- Node.js/npm 및 Chrome이 필요하다. 앱 전용 runtime에 Remotion 4.0.537, React 19.2.9, puppeteer-core 24.26.1을 준비한다. 기존 Remotion 프로젝트도 선택할 수 있다.
- 샘플 이후 소스·설정·실행 harness의 SHA-256이 바뀌면 렌더링을 거절한다. 명백한 외부 요청·명령 호출 및 비결정적 난수·현재 시각 의존 코드를 거절한다. 이 검사는 OS 보안 sandbox를 의미하지 않는다.
- 임시 MP4를 길이·크기·fps·오디오로 검증한 뒤 `render.mp4`로 게시한다. 기존 완성 파일을 재렌더링으로 덮어쓰지 않는다. 타임라인 추가는 하나의 `EditorStore.apply`로 undo/redo를 지원한다.
- `GenerationProcess`는 `posix_spawn`으로 고유 프로세스 그룹을 만들고 stdout/stderr/stdin을 동시에 처리한다. 취소·타임아웃 시 그룹 TERM/KILL 후 PID를 회수한다.
- Windows 구현·공개 릴리스·Git push·두 Mac 코드 동기화는 수행하지 않았다. 프로젝트 bridge의 `start`는 자동 승인 검토가 외부 코드 전송 가능성을 이유로 거부했으며, 읽기 전용 `show`만 완료했다.

## 검증 결과

- Swift debug/release 빌드 성공. 기존 AVVideoCompositing Sendable 및 Optional.none 경고가 남아 있다.
- 최종 영상 생성 selftest **57개 통과**. Canvas/Remotion 각각 실제 Chrome 샘플 PNG 4장과 640×640·30fps·2초 MP4를 만들었다. Canvas AAC 오디오 유무, 길이·크기·fps, 샘플 재현성, 승인 전 미렌더링, 코드 변경 거절, 타임라인 추가·undo/redo를 확인했다.
- Homebrew FFmpeg와 앱 내장 FFmpeg 모두 검사했다. 내장 LGPL 빌드에는 libx264가 없으므로 사용 가능한 인코더를 확인해 `h264_videotoolbox`를 쓴다.
- 프로세스 runner 별도 실제 회귀: 1MB stdin/1.5MB stdout/8MB stderr, 2MB 출력 제한, 오류 코드, 타임아웃, 실행 전 취소, 취소 시 손자 프로세스 종료 모두 통과했다. 수정 전 손자가 남는 문제가 실제로 재현됐고 수정 뒤 해결됐다.
- 별도 bundle ID 개발 앱에서 AI 탭 진입, 생성 창, Claude 연결 표시, 광화문 예시 적용, 1080 정사각형·20초·30fps, 생성 버튼 활성 상태를 실제 UI로 확인했다.
- `dist/EasyCut.app.zip` 압축 검증 완료. 임시 개발 앱은 정상 종료하고 `dist/EasyCut-Generation-UI-Test.app.zip`에 보관·검증한 뒤 실행 가능한 앱 번들을 정리했다. `dist`·`.build/dmg`·임시 UI 검증 폴더에 앱 번들은 남기지 않았다.
- 생성 기능을 포함한 빌드의 `/Applications/EasyCut.app` 설치와 실제 AI 생성 창 진입·광화문 예시 적용을 확인했다. Opus 속도 개선 설치에서 생성 시트가 열린 상태의 정상 종료 요청이 `사용자가 취소함. (-128)`으로 끝나 규칙대로 중단했다. 이후 사용자가 전체 렌더링과 최신 설치를 명시 승인했다. 생성 시트를 닫고 메뉴로 정상 종료한 뒤 **속도 개선·사용자 주제 우선·무음 요청 지원·자유 입력 안내를 포함한 최종 빌드를 설치 완료**했다. 설치 실행 파일 SHA-256이 최종 ZIP 안의 실행 파일과 일치하며 `codesign --verify --deep --strict`가 통과했다. 재실행한 설치 앱의 생성 창에서 새 자유 입력 안내와 빈 설명란·예시 버튼을 확인했다. 원래 설치본은 `dist/EasyCut-before-video-generation.app.zip`에 백업했다. 공개 릴리스는 하지 않았으며 버전 표기는 기존 1.12.6이다.

## 재검증 명령

```sh
swift build --disable-sandbox --scratch-path /private/tmp/easycut-generation-build \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/easycut-swift-module-cache

EASYCUT_SUPPORT_DIR=/private/tmp/easycut-generation-test-support \
EASYCUT_SELFTEST_ONLY=video-generation \
EASYCUT_GENERATION_RUNTIME="$PWD/.build/generation-support/video-runtime-v1" \
EASYCUT_GENERATION_FFMPEG="$PWD/vendor/bin/ffmpeg" \
/private/tmp/easycut-generation-build/debug/EasyCut --selftest /private/tmp/easycut-generation-tests
```

원본 편집 프로젝트나 창작 영상 전체를 자동으로 렌더링하지 않는다. 2초 영상은 검증 전용 fixture다.

## 실제 Claude Opus 창작 예시

- 초기 구조화 출력 호출 2건은 600초 제한에 도달했다. 최종 호출은 safe mode, 도구 없음, JSON 단일 응답, 간결한 소스 지시를 사용한다. CLI 응답은 앱에서 별도로 JSON·계약 검증한다.
- 단순 장면 요청은 실제 앱 호출 경로에서 코드 생성과 샘플 4장 검사를 통과했다.
- 광화문 멤피스 상세 대안은 실제 Opus 단일 턴으로 388,447ms, 소스 14,514바이트에 생성됐다. 샘플 PNG 4장을 실제 Chrome으로 렌더링·시각 확인했다.
- 빠른 설정 직접 CLI 대안은 45,758ms였다. **최종 앱 호출 경로(low effort)** 에서 같은 전체 광화문 설명으로 **91,482ms**, 소스 **8,179바이트**를 반환했으며 샘플 4장·승인 전 전체 영상 없음 검사를 통과했다.
- 검토용 산출물: `output/claude-video-generation-20261030/` (최종 샘플 4장, 모아보기, 요청·장면 코드·harness·체크섬). 상세 대안은 그 아래 `detailed-version/`에 보존했다.
- 최종 샘플은 1080×1080, 30fps, 20초 중 2·7·12·17초 시점이다. 파란 버스 reveal·광화문과 산·멤피스 패턴·행렬·한/영 설명과 좌표를 시각 확인했다.
- 사용자 승인 후 확인한 체크섬의 코드로 **20.0초·1080×1080·30fps·600프레임 H.264/yuv420p + AAC stereo 44.1kHz** 전체 영상을 렌더링했다. 최종 파일은 `output/claude-video-generation-20261030/광화문광장_멤피스_20초.mp4` (14,722,913바이트)다. 합성음원 측정은 **-18.8 LUFS, -4.1 dBTP**이며 원본 WAV peak 0.6256, RMS 0.1057로 확인했다. 실제 청취 평가를 했다고 주장하지 않는다.
- ffmpeg-skill custom 1:1·20.1초 상한·content 검사: 실패 0건. 별도 자막 트랙이 없다는 선택적 경고 1건이 있으며, 장소·설명 텍스트는 화면에 포함된다. 6장 모아보기에서 한글·구도·장면 변화를 시각 확인했다. 검사 JSON과 모아보기를 같은 output 폴더에 보존했다.

## 사용자 자유 제작 요청 검증

- 광화문·멤피스·브랜드 오프닝은 예시 버튼에만 존재한다. 초기 prompt는 비어 있고 매번 사용자 설명으로 새 코드를 작성한다.
- 장소·랜드마크 지시는 장소를 요청할 때에만 적용한다. 제품·로고·개념·수학 등에는 도시나 멤피스 스타일을 부가하지 않도록 명시했다. 요청하지 않은 글자를 추가하지 않으며 무음/효과음만 요청도 음악 지시보다 우선한다.
- 실제 Claude Opus 호출로 **검은 배경·민트색 원 세 개·삼각형으로 모이는 추상 로고·글자 없음·무음** 요청을 16,447ms에 생성하고 샘플 4장을 확인했다. 코드의 `audio(t)`는 0을 반환하며 건물·장소·탈것·글자가 없다. 원본 job은 `.build/generation-support/generated-videos/3C54F7B4-A620-4773-9C5C-9FE4F943E325`다.
- 지원 범위는 Canvas·Remotion 코드 애니메이션이며 외부 원본 미디어나 실사 영상 생성 AI를 연결했다고 설명하지 않는다.

프로세스 회귀 검사는 `Tests/VideoGeneration/README.md`와 `GenerationProcessRegression.swift`에 보존했다. 저장된 harness를 다시 컴파일·실행해 `FAILURES 0`을 확인했다.

## 프롬프트 중심 제작 화면 개선

사용자는 이후 “어디서 시작하는가”, “꼭 멤피스가 아니어도 원하는 영상”을 요청했고, 범위를 애니메이션·설명·홍보 영상으로 확인했다.

- 상단 도구 막대의 첫 진입점과 파일 메뉴에 **영상 만들기**를 추가했다. 기존 AI 탭 버튼도 같은 이름으로 맞췄다.
- 기본 화면에서 제작 엔진 선택을 빼고 접힌 **고급 설정**으로 옮겼다. 설명란은 빈 상태이며 주제·이야기·스타일·색상·움직임·글자·소리를 자유롭게 입력한다.
- 특정 도시·멤피스가 대표 선택지처럼 보이지 않도록 예시를 교육 설명·제품 홍보·데이터 이야기·손그림 이야기로 바꿨다. 예시 버튼은 prompt만 바꾸고 사용자의 화면·길이·제작 방식은 유지한다.
- Canvas/Remotion 이름은 고급 설정에 보관하며, 새 생성 지시는 요청에 따라 시각 기법·팔레트·장면 구조를 선택한다. 설명·홍보·이야기·데이터는 조건부 구성 지침이며 고정 템플릿이 아니다. 요청한 문구·브랜드·수치를 보존하고 설명하지 않은 상품 주장이나 통계를 만들지 않도록 했다.
- Swift debug 빌드와 diff whitespace 검사 통과. 기존 렌더·취소·가져오기 경로는 바꾸지 않아 직전 57개 렌더 통합 검사 결과를 재사용한다.
- 실제 Claude+Chrome 추가 검증 2건: **물의 순환 교육 인포그래픽** (29,565ms, 4,499바이트, 파랑/흰색, 한국어 단계명)과 **가상 한줄 노트 앱 홍보** (27,448ms, 4,358바이트, 검정/보라 네온, 폰 모형). 각각 샘플 4장이 생성됐고 `audio(t)`가 0을 반환한다. 서로 다른 주제·스타일·장면을 시각 확인했으며 승인 전 전체 영상이 없는 것도 검사했다.
- 원본 검증 job: `.build/generation-support/generated-videos/7C37D130-1468-40B4-96B0-602D3A7B975E`, `.build/generation-support/generated-videos/EECD0794-E0D2-42DB-8C21-C2F76866E04B`.
- 최종 release 빌드와 `/Applications/EasyCut.app` 설치 완료. 설치 실행 파일이 최종 ZIP의 실행 파일과 일치한다. 실제 앱에서 상단 **영상 만들기** 버튼으로 새 화면을 열어 빈 설명란·범용 예시 4종·접힌 고급 설정·새 생성 버튼을 확인했다. 길이를 21초로 바꾸고 제품 홍보 예시를 눌러도 21초가 유지되는 것을 확인한 뒤 빈 설명·20초로 되돌려 두었다.
- 설치 스크립트가 정상 종료 반환 직후 앱 프로세스를 너무 빨리 검사해 중단되는 사례를 확인했다. 강제 종료 없이 최대 10초(0.2초 간격) 종료를 기다리도록 보완했다. 취소 및 상태 조회 오류는 계속 설치 중단으로 처리한다. `bash -n`과 실제 최종 설치 성공을 확인했다.
