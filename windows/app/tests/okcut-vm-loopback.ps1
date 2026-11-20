param(
    [Parameter(Mandatory=$true)][ValidateSet('Restart','Inspect','Toggle')][string]$Mode,
    [ValidateRange(1000,15000)][int]$WaitMs = 7000,
    [string]$EvidencePath
)
$ErrorActionPreference = 'Stop'
$report = [ordered]@{ mode=$Mode; startedUtc=[DateTime]::UtcNow.ToString('o'); events=@(); status='starting' }
$ownProcess = $null
$exitCode = 1
function Record($Stage, $Value) {
    $event = [ordered]@{ stage=$Stage; utc=[DateTime]::UtcNow.ToString('o'); value=$Value }
    $report.events += $event
    Write-Host ($event | ConvertTo-Json -Depth 8 -Compress)
}

try {
    if ($Mode -eq 'Restart') {
        $devices = @(Get-PnpDevice -Class MEDIA -PresentOnly | Where-Object FriendlyName -eq 'VB-Audio Virtual Cable')
        if ($devices.Count -ne 1) { throw "Expected exactly one lab cable device; found $($devices.Count)" }
        $device = $devices[0]
        if ([string]::IsNullOrWhiteSpace($device.InstanceId)) { throw 'Cable device has no instance ID' }
        Record 'before' @{ device=$device | Select-Object Status,FriendlyName,InstanceId; audioService=(Get-Service Audiosrv).Status.ToString() }
        $output = & pnputil.exe /restart-device $device.InstanceId 2>&1
        $pnputilExit = $LASTEXITCODE
        Record 'deviceRestart' @{ exitCode=$pnputilExit; output=($output -join "`n") }
        if ($pnputilExit -ne 0) { throw "pnputil restart failed: $pnputilExit" }
        Restart-Service Audiosrv -Force
        Start-Sleep -Seconds 3
        Record 'readback' @{ device=Get-PnpDevice -InstanceId $device.InstanceId | Select-Object Status,FriendlyName,InstanceId; audioService=(Get-Service Audiosrv).Status.ToString() }
        $report.status = 'restarted'
        $exitCode = 0
    } else {
        if (!$env:RUNNER_TEMP) { throw 'RUNNER_TEMP is required' }
        $control = Join-Path $env:RUNNER_TEMP 'vm-audio-test-cable/VBCABLE_ControlPanel.exe'
        if (!(Test-Path -LiteralPath $control -PathType Leaf)) { throw "Verified fixture control panel is missing: $control" }
        $signature = Get-AuthenticodeSignature -FilePath $control
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^CN=BUREL VINCENT Entrepreneur individuel,|Vincent Burel|VB-Audio)') {
            throw "Unexpected control-panel signature: $($signature.Status) $($signature.SignerCertificate.Subject)"
        }
        $name = [IO.Path]::GetFileNameWithoutExtension($control)
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) {
            throw 'A vendor control panel is already running; refusing to reuse or close another instance'
        }
        Record 'control' @{ path=$control; sha256=(Get-FileHash -LiteralPath $control -Algorithm SHA256).Hash; signer=$signature.SignerCertificate.Subject }
        Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class LoopbackMenuQa {
    const uint Flags = 0x22; // SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT
    [StructLayout(LayoutKind.Sequential)] struct Item {
        public uint cbSize, fMask, fType, fState, wID;
        public IntPtr hSubMenu, hbmpChecked, hbmpUnchecked;
        public UIntPtr dwItemData;
        public IntPtr dwTypeData;
        public uint cch;
        public IntPtr hbmpItem;
    }
    public class MenuState {
        public bool Found, Refreshed, Checked, Disabled;
        public string Text, StateHex, Problem;
        public uint CommandId;
        public int TopPosition, ItemPosition;
        public long Window, Menu;
    }
    public class DispatchResult {
        public bool Posted;
        public int LastError;
        public uint CommandId;
    }
    public class NativeWindow {
        public long Window, Owner;
        public string Title, ClassName;
        public bool Enabled, Visible;
        public List<string> ChildTexts = new List<string>();
    }
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr menu, int index);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", EntryPoint="GetMenuItemInfoW", SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)] static extern bool GetMenuItemInfo(IntPtr menu, uint item, bool byPosition, ref Item info);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", SetLastError=true)]
    static extern IntPtr SendTimeout(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr ReadText(IntPtr hwnd, uint message, UIntPtr wparam, StringBuilder text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", EntryPoint="PostMessageW", SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)] static extern bool Post(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("kernel32.dll")] static extern void SetLastError(uint error);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hwnd, EnumProc callback, IntPtr param);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    public static MenuState Read(IntPtr hwnd) {
        var found = new List<MenuState>();
        IntPtr root = GetMenu(hwnd);
        if (root == IntPtr.Zero) return new MenuState { Problem="No standard HMENU", Window=hwnd.ToInt64() };
        int tops = Math.Min(Math.Max(GetMenuItemCount(root),0),16);
        for (int i=0; i<tops; i++) {
            IntPtr menu = GetSubMenu(root,i);
            if (menu == IntPtr.Zero) continue;
            UIntPtr reply;
            bool refreshed = SendTimeout(hwnd,0x117,menu,new IntPtr(i),Flags,300,out reply) != IntPtr.Zero;
            int count = Math.Min(Math.Max(GetMenuItemCount(menu),0),128);
            for (int j=0; j<count; j++) {
                IntPtr text = Marshal.AllocHGlobal(1024);
                try {
                    var item = new Item { cbSize=(uint)Marshal.SizeOf(typeof(Item)), fMask=0x143, dwTypeData=text, cch=511 };
                    if (!GetMenuItemInfo(menu,(uint)j,true,ref item)) continue;
                    string label = Marshal.PtrToStringUni(text,(int)Math.Min(item.cch,511u));
                    string normalized = label.Replace("&","").Split('\t')[0].Trim();
                    if (!String.Equals(normalized,"Enable Loopback Streaming",StringComparison.OrdinalIgnoreCase)) continue;
                    found.Add(new MenuState { Found=true, Refreshed=refreshed, Checked=(item.fState&8)!=0,
                        Disabled=(item.fState&3)!=0, Text=label, StateHex="0x"+item.fState.ToString("X8"),
                        CommandId=item.wID, TopPosition=i, ItemPosition=j, Window=hwnd.ToInt64(), Menu=menu.ToInt64() });
                } finally { Marshal.FreeHGlobal(text); }
            }
        }
        if (found.Count==1) return found[0];
        return new MenuState { Problem="Expected one exact menu item; found "+found.Count, Window=hwnd.ToInt64() };
    }
    public static DispatchResult Dispatch(IntPtr hwnd, uint id) {
        if (id==0 || id>=0xFFFF) throw new ArgumentException("Unsafe menu command ID");
        SetLastError(0);
        bool posted = Post(hwnd,0x111,new IntPtr(id),IntPtr.Zero); // menu WM_COMMAND, once only
        return new DispatchResult { Posted=posted, LastError=Marshal.GetLastWin32Error(), CommandId=id };
    }
    public static List<NativeWindow> Observe(uint pid) {
        var windows = new List<NativeWindow>();
        var budget = Stopwatch.StartNew();
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            if (budget.ElapsedMilliseconds>2000 || windows.Count>=12) return false;
            uint ownerPid; GetWindowThreadProcessId(hwnd,out ownerPid);
            if (ownerPid!=pid || !IsWindowVisible(hwnd)) return true;
            var title = new StringBuilder(512); GetWindowText(hwnd,title,title.Capacity);
            var cls = new StringBuilder(256); GetClassName(hwnd,cls,cls.Capacity);
            var win = new NativeWindow { Window=hwnd.ToInt64(), Owner=GetWindow(hwnd,4).ToInt64(),
                Title=title.ToString(), ClassName=cls.ToString(), Enabled=IsWindowEnabled(hwnd), Visible=true };
            if (win.ClassName=="#32770" || win.Owner!=0) {
                int children=0;
                EnumChildWindows(hwnd,delegate(IntPtr child,IntPtr ignored) {
                    if (++children>40 || budget.ElapsedMilliseconds>2000) return false;
                    var content=new StringBuilder(512); UIntPtr result;
                    if (ReadText(child,0xD,new UIntPtr(512),content,Flags,75,out result)!=IntPtr.Zero && content.Length>0)
                        win.ChildTexts.Add(content.ToString());
                    return true;
                },IntPtr.Zero);
            }
            windows.Add(win);
            return true;
        },IntPtr.Zero);
        return windows;
    }
    public static bool Close(IntPtr hwnd) { return Post(hwnd,0x10,IntPtr.Zero,IntPtr.Zero); }
}
'@
        $ownProcess = Start-Process -FilePath $control -PassThru
        $ready = [Diagnostics.Stopwatch]::StartNew()
        do {
            $ownProcess.Refresh()
            if ($ownProcess.HasExited) { throw 'The new vendor helper exited before exposing a window' }
            if ($ownProcess.MainWindowHandle -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 150
        } while ($ready.ElapsedMilliseconds -lt 5000)
        $hwnd = $ownProcess.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) { throw 'Vendor helper did not expose a main window' }
        $before = [LoopbackMenuQa]::Read($hwnd)
        Record 'before' $before
        $windows = @([LoopbackMenuQa]::Observe([uint32]$ownProcess.Id))
        Record 'windowsBefore' $windows
        if (!$before.Found -or !$before.Refreshed -or $before.Disabled) { throw 'Menu state is unavailable, unrefreshed, or disabled; no command sent' }
        if ($Mode -eq 'Inspect') {
            $report.status='inspected'; $exitCode=0
        } else {
            $desired = !$before.Checked
            if (@($windows | Where-Object { $_.ClassName -eq '#32770' -or $_.Window -ne $hwnd.ToInt64() -and $_.Owner -ne 0 }).Count -gt 0) {
                $report.status='dialogPresentNoDispatch'; $exitCode=2
            } else {
                $dispatch = [LoopbackMenuQa]::Dispatch($hwnd,$before.CommandId)
                Record 'dispatch' $dispatch
                if (!$dispatch.Posted) { throw "PostMessage failed: $($dispatch.LastError)" }
                $timer=[Diagnostics.Stopwatch]::StartNew()
                $last=$null
                $report.status='unconfirmed'; $exitCode=2
                do {
                    Start-Sleep -Milliseconds 250
                    $ownProcess.Refresh()
                    if ($ownProcess.HasExited) { Record 'helperExited' $ownProcess.ExitCode; break }
                    $state=[LoopbackMenuQa]::Read($hwnd)
                    $key="$($state.Found)|$($state.Refreshed)|$($state.StateHex)|$($state.Problem)"
                    if ($key -ne $last) { Record 'readback' $state; $last=$key }
                    $windows=@([LoopbackMenuQa]::Observe([uint32]$ownProcess.Id))
                    $dialogs=@($windows | Where-Object { $_.ClassName -eq '#32770' -or $_.Window -ne $hwnd.ToInt64() -and $_.Owner -ne 0 })
                    if ($dialogs.Count -gt 0) { Record 'dialogObservedNoClick' $windows; $report.status='dialogObserved'; break }
                    if ($state.Found -and $state.Refreshed -and !$state.Disabled -and $state.Checked -eq $desired) {
                        $report.status='desiredReadBack'; $exitCode=0; break
                    }
                } while ($timer.ElapsedMilliseconds -lt $WaitMs)
                Record 'windowsAfter' ([LoopbackMenuQa]::Observe([uint32]$ownProcess.Id))
            }
        }
    }
} catch {
    $report.status='error'
    $report.error=$_.Exception.Message
    Record 'error' $_.Exception.Message
    $exitCode=1
} finally {
    if ($null -ne $ownProcess) {
        try {
            $ownProcess.Refresh()
            if (!$ownProcess.HasExited) {
                $requested=[LoopbackMenuQa]::Close($ownProcess.MainWindowHandle)
                if (!$ownProcess.WaitForExit(1200)) {
                    # Only the exact helper process created above; no dialog buttons or other apps.
                    $ownProcess.Kill()
                    $ownProcess.WaitForExit(1200) | Out-Null
                    Record 'cleanup' @{ pid=$ownProcess.Id; closePosted=$requested; terminatedOwnHelper=$true }
                } else { Record 'cleanup' @{ pid=$ownProcess.Id; closePosted=$requested; terminatedOwnHelper=$false } }
            }
        } catch { Record 'cleanupError' $_.Exception.Message }
    }
    $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $report.exitCode=$exitCode
    $json=$report | ConvertTo-Json -Depth 12
    if ($EvidencePath) { $json | Set-Content -LiteralPath $EvidencePath -Encoding UTF8 }
    Write-Output $json
}
exit $exitCode
