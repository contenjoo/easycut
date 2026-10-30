# Windows 0.7.0 영상 제작 검증

Windows 상단 **영상 만들기**, 파일 메뉴와 AI 탭에서 자유 프롬프트로 제작을 시작한다. Claude·GPT는 구독 로그인/API 키를, Gemini는 API 키를 지원한다. 검토된 다섯 지침 중 설명에 맞는 최대 세 개를 선택하고, 네 장의 미리보기 확인 후 같은 소스·설정으로 MP4를 렌더링한다.

## 로컬 검증

- Rust 코어 31개와 앱 검사 9개 통과. Windows 전용 JobObject 후손 종료 검사는 아래 Windows CI에서 별도로 확인했다.
- worker 검사 14개 통과. Windows npm `.cmd` → 공식 Node 스크립트 검사 한 개는 Windows CI에서 실행한다.
- 자연어 편집 파서 12개 기존 검사 통과.
- 실제 Chrome·FFmpeg로 Canvas/Remotion 각각 640×360, 30fps, 2초 MP4 생성. 한글·공백 경로, 네 장의 결정적 프레임, 승인 전 전체 출력 부재, 소스·스킬 변경 시 렌더 거부, 완료 MP4 재사용을 확인했다. Canvas 오디오 트랙/Remotion 무음 출력도 ffprobe로 확인했다.

## Windows CI 필수 검사

[영상 제작 집중 검사](https://github.com/contenjoo/easycut/actions/runs/41014603645)는 2026-10-30에 전체 통과했다. Windows Rust 41개, worker 15개, 실제 Canvas·Remotion 렌더와 네이티브 WebView2 전체 제작 흐름을 확인했다.

- 실제 Windows 자격 증명 관리자에서 Claude·GPT·Gemini 검사 키를 저장·재조회하고 입력칸에서 지운다.
- Claude/GPT의 구독/API 선택과 Gemini API, 입력 보존·예시·다섯 스킬·미리보기 승인·변경 후 재승인·취소·오류/재시도를 검증한다.
- 1100×580 WebView 화면에서도 닫기·미리보기 실행 버튼이 보인다.
- 실제 Rust → worker → 검사용 Codex CLI 응답 → 스킬 1개 선택 → 1280×720/24fps/2초 미리보기 4장 → 승인 MP4/오디오 → 실제 생성 영상 가져오기 → 실행 취소로 에셋·클립 모두 0개가 되는 흐름을 확인한다. 모델 응답만 고정 데이터이며 나머지 경로는 실제 앱 코드다.
- Windows 확장 경로를 Node 20에 직접 넘기면 `EISDIR`로 실패하는 점을 재현했다. 외부 Node 스크립트 인자만 일반 Windows 경로로 변환해 앱의 제작 도구 시작 오류를 수정했다. [Node 공식 이슈](https://github.com/nodejs/node/issues/62446)

집중 검사는 `windows.yml`의 `generationOnly=true`로 실행한다. 실제 배포는 `generationOnly=false`, `publishRelease=true`로 실행하며 별도 설치·기존 편집 검사까지 모두 통과해야 게시한다.

## 정식 설치 파일 검증

[실제 설치본 검사](https://github.com/contenjoo/easycut/actions/runs/41019425928)는 전체 통과했다. 새 검사용 바이너리를 만들지 않고, 배포할 NSIS 파일을 설치해 그 앱에서 같은 영상 제작·미리보기·승인·렌더·가져오기·실행 취소 검사를 수행했다.

- 생성 출처: [Windows 설치 파일 빌드](https://github.com/contenjoo/easycut/actions/runs/41015222762), 생산 소스 `515fec5b6aab15b1a72b94ea028113e57e76a551`. 해당 실행에서 Rust·worker·렌더·NSIS·설치 후 자체 검사·MCP·기존 녹화/Whisper/편집 UI 단계가 통과했다. 생성 UI 검사의 언어 설정은 테스트 코드에서 보정해 위 설치본 검사로 검증했다.
- 설치본 검사는 현재 소스의 생산 코드가 원본과 동일한지 Git diff로 확인하고, GitHub artifact ZIP digest와 내려받은 ZIP 해시를 대조했다. 소스 변경 없이 같은 설치 파일을 재사용했다.
- 파일: `EasyCut_0.7.0_x64-setup.exe`, 63,669,873바이트.
- NSIS SHA256: `046699521e58e5b88fbbaba302b834309f358fb865917d98c12a6b01a994c052`.
- 설치된 앱 EXE SHA256: `9d81fa8920836e23f78f049f2f70274110de8283ebc2633520a93f346c608ca3`.
- Windows 관리자 CI의 WebView2 보안 정책을 고려해 해당 테스트 앱의 HKLM 값만 임시 설정하고 검사 종료 시 원복했다. 배포 EXE와 설치 파일은 변경하지 않았다.

`installerRunId=41015222762`, `generationOnly=true`로 동일 설치 파일 검증을 재현할 수 있다. 이 모드는 새 파일 게시 없이 검증 증거만 남긴다.

`.github/workflows/windows.yml`은 다음 단계가 성공한 후에만 정식 설치 파일을 게시한다.

- Windows Rust 전체 검사, JobObject 부모 종료 전후 손자 프로세스 정리, Windows worker 검사.
- 실제 Chrome/Edge·FFmpeg의 Canvas/Remotion 미리보기와 전체 렌더링.
- NSIS 설치 파일 빌드, 앱 자체 검사, 실행 중 앱의 MCP 편집, 실제 음성 녹화/Whisper 받아쓰기.
- 조용한 설치 후 설치 앱 자체 검사와 생성 리소스 포함 확인.
- 별도 devtools 빌드의 실제 WebView2 화면에서 공급자·연결 방식·자격 증명 관리자·입력 보존·미리보기·승인·오류/재시도·중지·최소 창 크기와 타임라인 추가/되돌리기.

생산용 설치 파일에는 devtools를 활성화하지 않는다. CI의 모델 응답은 고정된 검사 데이터이며 유료 API나 개인 구독 계정을 호출하지 않는다. 실제 모델의 영상 품질이나 사용자의 Windows PC 환경을 검증했다는 의미는 아니다. API별 인증 헤더·응답 해석·오류 비노출은 단위 검사로 확인한다.

## 배포와 업데이트

정식 태그는 `win-v0.7.0`이다. Windows 앱은 `win-v*` 릴리스에서 최신 설치 파일을 찾는다. macOS 자동 업데이트가 사용하는 GitHub의 latest는 `v1.13.0`에 유지한다. NSIS 설치 파일과 네이티브 UI/렌더 증거는 해당 Actions 실행에 보관한다.
