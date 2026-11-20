$ErrorActionPreference = 'Stop'
$zip = Join-Path $env:RUNNER_TEMP 'VBCABLE_Driver_Pack45.zip'
$folder = Join-Path $env:RUNNER_TEMP 'vm-audio-test-cable'
curl.exe -fLsS --retry 2 https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip -o $zip
if ($LASTEXITCODE -ne 0) { throw 'Audio fixture driver download failed' }
if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne 'b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb') {
    throw 'Unexpected audio fixture driver ZIP digest'
}
Expand-Archive $zip -DestinationPath $folder
$inf = Join-Path $folder 'vbMmeCable64_win10.inf'
$signature = Get-AuthenticodeSignature (Join-Path $folder 'vbaudio_cable64_win10.cat')
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
    throw "Audio fixture driver catalog verification failed: $($signature.Status) $($signature.SignerCertificate.Subject)"
}
# Register a root-enumerated lab device for the hardware ID published in the signed INF.
# Leave Windows driver signature enforcement in effect.
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AudioFixtureDevice {
    [StructLayout(LayoutKind.Sequential)]
    private struct Info {
        public int Size;
        public Guid ClassGuid;
        public int DevInst;
        public IntPtr Reserved;
    }
    [DllImport("setupapi.dll", SetLastError=true)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid guid, IntPtr hwnd);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool SetupDiCreateDeviceInfo(IntPtr list, string name, ref Guid guid, string description, IntPtr hwnd, uint flags, ref Info info);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool SetupDiSetDeviceRegistryProperty(IntPtr list, ref Info info, uint property, byte[] value, uint length);
    [DllImport("setupapi.dll", SetLastError=true)]
    private static extern bool SetupDiCallClassInstaller(uint command, IntPtr list, ref Info info);
    [DllImport("setupapi.dll")]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr list);
    [DllImport("winmm.dll")] public static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll")] public static extern uint waveOutGetNumDevs();
    private static void Check(bool ok) {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void Register() {
        Guid media = new Guid("4d36e96c-e325-11ce-bfc1-08002be10318");
        IntPtr list = SetupDiCreateDeviceInfoList(ref media, IntPtr.Zero);
        Check(list != new IntPtr(-1));
        try {
            Info info = new Info();
            info.Size = Marshal.SizeOf(typeof(Info));
            Check(SetupDiCreateDeviceInfo(list, "VBAudioVACWDM", ref media, null, IntPtr.Zero, 1, ref info));
            byte[] id = System.Text.Encoding.Unicode.GetBytes("VBAudioVACWDM\0\0");
            Check(SetupDiSetDeviceRegistryProperty(list, ref info, 1, id, (uint)id.Length));
            Check(SetupDiCallClassInstaller(0x19, list, ref info));
        } finally { SetupDiDestroyDeviceInfoList(list); }
    }
}
'@
Start-Service AudioEndpointBuilder
Start-Service Audiosrv
[AudioFixtureDevice]::Register()
pnputil.exe /add-driver $inf /install
if ($LASTEXITCODE -ne 0) { throw "Windows refused to install the signed audio driver: $LASTEXITCODE" }
for ($n=0; $n -lt 30; $n++) {
    if ([AudioFixtureDevice]::waveInGetNumDevs() -gt 0 -and [AudioFixtureDevice]::waveOutGetNumDevs() -gt 0) { break }
    Start-Sleep -Milliseconds 500
}
$endpoints = @(Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue | Select-Object Status,FriendlyName,InstanceId)
$result = @{
    signer=$signature.SignerCertificate.Subject; waveIn=[AudioFixtureDevice]::waveInGetNumDevs();
    waveOut=[AudioFixtureDevice]::waveOutGetNumDevs(); endpoints=$endpoints
}
$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $env:OKCUT_EVIDENCE 'windows-audio-endpoints.json')
$result | ConvertTo-Json -Depth 8 | Write-Host
if ($result.waveIn -eq 0 -or $result.waveOut -eq 0) { throw 'No active audio fixture input and output' }

# The VM has no personal microphones or user data. Enable desktop microphone
# access for this run's test cable so Windows can grant the requested permission.
$microphoneKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged'
)
foreach ($key in $microphoneKeys) {
    $before = Get-ItemPropertyValue -Path $key -Name Value -ErrorAction SilentlyContinue
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name Value -Value Allow -PropertyType String -Force | Out-Null
    Write-Host "Disposable VM microphone setting ($key): $before -> Allow"
}
