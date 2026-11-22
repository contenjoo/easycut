# Browser media regressions complement the installed WebView2/editor test.
$ErrorActionPreference = 'Stop'
$env:NODE_PATH = "$env:RUNNER_TEMP/easycut-ui-tests/node_modules"
$env:EASYCUT_CHROME = "$env:ProgramFiles/Google/Chrome/Application/chrome.exe"
$env:FFMPEG = "$env:LOCALAPPDATA/EasyCut/resources/bin/ffmpeg.exe"
if (!(Test-Path "windows/app/ui/camera-backgrounds/runtime/vision_bundle.mjs")) {
    npm ci --prefix windows/app
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare local camera assets' }
}
foreach ($test in @('camera-background-recording', 'record-background', 'camera-backgrounds')) {
    node "windows/app/tests/$test.cjs"
    if ($LASTEXITCODE -ne 0) { throw "$test failed" }
}
