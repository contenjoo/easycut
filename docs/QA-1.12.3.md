# EasyCut 1.12.3 (22) 자막 한글 입력 검증

## 변경

- 왼쪽 목록과 오른쪽 편집칸이 같은 native NSTextView 기반 편집기를 사용한다.
- 조합·삽입·삭제가 끝난 직후 실제 문자열을 공유 자막에 전달한다.
- 같은 모델 값의 재반영과 marked text 재설정으로 입력이 되돌아가는 것을 막는다.
- 포커스를 잃을 때 조합을 확정하고, 외부 수정 반영 중 이전 값의 재발행을 막는다.
- 목록 행 데이터는 고정된 자막 UUID를 사용한다.

## 실제 macOS 앱 검증

설치 위치: `/Applications/EasyCut.app`. 한글 내용을 붙여넣거나 AX 값으로 설정하지 않고,
두벌식 입력기에서 CGEvent 물리 키코드의 down/up 이벤트로 입력했다.
키 전송 뒤 실제 접근성 문자열을 읽어 각 키의 처리를 확인했다.

- 왼쪽: `dkssudgktpdy gksrmf wkakrdlqslek` → `안녕하세요 한글 자막입니다`
- 왼쪽 겹받침: `rkqtdl djqttmqslek` → `값이 없습니다`
- 오른쪽: `gksrmf wkakr dlqfur ghkrdls` → `한글 자막 입력 확인`
- 끝 공백 없이 입력한 마지막 글자와 포커스 이동 후 양쪽 일치 확인.
- 전체 선택·Delete로 빈 자막을 만들고 두 입력칸이 비며 자막 1개가 유지되는지 확인.
- 빈 자막에 다시 전체 문장을 입력해 양쪽 일치 확인.
- 프로젝트 저장 파일 JSON의 자막이 `안녕하세요 한글 자막입니다`와 정확히 일치함을 확인.
- 새 프로젝트로 전환 후 저장 프로젝트를 실제 열기 창으로 다시 열어 양쪽 문장이 유지되는지 확인.

검증 프로젝트: `/tmp/easycut-1.12.3-korean-final-verified.easycut`.

## 회귀 검사

`EASYCUT_SELFTEST_ONLY=caption-text .build/arm64-apple-macosx/release/EasyCut --selftest /tmp/easycut-1.12.3-tests`

자막 텍스트·바인딩·native IME 검사 23개 통과.

## 산출물

- `dist/EasyCut-1.12.3.dmg`
- SHA256: `7699c6f74a9ade378f2630957546a0ac11188981ea10243386c7ddcddc36c459`
- 보관 앱: `dist/EasyCut.app.zip`. 빌드·설치용 임시 앱 번들은 정리한다.
