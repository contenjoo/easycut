# macOS 전환·텍스트 효과 검증 (2026-11-02)

## 구현 범위

- 클립 시작·끝 전환 8종: 페이드, 슬라이드 4방향, 와이프 2방향, 확대·축소. 소리 페이드는 기존 설정을 사용한다.
- 제목·전체 자막 등장 효과 5종: 서서히 나타나기, 아래에서 올라오기, 위에서 내려오기, 팝업, 타이핑.
- 효과 시간 조절, 타임라인 전환 구간 표시, AI/MCP 설정·조회, 실행 취소·다시 실행.
- 타이핑은 한글·결합 이모지를 Character 단위로 표시하며 전체 문장의 줄바꿈·박스 크기를 유지한다.
- 새 저장 필드는 optional이며 기존 프로젝트는 효과 없이 열린다. 분할 시 내부 경계의 새 전환은 만들지 않고, 합치기는 바깥 전환을 보존한다.
- 미리보기·내보내기가 같은 합성 엔진을 사용한다. Windows 구현과 공개 릴리스는 이번 작업 범위에 포함하지 않았다.

## 검사 결과

- Debug/Release 빌드 통과.
- 효과 회귀 검사 57개 통과: 기존 파일 호환성, 저장 왕복, 짧은 클립 제한, 분할·합치기, AI 입력 검증·실행 취소, 전환·텍스트 실제 픽셀, 이모지·외곽선 숨김, 자막별 효과 재시작 포함.
- 생성 이미지·제목·자막으로 실제 3초 320×180 H.264 MP4 출력. 5시점의 미리보기 대비 평균 RGB 오차는 0.004~0.027(0~1)로 허용 기준 0.035 이내.
- 기존 타임라인 회귀 검사 33개 통과.
- 배속·자막 검사 21개 통과: 말소리 시작 3곳 모두 자막과 50ms 이내, 영상 트랙 10.000초.
- 배속 검사 첫 실행은 MP4 전체 길이 10.068333초여서 기존 60ms 기준에 1건 실패했다. 영상 트랙은 10.000초였고 음성 싱크는 통과했다. 업데이트 전 설치본은 전체 10.025초였으며 같은 새 바이너리·입력의 재실행도 전체 10.025초로 통과했다. 오디오 트랙의 인코딩 끝 여유분 차이를 관찰했으며 관련 제품 코드나 검사 기준은 변경하지 않았다.
- 설치 앱에서 실제 메뉴로 타이핑→팝업, 시작 와이프→페이드 선택, 효과 시간 0.70→0.84초 변경, 실행 취소로 원래 값 복원을 확인했다.
- `/Applications/EasyCut.app` 정상 설치·재실행, 코드 서명 검증 및 ZIP 무결성 검사 통과. ZIP 안 실행 파일과 설치 실행 파일 SHA256 일치.
- `dist`와 `.build`에 실행 가능한 `.app` 번들을 남기지 않았다. 보관물은 ZIP·DMG다.

## 실행 기록

```sh
swift build -c debug
EASYCUT_SELFTEST_ONLY=effects .build/debug/EasyCut --selftest /private/tmp/easycut-effects-20261102
EASYCUT_SELFTEST_ONLY=natural .build/debug/EasyCut --selftest /private/tmp/easycut-effects-regression
EASYCUT_SELFTEST_ONLY=speed-caption .build/debug/EasyCut --selftest /private/tmp/easycut-effects-speed
./scripts/build_app.sh --dmg --install
./scripts/relaunch.sh /private/tmp/easycut-effects-20261102/effects.easycut
```

로그: `/private/tmp/easycut-effects-test.log`, `/private/tmp/easycut-effects-timeline.log`, `/private/tmp/easycut-effects-speed-repeat.log`, `/private/tmp/easycut-effects-package.log`.
