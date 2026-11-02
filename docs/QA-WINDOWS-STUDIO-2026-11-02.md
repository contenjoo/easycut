# Windows 0.8.0 폰트·효과·UI 검증

2026-11-02 작업. macOS에서 완성한 효과 선택 방식을 Windows Tauri 앱에 구현했다. 이 문서의 로컬 검사는 macOS 호스트에서 수행했으며, Windows 설치본·WebView2·Windows GDI 글꼴 열거를 검증했다는 의미는 아니다.

## 구현

- 전환 18종, 텍스트 등장 효과 15종, 필터 9종. `none`/원본 항목은 개수에서 제외한다. macOS와 JSON 식별자를 공유하고, 알 수 없는 미래 속성도 보존한다.
- 기본/효과/배치 탭, 이름·아이콘·선택 표시가 있는 카드, 고정된 시간·강도·효과 재생 버튼, 시작/끝 전환 선택.
- Windows GDI로 실제 설치된 글꼴 계열을 조회한다. 검색·한글 별칭·미리보기·재시도와 명시적인 시스템 기본 글꼴 대체를 제공한다. 폰트 다운로드는 하지 않는다.
- 미디어/미리보기와 타임라인/속성의 세 영역, 핵심 도구와 더 보기 메뉴. 최소 콘텐츠 크기 1100×680.
- 클립과 자막의 미리보기 및 FFmpeg/ASS 내보내기. 원본 트랙 순서, PIP 경계, 클릭 강조와 최상위 자막 합성을 보존한다. Unicode grapheme 단위 타이핑을 사용한다.
- UI·AI·MCP가 같은 효과 입력 검증을 사용한다. 잘못된 복합 편집은 일부만 적용하지 않는다. 부분 스타일 변경에서 글꼴과 미래 필드를 보존한다. 자르기/이어붙이기는 바깥쪽 전환을 보존한다.

## 완료한 로컬 검사

- `EASYCUT_EFFECT_FFMPEG=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg cargo test --workspace -- --nocapture`: Rust 49개 통과. 이 중 실제 FFmpeg 검사는 모든 전환의 시작/끝 픽셀 변화와 완료 상태, 모든 필터의 변화와 강도 0, 모든 텍스트 효과, 텍스트 전환, 트랙 순서, 숨긴 트랙, 클릭 위 자막, 작은 PIP의 와이프/원형 전환을 실제 MP4 출력으로 확인했다. 로그: `/private/tmp/easycut-windows-studio-final-rust.log`.
- Node 효과·컨트롤 검사 16개 통과. 모든 효과 목록, 시간/방향/경계, 한글·결합 이모지, 폰트 이름 escaping, 재생 시계 중복, 개인정보 마스크와 픽셀 전환을 검사했다.
- 기존 자연어 편집 파서 12개 통과. 영상 생성 worker 14개 통과, Windows 전용 1개는 호스트에서 건너뜀.
- 실제 HTML/CSS/JS를 headless Chrome에서 구동한 UI 흐름 8개 통과. Tauri 명령은 모의 backend를 사용했다. 효과 선택/시간/되돌리기, 시작·끝 전환/해제, 재생, 폰트 검색/선택/포커스, 필터 강도, 두 화면 크기, 자막 IME, 폰트 조회 실패/재시도를 확인했다. 페이지/콘솔 오류 및 외부 요청 0.
- 화면과 manifest: `output/windows-studio-20261102/`. 이 증거는 Windows 네이티브 실행 증거가 아니다.

## 렌더러 차이

Windows CSS/FFmpeg와 macOS CoreImage/텍스트 렌더러는 픽셀 단위로 동일하지 않다. Windows 내보내기 flip은 원근감을 근사한 압축, blur는 다중 샘플 확산, 글자 wipe는 ASS/캔버스 clipping을 사용한다. 개인정보 가림이 활성화된 동안 미리보기의 픽셀 전환은 원본 재샘플링을 생략하고 가림을 유지한다. 내보내기는 가린 영상에 효과를 적용한다.

Windows runner에서 실행할 `studio-native.cjs`를 추가했다. 모의 backend 없이 실제 GDI 글꼴 조회, 효과 저장, 두 화면 크기의 WebView2 UI와 실제 MP4 출력을 확인하도록 기존 Windows workflow에 연결했다. NSIS 빌드, 설치/자체 검사 및 기존 녹화·Whisper·MCP·영상 생성 회귀 검사도 같은 workflow가 수행한다.

## 실제 Windows 검증 완료

사용자가 검토용 브랜치 한 번의 push 차단 예외와 `publishRelease=false` Windows workflow 실행을 승인했다. 검토 커밋 `1ea8b9d9cf3ac658513a7f323cfd504e9e90cee9`를 `codex/windows-studio-0.8.0`에 전송하고 [Windows 빌드 41456096875](https://github.com/contenjoo/easycut/actions/runs/41456096875)를 실행했다. 후처리를 포함한 전체 실행은 `success`로 완료됐다.

- Windows Rust 검사 50개, 효과·컨트롤 Node 16개, 기존 자연어 파서 12개, worker 15개 및 모든 효과의 실제 FFmpeg 출력 검사 통과. Windows GDI 설치 글꼴 열거도 실제 OS에서 확인했다.
- 실제 Canvas·Remotion 미리보기/렌더 통과. NSIS 설치 파일 빌드 통과.
- 실제 음성의 Whisper 받아쓰기와 앱 자체 검사, 실행 중 앱의 MCP 편집 통과.
- NSIS로 실제 설치한 앱의 자체 검사와 제작 리소스 포함 확인 통과.
- 별도 devtools 빌드의 네이티브 WebView2 녹화·자연어 편집·영상 제작·폰트/효과 UI 검사 통과. `studio-native.cjs`는 실제 Rust 명령으로 효과·시간·폰트 저장, 1440×900/1100×680 콘텐츠 크기 및 MP4 출력을 확인했다. 설치 폰트 154개를 조회하고 Arial을 선택했다.
- 공개 릴리스 단계는 `skipped`. 운영 main·태그는 변경하지 않았으며 원본 HEAD/index를 보존했다. 0.8.0은 검토용 설치 파일이다.

[설치 파일 artifact](https://github.com/contenjoo/easycut/actions/runs/41456096875/artifacts/13147743075): `EasyCut-Windows-setup` ZIP 안의 `EasyCut_0.8.0_x64-setup.exe`. ZIP은 63,727,769바이트다. GitHub가 보고한 **ZIP archive** digest는 `sha256:506347d29a51cce88d32a52cb50b54af8a9968009633bf1166d3a24d19136bb5`다. 내부 EXE의 별도 해시로 해석하지 않는다.

[네이티브 UI 증거](https://github.com/contenjoo/easycut/actions/runs/41456096875/artifacts/13146959667)와 [영상 생성 증거](https://github.com/contenjoo/easycut/actions/runs/41456096875/artifacts/13148317130)를 같은 실행에 보관했다. 생산용 설치 파일에는 devtools를 켜지 않았다. 유료 모델 호출 없이 통제된 생성 응답을 사용한 검사이며 실제 모델의 결과 품질을 보장하지 않는다.
