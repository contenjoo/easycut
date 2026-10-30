# EasyCut 1.13.0 — 설명으로 새 영상 만들기

원하는 내용을 적고 애니메이션·설명·홍보 영상을 만들 수 있습니다. 상단 **영상 만들기**에서 사용할 AI와 화면비·길이를 정하고, 미리보기 4장을 확인한 뒤 전체 영상을 렌더링하세요. 완성한 MP4는 타임라인에 추가해 편집할 수 있습니다.

- **Claude·GPT는 구독 로그인 또는 API 키**, **Gemini는 API 키**로 사용합니다. 사용자마다 본인 계정을 연결하며, API 키는 해당 Mac의 키체인에 저장합니다. 구독 방식은 본인 계정의 사용 한도를 따르고, API 요금은 구독료와 별도입니다.
- Claude 구독은 Claude 계정으로, GPT 구독은 ChatGPT 계정으로 로그인합니다. API 키로 인증한 CLI를 구독 로그인으로 처리하지 않습니다. 구독 CLI의 개인 설정·연결 도구를 끄고 장면 코드만 받은 뒤 이 Mac에서 렌더링합니다.
- 영상 제작 품질을 우선한다면 현재 **Claude Opus 5.5**를 가장 권장합니다. EasyCut의 권장 설정이며, 모든 모델의 품질을 비교 측정했다는 의미는 아닙니다.
- 프롬프트에 맞춰 제품·브랜드 모션, 설명, 타이포, 데이터 이야기, 입자·패턴 아트의 다섯 가지 제작 지침 중 필요한 것을 자동 적용합니다. 선택 이유와 원본 링크도 확인할 수 있습니다.
- 사용자가 지정한 주제·스타일·색상·문구·무음 여부를 우선합니다. 특정 스타일이나 장소는 고정하지 않습니다.
- 미리보기에서 확인한 코드와 설정으로 렌더링합니다. 생성한 클립을 타임라인에 추가한 뒤 실행 취소할 수 있습니다.
- 처음 렌더 도구를 설치하다 중단한 경우 다시 설치를 시도하도록 복구 처리를 개선했습니다.

영상 생성은 이번 **macOS 버전**에서 제공합니다. 한 번에 2~60초이며 Node.js·npm과 Chrome이 필요합니다. Canvas 방식은 배경음악·효과음을 코드로 합성할 수 있고, Remotion 방식은 기본 무음입니다. 내레이션은 별도로 추가할 수 있습니다.

Gemini 구독 로그인은 지원하지 않습니다. Google의 [개인 계정 Gemini CLI 지원 중단 안내](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)와 [Antigravity의 타사 앱 연결 제한](https://antigravity.google/docs/faq)에 따라 Gemini API로 연결합니다.

Windows 정식 최신 버전은 [0.6.3](https://github.com/contenjoo/easycut/releases/tag/win-v0.6.3)입니다.

[macOS 1.13.0 내려받기](https://github.com/contenjoo/easycut/releases/download/v1.13.0/EasyCut-1.13.0.dmg) · [사용 안내](https://contenjoo.github.io/easycut/)
