# EasyCut 개발 규칙

- 사용자에게 표시되는 macOS 앱은 `/Applications/EasyCut.app` 하나로 유지한다.
- `scripts/build_app.sh`는 임시 앱 번들을 만들고 종료 시 정리한다. 보관할 빌드는 `dist/EasyCut.app.zip`과 DMG를 사용한다. 설치는 `--install`, 개발 재실행은 `scripts/relaunch.sh`를 사용한다.
- 별도 이름이나 bundle ID로 만든 테스트 앱도 사용 후 `ditto -c -k --sequesterRsrc --keepParent`로 ZIP에 보관하고, 압축 검증 후 앱 번들을 정리한다. `dist`나 `.build/dmg`에 실행 가능한 앱 사본을 남기지 않는다.
- 실행 중인 앱은 강제 종료하지 않는다. 저장 확인창을 거쳐 정상 종료하며, 사용자가 취소하면 설치를 중단한다.
