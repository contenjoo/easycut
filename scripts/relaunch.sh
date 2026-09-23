#!/bin/bash
# 개발용: 다시 빌드하고 앱을 새로 띄운다 (인자: 열 파일들)
cd "$(dirname "$0")/.."
pkill -x EasyCut; sleep 0.5
./scripts/build_app.sh 2>&1 | grep -E "error:|완료" 
open -a "$PWD/dist/EasyCut.app" "$@"
