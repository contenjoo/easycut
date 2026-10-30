# 영상 생성 프로세스 회귀 검사

macOS와 Python 3이 필요합니다. 프로젝트 루트에서 실행합니다. 실제 `GenerationProcess.swift`를 최소 의존성 stub과 함께 컴파일하며 renderer·Claude 계정·앱 실행은 필요하지 않습니다.

```sh
xcrun swiftc -module-cache-path /private/tmp/easycut-generation-test-modules Sources/EasyCut/AI/GenerationProcess.swift Tests/VideoGeneration/GenerationProcessRegression.swift -o /private/tmp/easycut-generation-process-tests
/private/tmp/easycut-generation-process-tests /private/tmp
```

첫 번째 인자는 임시 작업 폴더의 상위 경로이며 생략할 수 있습니다. 실행마다 고유 하위 폴더를 만들고 정리합니다. Python 경로를 지정하려면 `EASYCUT_TEST_PYTHON=/path/to/python3` 환경변수를 사용합니다.

1MB stdin·1.5MB stdout·8MB stderr 동시 처리, 재사용, stdout 2MB 제한, 오류 진단, 타임아웃, 실행 전 취소를 확인합니다. `cancel()`과 `Task.cancel()`은 SIGTERM을 무시하는 손자 프로세스와 부모가 먼저 종료된 경우에도 전체 그룹을 종료해야 합니다. 고유 heartbeat 파일로 생존 여부를 확인하며, 회귀 시 정리는 이 검사가 생성한 정확한 자식 PID에만 적용합니다. 성공 시 마지막 줄은 `FAILURES 0`입니다.
