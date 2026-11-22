# Both Windows builds must use the same validated RTMP preset reader.
$ErrorActionPreference = 'Stop'
$archive = Join-Path $env:RUNNER_TEMP 'easycut-ffmpeg-8.0.1.zip'
$destination = Join-Path $env:RUNNER_TEMP 'easycut-ffmpeg-8.0.1'
$source = 'https://github.com/GyanD/codexffmpeg/releases/download/8.0.1/ffmpeg-8.0.1-essentials_build.zip'
$sha256 = 'e2aaeaa0fdbc397d4794828086424d4aaa2102cef1fb6874f6ffd29c0b88b673'
Invoke-WebRequest $source -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $sha256) {
    throw 'FFmpeg archive failed SHA-256 verification'
}
Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
$bundle = Join-Path $destination 'ffmpeg-8.0.1-essentials_build'
$resources = Join-Path $PSScriptRoot '../app/src-tauri/resources'
New-Item -ItemType Directory -Force -Path "$resources/bin", "$resources/licenses" | Out-Null
Copy-Item "$bundle/bin/ffmpeg.exe", "$bundle/bin/ffprobe.exe" "$resources/bin"
Copy-Item "$bundle/LICENSE" "$resources/licenses/FFmpeg-LICENSE.txt"
