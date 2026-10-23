#!/bin/bash
# 개발용: 다시 빌드하고 앱을 새로 띄운다 (인자: 열 파일들)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build_app.sh --install
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT open -a /Applications/EasyCut.app "$@"
