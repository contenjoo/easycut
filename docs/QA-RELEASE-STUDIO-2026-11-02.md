# Mac 1.14.0 / Windows 0.8.0 업데이트 준비

사용자 요청: 폰트·효과·전환과 단순한 UI를 Mac·Windows 전체에 업데이트한다. 공개 최신 버전은 확인 시점에 Mac 1.13.0, Windows 0.7.0이었다.

## 설치·패키지 검증

- Mac 버전을 1.14.0, bundle build를 27로 올렸다. `/Applications/EasyCut.app` 하나에 정상 종료 절차를 거쳐 설치하고 다시 실행했다. 이전 앱은 `dist/EasyCut-before-1.14.0-install.app.zip`으로 보관했다.
- 설치된 앱으로 효과 검사 205개와 실제 MP4 출력/미리보기 비교를 다시 통과했다. 로그: `/private/tmp/easycut-release-1.14.0-effects.log`. 기존 효과/UI와 타임라인 검증은 [상세 기록](QA-STUDIO-UI-2026-11-02.md)을 재사용했다.
- 앱 서명 검증, ZIP CRC, DMG checksum 검증 통과. ZIP 안의 앱 버전·실행 파일 해시가 실제 설치본과 일치한다. 임시 `.app` 번들은 빌드 종료 시 정리됐다.
- Windows는 새로 빌드하지 않고 [전체 성공한 실행 41456096875](https://github.com/contenjoo/easycut/actions/runs/41456096875)의 설치 artifact 13147743075를 그대로 사용한다. [실제 Windows 검증](QA-WINDOWS-STUDIO-2026-11-02.md): Rust 50개, 효과 Node 16개, 파서 12개, worker 15개, NSIS 실제 설치·Whisper·MCP·영상 생성·네이티브 WebView2 폰트/효과/MP4 확인.
- GitHub artifact ZIP SHA256 `506347d29a51cce88d32a52cb50b54af8a9968009633bf1166d3a24d19136bb5` 일치. 내부 `EasyCut_0.8.0_x64-setup.exe`는 63,728,869바이트, SHA256 `21bda00580718a0f8a17f10d81f92d8da598c98a6010415ffde8f9ef83d2cbd3`. 다운로드는 사용자 지정 Drive 임시 다운로드 폴더에서 처리했다.
- 해시와 출처: `output/release-20261102/release-manifest.json`. Mac은 `dist/SHA256SUMS.txt`, Windows는 `output/release-20261102/windows/SHA256SUMS.txt`를 준비했다.

## 업데이트 경로와 게시 준비

- Mac 자동 업데이트는 GitHub `/releases/latest`에서 DMG를 찾는다. 새 Mac 릴리스를 latest로 지정해야 1.13.0 이하 사용자가 받는다.
- Windows는 `win-v*` 릴리스 중 설치 파일이 있는 가장 큰 버전을 찾는다. Windows 0.8.0은 `latest=false`로 게시해 Mac의 latest 채널을 유지한다. 검증한 Windows 소스 커밋은 `1ea8b9d9cf3ac658513a7f323cfd504e9e90cee9`다.
- Mac/Windows 릴리스 노트, README 한·영문, 소개 페이지의 버전·다운로드 링크·효과 안내를 준비했다. 과거 영상 생성 도입 버전 안내는 유지했다.
- 저장소 main 반영은 Pages 웹사이트를 배포한다. 바이너리 게시 후 main을 반영해야 공개 페이지의 새 다운로드 링크가 먼저 노출되지 않는다.
- 기존 원본 HEAD/index와 미커밋 변경을 보존하며 별도 검토 체크포인트를 만든다. 현재 공개 게시·main 반영은 아직 실행하지 않았다. 사용자 지정 push/운영 배포 차단 설정에 대한 최종 범위 승인이 필요하다.
