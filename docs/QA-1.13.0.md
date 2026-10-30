# EasyCut 1.13.0 (26) 출시 검사

- macOS 영상 만들기: Claude 구독/API, ChatGPT 구독(Codex)/GPT API, Gemini API.
- 실제 구독 인증과 API 키 인증을 구분하며 API 호출은 명시적으로 선택한 키로만 전송한다.
- 새 GPT 구독 요청은 API 모델명을 강제하지 않고 계정이 지원하는 Codex 기본 모델을 사용한다.
- 최종 영상 생성 검사 153개 통과. API 고정 endpoint·헤더 인증·응답/오류/취소, 구독 인증 분리, 스킬 선택, 설치 중단 복구, 실제 Canvas/Remotion 2초 렌더, 스킬/소스 승인 무결성과 타임라인 실행 취소를 포함한다. 로그: /private/tmp/easycut-subscriptions-tests-final.log.
- 실제 Claude Opus 5.5 구독에서 네 가지 장르의 스킬 선택과 미리보기 4장씩 확인. 실제 ChatGPT 구독에서도 스킬 선택, 코드 작성, 미리보기 4장 생성 통과(37FEA6B9-315F-4557-B647-515225531391). 단순한 요청에는 불필요한 스킬을 적용하지 않았다.
- Claude/GPT/Gemini API는 실제 과금 키가 없어 모의 HTTP 검사로 확인했다. 실제 API 호출의 결과 품질은 미검증이다.
- 다른 Remotion 서버가 3000 포트에서 동작 중인 개발 환경에서 localhost가 그 서버에 연결되는 현상을 확인했다. IPv4·IPv6 모두 비어 있는 고포트를 매 렌더에 명시해 격리한 뒤 실제 Remotion 검사 전체 통과. 외부 작업과 캐시는 보존했다.
- 공개 안내의 2~60초 범위와 앱 Stepper를 일치시켰다.
- 배포 ZIP의 버전 1.13.0(26), ZIP 무결성과 출처 고지 포함, 설치 앱과 ZIP 바이너리 SHA256 일치를 확인했다.
- 사용자에게 표시되는 앱은 /Applications/EasyCut.app 하나이며 실행 앱은 강제 종료하지 않았다.
- EasyCut 웹사이트의 설명/FAQ/구조화 데이터와 한국어·영어 README를 새 연결 방식과 Mac1.13.0/Win0.6.3 다운로드에 맞췄다. Windows 생성 기능은 출시 범위에 포함하지 않는다.

## 정식 배포 자산

```text
a761e37c635b3ef170ec550ab5177840da0595617c02ecc8ed77eec1933ba9b2  EasyCut-1.13.0.dmg
c8a70e092ccef15e185a9bce7d7a102a9e72a44632945361d8daeb3e0a8ad1f5  EasyCut.app.zip
```

설치 앱의 오래된 리소스가 남지 않도록 번들을 통째로 교체하고, 기존 앱은 검증한 ZIP으로 보관한 뒤 새 앱의 코드 서명을 확인한다. 실제 설치·서명 검사 통과. 설치한 화면에서 Claude 구독/API, GPT 구독/API, Gemini API 및 GPT 구독 연결 상태를 확인했다.
