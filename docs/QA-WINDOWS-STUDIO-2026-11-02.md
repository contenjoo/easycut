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

## 차이와 검증 대기

Windows CSS/FFmpeg와 macOS CoreImage/텍스트 렌더러는 픽셀 단위로 동일하지 않다. Windows 내보내기 flip은 원근감을 근사한 압축, blur는 다중 샘플 확산, 글자 wipe는 ASS/캔버스 clipping을 사용한다. 개인정보 가림이 활성화된 동안 미리보기의 픽셀 전환은 원본 재샘플링을 생략하고 가림을 유지한다. 내보내기는 가린 영상에 효과를 적용한다.

Windows runner에서 실행할 `studio-native.cjs`를 추가했다. 모의 backend 없이 실제 GDI 글꼴 조회, 효과 저장, 두 화면 크기의 WebView2 UI와 실제 MP4 출력을 확인하도록 기존 Windows workflow에 연결했다. NSIS 빌드, 설치/자체 검사 및 기존 녹화·Whisper·MCP·영상 생성 회귀 검사도 같은 workflow가 수행한다.

현재 Windows 네이티브 빌드·설치 파일 생성은 대기 중이다. 저장소의 사용자 지정 pre-push guard가 프로젝트 push를 차단하므로, 검토용 브랜치 한 번의 push와 `publishRelease=false` Windows workflow 실행 승인이 필요하다. 운영 main 병합·태그·공개 릴리스는 수행하지 않았다. 원본 작업 트리와 index는 보존한다.
