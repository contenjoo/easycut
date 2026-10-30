# EasyCut 영상 제작 스킬 자동 적용

2026-10-30에 원본 저장소와 공개 검색 색인을 확인했다. 애니메이션·설명·홍보 영상에 필요한 제작 지침을 EasyCut의 Canvas/Remotion 실행 방식에 맞게 요약·변형했다. 원본 스킬의 코드, 설치 명령, 실행 스크립트, 폰트·이미지·음원 및 별도 런타임은 포함하지 않는다.

## 앱에서 적용하는 방식

`VideoGenerationSkills.swift`의 고정 로컬 카탈로그 5개가 대상이다. 기본으로 켜진 **제작 스킬 자동 적용**을 사용하면 요청마다 선택한 AI가 프롬프트의 의미와 의도를 읽고 0~3개를 선택한다. 관련 없는 스킬, 부정한 스타일 언급, 단순한 날짜·길이·숫자만으로 스킬을 고르지 않도록 지시한다. 선택된 제작 지침만 소스 생성 프롬프트에 전달한다.

선택 ID는 카탈로그와 대조하며 알 수 없는 ID·중복·3개 초과 등 잘못된 응답은 거부한다. 카탈로그 버전, 선택된 지침·출처·수정본 및 선택 이유를 작업 폴더의 `applied-skills.json`에 저장한다. 자동 적용을 끈 요청도 해당 상태를 기록한다. 이 스냅샷은 미리보기 무결성 검사에 포함된다.

사용자가 지정한 주제·스타일·속도·정확한 문구·무음·텍스트 없음·원테이크 요청을 우선한다. 스킬이 앱의 렌더러·크기·fps·시간이나 허용된 의존성을 바꾸지 않는다. 기존처럼 **미리보기 4장 → 사용자 확인 → 같은 코드로 전체 렌더링**을 거친다.

이 기능은 고정 카탈로그에서 선택한다. X를 자동 크롤링하거나 요청마다 새 스킬을 내려받지 않으며, 임의의 GitHub/X 링크에서 스크립트나 패키지를 설치·실행하지 않는다.

## 영상 제작 AI 선택

**영상 만들기 → 영상 제작 AI**에서 Claude, GPT, Gemini를 선택한다. Claude와 GPT는 **구독 로그인 / API 키** 연결 방식을 고를 수 있고, Gemini는 API 키로 연결한다. 사용자마다 본인 계정이나 키를 사용한다. `VideoGenerationAPI.swift`와 `VideoGenerator.swift`의 기본 모델 및 연결 방식은 다음과 같다.

| 선택 | 앱의 기본 모델 | 연결 |
|---|---|---|
| Claude · 구독 | `claude-opus-5-5` | Claude Code CLI의 Claude 계정 로그인. API 키 인증과 구분한다. |
| Claude · API | `claude-opus-5-5` | Anthropic Messages API, `https://api.anthropic.com/v1/messages` |
| GPT · 구독 | `gpt-6.1-sol` | Codex CLI의 ChatGPT 계정 로그인. API 키 인증과 구분한다. |
| GPT · API | `gpt-6.1-sol` | OpenAI Responses API, `https://api.openai.com/v1/responses` |
| Gemini · API | `gemini-3.8-flash` | Gemini generateContent, `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` |

세 공급자 모두 API 키를 저장하고 API 모델 이름을 직접 바꿀 수 있다. 선택 모델을 해당 API 계정에서 사용할 수 있어야 한다. 구독 방식은 본인 Claude 또는 ChatGPT 계정의 사용 한도를 따르며, API 방식은 해당 API 계정의 모델 접근 권한·할당량·요금을 따른다. Claude Opus 5.5의 정확한 ID는 [공식 모델 문서](https://platform.claude.com/docs/en/models/opus-5-5/overview)에서 확인했다. [Claude Code 모델 설정](https://code.claude.com/docs/en/model-config)에 따르면 Opus 5.5에는 CLI v2.1.280 이상이 필요하다.

구독 인증은 CLI가 설치되어 있다는 사실만으로 성공 처리하지 않는다. `AgentLink.subscriptionStatus`는 Claude의 `auth status --json` 결과에서 `loggedIn: true`와 `authMethod: claude.ai`를 확인하고, Codex의 `login status` 결과는 ChatGPT 로그인이어야 하며 API 키 로그인을 거절한다. 구독 선택 상태에서 API 키 인증으로 조용히 전환해 호출하지 않는다. 로그인 버튼은 필요한 공식 CLI 준비와 브라우저 계정 로그인을 진행한다.

구독 CLI에도 개인 편집 설정이나 도구를 연결하지 않는다. Claude는 도구·설정 소스를 끄고 빈 MCP 구성을 사용한다. Codex는 개인 설정·프로젝트 규칙을 제외하고 셸·앱·플러그인·후크·기억·브라우저 등의 기능을 끈 읽기 전용 요청으로 실행한다. 두 경우 모두 장면 코드 응답만 받으며, 실제 프레임과 MP4는 EasyCut이 정한 렌더 과정으로 만든다.

Gemini 구독 로그인은 제공하지 않는다. Google은 [공식 폐기 안내](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)에서 2026-06-18부터 Gemini CLI의 개인 무료·Google AI Pro·Ultra 계정 접근이 중단되었다고 알렸다. 후속 Antigravity도 [공식 FAQ](https://antigravity.google/docs/faq)에서 소비자 플랜의 headless CLI를 타사 앱이나 코딩 에이전트로 감싸 사용하는 방식을 지원하지 않는다고 명시한다. EasyCut은 이 구독 연결을 추가하지 않고 Gemini API를 사용한다.

화면의 **“영상 제작 품질을 우선한다면 현재 Claude Opus 5.5를 가장 권장합니다”**는 EasyCut의 기본 권장 안내다. 이번 작업에서 공급자별 영상 품질을 비교 측정해 우열을 입증했다는 의미가 아니다. GPT도 [공식 코드 생성 가이드](https://developers.openai.com/api/docs/guides/code-generation)에 안내된 현행 모델군을 사용할 수 있다. Gemini 기본 모델의 stable 상태와 기능은 [Gemini 3.8 Flash 공식 문서](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash)에서 확인했다.

모든 연결 방식은 같은 카탈로그와 생성 계약을 사용한다. 자동 적용을 켜면 **선택한 공급자·모델이 스킬 선택을 한 번 수행한 뒤, 선택 지침을 받아 코드 생성을 한 번 수행**한다. 자동 적용을 끄면 스킬 선택 요청을 건너뛴다. `request.json`에 공급자·연결 방식·모델·자동 적용 설정을 저장하고, 스킬 스냅샷과 생성 소스를 보존한다. API로 바꾸어도 이후 미리보기·승인·로컬 렌더링 과정은 같다.

Claude API는 도구 없이 Messages API에 프롬프트를 보내고 JSON으로 답하도록 요청한다. 응답의 `text` 블록만 읽으며 thinking 블록, 거절·토큰 상한·도구 사용 등으로 끝난 결과는 코드로 실행하지 않는다. [Anthropic Messages API](https://platform.claude.com/docs/en/api/messages)를 참고했다. GPT API는 JSON 출력 모드를 사용하며 응답의 `output`에서 메시지의 `output_text`를 모은다. 완료되지 않은 응답과 refusal은 거부한다. [OpenAI 텍스트 생성](https://developers.openai.com/api/docs/guides/text), [구조화 출력](https://developers.openai.com/api/docs/guides/structured-outputs)을 참고했다. Gemini API는 `responseMimeType: application/json`을 요청하고 첫 candidate의 `thought`가 아닌 텍스트만 읽는다. 차단·미완료·토큰 상한 종료는 실패로 처리한다. [Gemini generateContent REST 참조](https://ai.google.dev/api/generate-content)를 참고했다. 세 API 모두 받은 내용에 기존 JSON·생성 코드 계약 검사를 다시 적용한다.

## API 키와 과금

API 키는 macOS 키체인에 보관한다. Claude는 기존 `Keychain.service`, GPT는 `com.contenjoo.easycut.openai`, Gemini는 기존 `GeminiClient.keychainService`를 사용한다. 구독 로그인 정보와 API 키는 연결 방식에 따라 따로 확인하며, 키를 `request.json`, 생성 소스 또는 스킬 스냅샷에 저장하지 않는다. API 요청은 고정된 공식 호스트만 사용하고 HTTP 리디렉션을 따르지 않는다.

**Claude·GPT·Gemini API는 구독료와 별도로 모델별 API 사용량에 따른 요금이 발생할 수 있다.** 스킬 선택과 코드 생성은 각각 요청이므로 자동 적용을 켠 API 작업에는 두 요청의 사용량이 발생한다. 구독 방식의 작업은 본인 구독 계정의 사용 한도를 적용한다. OpenAI API 결제는 ChatGPT 구독 결제와 별개다. [OpenAI 결제 안내](https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform)에서 확인할 수 있다. Gemini에는 모델·프로젝트별 무료 한도와 유료 구간이 있으며 실제 비용·한도는 [Gemini 결제 안내](https://ai.google.dev/gemini-api/docs/billing) 및 [요금표](https://ai.google.dev/gemini-api/docs/pricing)를 따른다. 앱이 API 키만으로 유료 계정·사용 가능한 모델을 보장하지는 않는다.

## 카탈로그와 원본

| ID / 화면 이름 | EasyCut에 맞춘 내용 | 원본 / 고정 수정본 / 라이선스 |
|---|---|---|
| `motion-design` / 제품·브랜드 모션 | 한 박자에 한 생각, 의미 있는 움직임, 읽기 시간과 여백, 사용자 요청에서 색과 속도 결정. 제품·성과를 임의로 만들어 내지 않음. | [cskwork motion-graphics SKILL.md](https://github.com/cskwork/motion-graphics-skill/blob/6670b8cc41648fc6b70ecdd8fbb8b04a22fb82ea/skills/motion-graphics/SKILL.md), `6670b8cc41648fc6b70ecdd8fbb8b04a22fb82ea`, MIT |
| `visual-explainer` / 이해를 돕는 설명 | 원인·변화·결과를 물체의 행동으로 전달. 공간과 주인공의 연결을 유지하고 필요한 요소를 순차로 공개. | [Bang Motion explainer.md](https://github.com/bangtutorial/bang-motion/blob/c1aa65e921c970d858705fcb4a53a8294d1a4131/references/explainer.md), `c1aa65e921c970d858705fcb4a53a8294d1a4131`, MIT |
| `kinetic-type` / 움직이는 타이포 | 문구의 의미에 맞춘 등장·정지·퇴장, 두 단계 이내 글자 위계, 한글·문장부호 보존. 글자 없는 요청에는 사용하지 않음. | [Bang Motion SKILL.md](https://github.com/bangtutorial/bang-motion/blob/c1aa65e921c970d858705fcb4a53a8294d1a4131/SKILL.md), 같은 수정본, MIT |
| `data-story` / 숫자·데이터 이야기 | 제공된 수치·단위와 일관된 축을 사용하고 시간 보간 후 정확한 값에 고정. 예시 수치는 허용된 경우에만 예시로 표시. | [Remotion interpolate 공식 문서](https://www.remotion.dev/docs/interpolate)를 참고해 EasyCut이 자체 작성. `reviewed-2026-10-30`. 원본 스킬/예시 코드 미포함. |
| `generative-art` / 입자·패턴 아트 | 주제에 맞는 입자·흐름·반복 패턴을 일정한 규칙과 팔레트로 구성. 모든 프레임이 인덱스와 시간에서 재현되도록 변환. p5.js/인터랙티브 뷰어 사용 안 함. | [Anthropic algorithmic-art SKILL.md](https://github.com/anthropics/skills/blob/ca45fc496a3436251f191354091d557da31c15b5/skills/algorithmic-art/SKILL.md), `ca45fc496a3436251f191354091d557da31c15b5`, Apache-2.0 |

검토한 추가 자료: [cskwork Shorts](https://github.com/cskwork/motion-graphics-skill/blob/6670b8cc41648fc6b70ecdd8fbb8b04a22fb82ea/skills/motion-graphics/formats/shorts.md), [cskwork launch video](https://github.com/cskwork/motion-graphics-skill/blob/6670b8cc41648fc6b70ecdd8fbb8b04a22fb82ea/skills/motion-graphics/formats/launch-video.md), [Bang Motion opener concepts](https://github.com/bangtutorial/bang-motion/blob/c1aa65e921c970d858705fcb4a53a8294d1a4131/references/opener-konsep.md), [Remotion vertical bar chart](https://convert.remotion.dev/elements/data/vertical-bar-chart/), [Remotion pie chart](https://convert.remotion.dev/elements/data/pie-chart/).

## X에서 발견한 내용과 확인 범위

- [Remotion 공식 X 게시물](https://x.com/Remotion/status/2013626968386765291)은 공개 검색 색인에 반복적으로 연결되어 있었다. X 원문 직접 열기는 403으로 실패했다. 실제 스킬 기능은 [Remotion 공식 문서](https://www.remotion.dev/docs/ai/skills)와 [원본 저장소](https://github.com/remotion-dev/skills)에서 확인했다.
- [Bang Motion을 공유한 @vintcessun 게시물](https://x.com/vintcessun/status/2099791342373347377)은 [Trendshift 공개 X 언급 색인](https://trendshift.io/repositories/218990)에서 2026-09-15 공유와 정확한 게시물 링크를 확인했다. X 원문 직접 열기는 Cache miss로 실패했다. 제작 지침과 라이선스는 위의 고정 GitHub 수정본에서 직접 확인했다.
- cskwork와 Anthropic은 GitHub 원본으로 확인한 후보다. 두 스킬의 특정 X 공유 게시물을 직접 확인했다고 주장하지 않는다.
- X 검색 결과의 인기·완성 영상만으로 호환성을 판정하지 않았다. HyperFrames처럼 별도 엔진을 요구하는 원본은 이번 연결 대상에서 제외했다.

## 검증과 설치

- 자동 선택·기존 요청 호환·API 요청/응답·오류·취소·Canvas/Remotion 실제 2초 렌더·승인 이후 스킬 변경 감지·타임라인 실행 취소를 포함한 119개 검사가 통과했다. API HTTP 검사는 전용 URLProtocol이 가로채며 실제 키나 외부 통신을 쓰지 않았다. 로그: `/private/tmp/easycut-video-providers-tests.log`.
- 실제 Claude Code로 물의 순환 설명(`visual-explainer`, `kinetic-type`), 텀블러 홍보(`motion-design`, `kinetic-type`), 무문자 입자 아트(`generative-art`), 대출량 그래프(`data-story`)를 각각 선택하고 미리보기 4장씩 생성했다. 10·20·30권의 그래프 값과 한글을 직접 확인했다. 이 미리보기 작업에서는 전체 렌더를 실행하지 않았다.
- 최종 설치 앱에서도 프롬프트 입력부터 스킬 자동 선택, 선택 이유·원본 링크, 미리보기 4장과 승인 버튼까지 확인했다. 작업 `126F4F10-49BA-489D-AFEC-AFA30D7BD5AD`의 `modelUsage`는 `claude-opus-5-5`이며 생성 코드는 사용자 Application Support 폴더에 저장된다.
- 일반 사용자를 위한 Claude/GPT/Gemini 선택, 본인 API 키의 보안 입력·키체인 저장 안내·발급 안내 링크·모델 설정·별도 과금 안내를 확인했다. 확인한 Mac에는 GPT/Gemini 키가 없어 두 API의 실제 과금 호출은 미검증이다. 각 사용자는 자신의 계정과 키로 사용한다.
- `scripts/build_app.sh --install`로 `/Applications/EasyCut.app`에 설치했다. 코드 서명 검증, ZIP 무결성, 설치 바이너리와 ZIP의 SHA256 일치, 출처 고지 포함을 확인했다. `dist`와 `.build/dmg`에는 실행 가능한 앱 사본이 없다. 빌드 ZIP은 `dist/EasyCut.app.zip`이다. 공개 릴리스는 수행하지 않았다.

## 출처 고지

`Resources/VideoSkillNotices.txt`에 MIT 두 원본의 저작권·허가 고지 및 Anthropic의 저작권·Apache-2.0 전체 라이선스를 포함한다. 요약·변형한 지침임을 표시하고 각 카드에 원본 링크와 수정본을 보존한다.

`remotion-dev/skills`의 확인 수정본은 `30d4553ecd46fbc5212fd0ff006ae43af522158b`다. 이 저장소는 확인 시 GitHub API의 라이선스 필드가 비어 있고 트리에 LICENSE 파일이 없었다. MIT라고 표시하거나 원본 문서를 번들에 복제하지 않았다. `data-story`는 공식 문서를 참고한 EasyCut 자체 지침으로 구분한다. Remotion 실행 도구 자체의 이용 조건과 이 제작 지침의 출처는 별개다.
