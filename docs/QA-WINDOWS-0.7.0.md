# Windows 0.7.0 영상 제작 검증

Windows 상단 **영상 만들기**, 파일 메뉴와 AI 탭에서 자유 프롬프트로 제작을 시작한다. Claude·GPT는 구독 로그인/API 키를, Gemini는 API 키를 지원한다. 검토된 다섯 지침 중 설명에 맞는 최대 세 개를 선택하고, 네 장의 미리보기 확인 후 같은 소스·설정으로 MP4를 렌더링한다.

## 로컬 검증

- Rust workspace 검사 38개 통과. Windows 전용 JobObject 후손 종료 검사는 Windows CI에서 실행한다.
- worker 검사 14개 통과. Windows npm `.cmd` → 공식 Node 스크립트 검사 한 개는 Windows CI에서 실행한다.
- 자연어 편집 파서 12개 기존 검사 통과.
- 실제 Chrome·FFmpeg로 Canvas/Remotion 각각 640×360, 30fps, 2초 MP4 생성. 한글·공백 경로, 네 장의 결정적 프레임, 승인 전 전체 출력 부재, 소스·스킬 변경 시 렌더 거부, 완료 MP4 재사용을 확인했다. Canvas 오디오 트랙/Remotion 무음 출력도 ffprobe로 확인했다.

## Windows CI 필수 검사

`.github/workflows/windows.yml`은 다음 단계가 성공한 후에만 정식 설치 파일을 게시한다.

- Windows Rust 전체 검사, JobObject 부모 종료 전후 손자 프로세스 정리, Windows worker 검사.
- 실제 Chrome/Edge·FFmpeg의 Canvas/Remotion 미리보기와 전체 렌더링.
- NSIS 설치 파일 빌드, 앱 자체 검사, 실행 중 앱의 MCP 편집, 실제 음성 녹화/Whisper 받아쓰기.
- 조용한 설치 후 설치 앱 자체 검사와 생성 리소스 포함 확인.
- 별도 devtools 빌드의 실제 WebView2 화면에서 공급자·연결 방식·자격 증명 관리자·입력 보존·미리보기·승인·오류/재시도·중지·최소 창 크기와 타임라인 추가/되돌리기.

생산용 설치 파일에는 devtools를 활성화하지 않는다. CI의 모델 응답은 고정된 검사 데이터이며 유료 API나 개인 구독 계정을 호출하지 않는다. 실제 모델의 영상 품질이나 사용자의 Windows PC 환경을 검증했다는 의미는 아니다. API별 인증 헤더·응답 해석·오류 비노출은 단위 검사로 확인한다.

## 배포와 업데이트

정식 태그는 `win-v0.7.0`이다. Windows 앱은 `win-v*` 릴리스에서 최신 설치 파일을 찾는다. macOS 자동 업데이트가 사용하는 GitHub의 latest는 `v1.13.0`에 유지한다. NSIS 설치 파일과 네이티브 UI/렌더 증거는 해당 Actions 실행에 보관한다.
