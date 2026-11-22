# Disposable GitHub-hosted Windows runner. The signed/installed app is never rebuilt.
param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][ValidateSet("suite", "local", "private", "background")][string]$Mode
)
$ErrorActionPreference = "Stop"
$exe = (Resolve-Path $Executable).Path
$appName = [IO.Path]::GetFileName($exe)
if ($appName -ine "easycut-windows.exe") { throw "Unexpected EasyCut executable" }
$eventKey = $null
if ($Mode -eq "private") {
    $eventKey = $env:EASYCUT_PRIVATE_LIVE_TEST_KEY
    if (-not $eventKey) { throw "Missing single-event destination" }
    Remove-Item Env:EASYCUT_PRIVATE_LIVE_TEST_KEY
}
$env:NODE_PATH = "$env:RUNNER_TEMP/easycut-ui-tests/node_modules"
$env:EASYCUT_NATIVE_OUTPUT = "$env:RUNNER_TEMP/native-evidence"
$env:WEBVIEW2_USER_DATA_FOLDER = "$env:RUNNER_TEMP/broadcast-webview-$Mode"
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9222 --autoplay-policy=no-user-gesture-required"
New-Item -ItemType Directory -Force $env:EASYCUT_NATIVE_OUTPUT | Out-Null
$backup = @()
$app = $null
try {
    # Elevated WebView2 hosts can ignore environment-only overrides. Both windows
    # must use the same app-scoped policy, arguments, and isolated profile.
    $settings = @{
        UserDataFolder = $env:WEBVIEW2_USER_DATA_FOLDER
        AdditionalBrowserArguments = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
    }
    foreach ($entry in $settings.GetEnumerator()) {
        $path = "SOFTWARE\Policies\Microsoft\Edge\WebView2\$($entry.Key)"
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($path)
        try {
            $exists = $key.GetValueNames() -contains $appName
            $backup += @{path=$path; existed=$exists; value=$key.GetValue($appName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); kind=$(if ($exists) { $key.GetValueKind($appName) })}
            $key.SetValue($appName, $entry.Value, [Microsoft.Win32.RegistryValueKind]::String)
        } finally { $key.Dispose() }
    }
    # Terminate only a runner-owned copy started by this install or earlier test.
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -ieq $exe } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $_.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
    }
    $app = Start-Process $exe -PassThru
    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        if ($app.HasExited) { throw "EasyCut exited before opening the editor (exit $($app.ExitCode))" }
        try {
            $pages = Invoke-RestMethod "http://127.0.0.1:9222/json/list" -TimeoutSec 1
            if ($pages | Where-Object { $_.type -eq "page" -and $_.url -match "^https?://tauri\.localhost/" }) { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "EasyCut editor was unavailable on its runner-local CDP endpoint" }
    if ($Mode -eq "suite") {
        foreach ($script in @("natural-edit-native.cjs","generation-native.cjs","studio-native.cjs","broadcast-ui.cjs")) {
            node "windows/app/tests/$script"
            if ($LASTEXITCODE -ne 0) { throw "$script failed" }
        }
    }
    if ($Mode -eq "background") {
        node windows/app/tests/broadcast-native.cjs --camera-background
    } elseif ($Mode -eq "private") {
        # The app, browser, FFmpeg and diagnostics never inherit the one-event credential.
        $env:EASYCUT_PRIVATE_LIVE_TEST_KEY = $eventKey
        node windows/app/tests/broadcast-native.cjs --private-youtube
    } else {
        node windows/app/tests/broadcast-native.cjs
    }
    if ($LASTEXITCODE -ne 0) { throw "Broadcast verification failed" }
} finally {
    Remove-Item Env:EASYCUT_PRIVATE_LIVE_TEST_KEY -ErrorAction SilentlyContinue
    $eventKey = $null
    if ($app -and -not $app.HasExited) {
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $app.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    foreach ($entry in $backup) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($entry.path, $true)
        try {
            if ($entry.existed) { $key.SetValue($appName, $entry.value, $entry.kind) }
            else { $key.DeleteValue($appName, $false) }
        } finally { $key.Dispose() }
    }
}
