param([ValidateSet('Fixture','Pick','Save','Focus','FocusApp','Screenshot')][string]$Action, [string]$Value)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes
$fixtureTitle = 'OK Cut QA Source Window'
if ($Action -eq 'Fixture') {
    $form = New-Object Windows.Forms.Form
    $form.Text = $fixtureTitle
    $form.Width = 880
    $form.Height = 540
    $form.StartPosition = 'CenterScreen'
    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.Left = 110
    $label.Top = 50
    $label.ForeColor = [Drawing.Color]::White
    $label.Font = New-Object Drawing.Font('Segoe UI',25)
    $label.BackColor = [Drawing.Color]::Transparent
    $form.Controls.Add($label)
    $script:phase = 0
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 900
    $timer.Add_Tick({
        $script:phase++
        $form.BackColor = if ($script:phase % 2) { [Drawing.Color]::FromArgb(26,70,242) } else { [Drawing.Color]::FromArgb(236,27,56) }
        $label.Text = "$fixtureTitle / Frame $script:phase"
    })
    $form.Add_Shown({ $timer.Start() })
    [Windows.Forms.Application]::Run($form)
    exit
}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VmInput {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
'@
function Screenshot($Path) {
    $rect = [Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [Drawing.Bitmap]::new($rect.Width, $rect.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$rect.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
function Click($Element) {
    $rect = $Element.Current.BoundingRectangle
    if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) { throw "Element not visible: $($Element.Current.Name)" }
    [VmInput]::SetCursorPos([int]($rect.Left + $rect.Width/2),[int]($rect.Top + $rect.Height/2)) | Out-Null
    [VmInput]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
    [VmInput]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
function Foreground {
    $h = [VmInput]::GetForegroundWindow()
    if ($h -ne [IntPtr]::Zero) { [Windows.Automation.AutomationElement]::FromHandle($h) }
}
function Children($Root) {
    $Root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
}
function Save-Tree($Root,$Path) {
    $rows = foreach ($item in (Children $Root)) {
        try {
            [pscustomobject]@{ name=$item.Current.Name; type=$item.Current.ControlType.ProgrammaticName; id=$item.Current.AutomationId; enabled=$item.Current.IsEnabled }
        } catch {}
    }
    $rows | ConvertTo-Json -Depth 4 | Set-Content $Path -Encoding UTF8
}
if ($Action -eq 'Screenshot') { Screenshot $Value; exit }
if ($Action -eq 'Focus') {
    $shell = New-Object -ComObject WScript.Shell
    if (!$shell.AppActivate($fixtureTitle)) { throw 'Fixture window cannot be activated' }
    exit
}
if ($Action -eq 'FocusApp') {
    $shell = New-Object -ComObject WScript.Shell
    if (!$shell.AppActivate([int]$Value)) { throw 'Installed app window cannot be activated' }
    Start-Sleep -Milliseconds 300
    Write-Host "Foreground window: $((Foreground).Current.Name)"
    exit
}
$deadline = (Get-Date).AddSeconds(22)
$last = $null
while ((Get-Date) -lt $deadline) {
    $root = Foreground
    $last = $root
    if (!$root) { Start-Sleep -Milliseconds 250; continue }
    $items = @(Children $root)
    if ($Action -eq 'Pick') {
        $share = $items | Where-Object { $_.Current.Name -match '^(Share|공유)$' -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button } | Select-Object -First 1
        if ($share) {
            Screenshot (Join-Path $env:OKCUT_EVIDENCE 'screen-picker.png')
            $windowTab = $items | Where-Object { $_.Current.Name -match '^(Window|창)$' -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::TabItem } | Select-Object -First 1
            $tile = $items | Where-Object { $_.Current.Name -like "*$fixtureTitle*" -and !$_.Current.IsOffscreen } | Select-Object -First 1
            if (!$tile -and $windowTab) {
                Click $windowTab
                Start-Sleep -Milliseconds 700
                $items = @(Children $root)
                $tile = $items | Where-Object { $_.Current.Name -like "*$fixtureTitle*" -and !$_.Current.IsOffscreen } | Select-Object -First 1
            }
            Save-Tree $root (Join-Path $env:OKCUT_EVIDENCE 'screen-picker-tree.json')
            if ($tile) {
                Click $tile
                Start-Sleep -Milliseconds 300
                if ($share.Current.IsEnabled) {
                    Screenshot (Join-Path $env:OKCUT_EVIDENCE 'window-selected.png')
                    Click $share
                    Write-Host "Selected real capture source: $fixtureTitle"
                    exit
                }
            }
        }
    } else {
        $save = $items | Where-Object { $_.Current.Name -match '^(Save|저장)$' -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.AutomationId -eq '1' } | Select-Object -First 1
        if ($save) {
            $file = $items | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and $_.Current.AutomationId -eq '1001' } | Select-Object -First 1
            if (!$file) { $file = $items | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and $_.Current.Name -match 'File name|파일 이름' } | Select-Object -First 1 }
            if ($file) {
                $valuePattern = $file.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
                $valuePattern.SetValue($Value)
                Click $save
                exit
            }
        }
    }
    Start-Sleep -Milliseconds 400
}
if ($last) { Save-Tree $last (Join-Path $env:OKCUT_EVIDENCE "$Action-last-window.json") }
Screenshot (Join-Path $env:OKCUT_EVIDENCE "$Action-failed.png")
throw "Unable to complete native $Action dialog on the Windows VM"
