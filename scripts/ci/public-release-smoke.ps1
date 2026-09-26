# Smoke-test one downloaded public release asset on an isolated Windows runner.
# This is intended to be copied with public-release-smoke.yml to the release-only
# repository. It owns every process and temporary path it creates.
#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$ChecksumPath,
    [string]$OutputDirectory = '',
    [ValidateRange(5,60)][int]$ReadyTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'SMOKE_WINDOWS_REQUIRED' }
$archive = [IO.Path]::GetFullPath($ArchivePath)
$checksumFile = [IO.Path]::GetFullPath($ChecksumPath)
if (-not [IO.File]::Exists($archive) -or -not [IO.File]::Exists($checksumFile)) { throw 'SMOKE_ASSET_MISSING' }
$archiveName = [IO.Path]::GetFileName($archive)
$line = (Get-Content -LiteralPath $checksumFile -Raw).Trim()
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($line -cne "$hash *$archiveName") { throw 'SMOKE_CHECKSUM_MISMATCH' }
if (([IO.FileInfo]$archive).Length -gt 1073741824L) { throw 'SMOKE_ARCHIVE_SIZE' }
$output = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { Join-Path ([IO.Path]::GetDirectoryName($archive)) 'smoke-output' } else { [IO.Path]::GetFullPath($OutputDirectory) }
if ([IO.Directory]::Exists($output) -or [IO.File]::Exists($output)) { throw 'SMOKE_OUTPUT_EXISTS' }
[void][IO.Directory]::CreateDirectory($output)

$temp = Join-Path ([IO.Path]::GetTempPath()) ('CuteCompanion.ReleaseSmoke.' + [Guid]::NewGuid().ToString('N'))
$extract = Join-Path $temp 'package'
$settings = Join-Path $temp 'settings'
$evidence = Join-Path $temp 'evidence'
[void][IO.Directory]::CreateDirectory($extract)
[void][IO.Directory]::CreateDirectory($settings)
[void][IO.Directory]::CreateDirectory($evidence)
$app = $null
$smokeStatus = 'failed'
$failureType = $null
$png = Join-Path $evidence 'live-01.png'
$settingsPng = Join-Path $evidence 'app-settings.png'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CuteCompanionReleaseSmokeNative
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int processId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
'@

try {
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $total = 0L
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.Contains('\') -or $entry.FullName.StartsWith('/') -or $entry.FullName -match '^[A-Za-z]:' -or
                $entry.FullName.Split('/') -contains '' -or $entry.FullName.Split('/') -contains '..' -or $entry.FullName.EndsWith('/') -or
                (($entry.ExternalAttributes -shr 16) -band 0xf000) -notin @(0, 0x8000) -or $entry.Length -gt 134217728L) { throw 'SMOKE_ARCHIVE_ENTRY' }
            $total += $entry.Length
            if ($total -gt 1073741824L) { throw 'SMOKE_ARCHIVE_SIZE' }
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
    } finally { $zip.Dispose() }

    $appPath = Join-Path $extract 'CuteCompanion.App.exe'
    if (-not [IO.File]::Exists($appPath)) { throw 'SMOKE_APP_MISSING' }
    $scope = [Guid]::NewGuid().ToString('N')
    $info = [Diagnostics.ProcessStartInfo]::new($appPath)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    foreach ($argument in @('--probe-mode','--agent-scope',$scope,'--settings-dir',$settings,'--evidence-dir',$evidence,'--mute')) { $info.ArgumentList.Add($argument) }
    $app = [Diagnostics.Process]::Start($info)
    $created = $app.StartTime.ToFileTimeUtc()
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $readyName = "Local\CuteCompanion.G0.$sid.Probe.$scope.$($app.Id).$created--ui-ready"
    $ready = $false; $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not $ready) {
        if ($app.HasExited) { throw "SMOKE_APP_EXITED_$($app.ExitCode)" }
        $event = $null
        try {
            if ([Threading.EventWaitHandle]::TryOpenExisting($readyName, [ref]$event)) { $ready = $event.WaitOne(0) }
        } finally { if ($null -ne $event) { $event.Dispose() } }
        if (-not $ready) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $ready) { throw 'SMOKE_UI_READY_TIMEOUT' }

    $overlay = [CuteCompanionReleaseSmokeNative]::FindWindow($null, 'CuteCompanion.G0.Overlay')
    if ($overlay -eq [IntPtr]::Zero) { throw 'SMOKE_OVERLAY_MISSING' }
    $overlayPid = 0
    [void][CuteCompanionReleaseSmokeNative]::GetWindowThreadProcessId($overlay, [ref]$overlayPid)
    if ($overlayPid -ne $app.Id) { throw 'SMOKE_OVERLAY_OWNER_MISMATCH' }
    $result = [IntPtr]::Zero
    $sent = [CuteCompanionReleaseSmokeNative]::SendMessageTimeout($overlay, 0x8004, [IntPtr]1, [IntPtr]0, 0x0002, 2000, [ref]$result)
    if ($sent -eq [IntPtr]::Zero -or $result.ToInt64() -ne 1) { throw 'SMOKE_CAPTURE_FAILED' }
    if (-not [IO.File]::Exists($png) -or ([IO.FileInfo]$png).Length -le 8) { throw 'SMOKE_CAPTURE_MISSING' }
    $magic = [IO.File]::ReadAllBytes($png)[0..7]
    if (-not ([Convert]::ToHexString($magic) -ceq '89504E470D0A1A0A')) { throw 'SMOKE_CAPTURE_NOT_PNG' }

    $settingsInfo = [Diagnostics.ProcessStartInfo]::new($appPath)
    $settingsInfo.UseShellExecute = $false; $settingsInfo.CreateNoWindow = $true
    foreach ($argument in @('--settings-capture','--probe-mode','--agent-scope',$scope,'--settings-dir',$settings,'--evidence-dir',$evidence,
            '--expected-pid',$app.Id.ToString([Globalization.CultureInfo]::InvariantCulture),'--expected-created',$created.ToString([Globalization.CultureInfo]::InvariantCulture))) { $settingsInfo.ArgumentList.Add($argument) }
    $settingsCapture = [Diagnostics.Process]::Start($settingsInfo)
    try { if (-not $settingsCapture.WaitForExit(10000) -or $settingsCapture.ExitCode -ne 0) { throw 'SMOKE_SETTINGS_CAPTURE_REQUEST_FAILED' } }
    finally { $settingsCapture.Dispose() }
    if (-not $app.WaitForExit(10000) -or $app.ExitCode -ne 0) { throw 'SMOKE_APP_SHUTDOWN_FAILED' }
    if (-not [IO.File]::Exists($settingsPng) -or ([IO.FileInfo]$settingsPng).Length -le 8) { throw 'SMOKE_SETTINGS_CAPTURE_MISSING' }
    $settingsMagic = [IO.File]::ReadAllBytes($settingsPng)[0..7]
    if (-not ([Convert]::ToHexString($settingsMagic) -ceq '89504E470D0A1A0A')) { throw 'SMOKE_SETTINGS_CAPTURE_NOT_PNG' }
    $smokeStatus = 'pass'
    Write-Output "PASS public release smoke: checksum, isolated launch, UI readiness, PNG capture, and owned shutdown ($archiveName)"
}
catch {
    $failureType = $_.Exception.GetType().Name
    throw
}
finally {
    if ($null -ne $app) {
        try { if (-not $app.HasExited) { $app.Kill($true); [void]$app.WaitForExit(3000) } } catch { }
        $app.Dispose()
    }
    if ([IO.File]::Exists($png)) { [IO.File]::Copy($png, (Join-Path $output 'live-01.png'), $false) }
    if ([IO.File]::Exists($settingsPng)) { [IO.File]::Copy($settingsPng, (Join-Path $output 'app-settings.png'), $false) }
    $captured = Join-Path $output 'live-01.png'
    $settingsCaptured = Join-Path $output 'app-settings.png'
    $captureHash = if ([IO.File]::Exists($captured)) { (Get-FileHash -LiteralPath $captured -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    $settingsCaptureHash = if ([IO.File]::Exists($settingsCaptured)) { (Get-FileHash -LiteralPath $settingsCaptured -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    $appBinary = Join-Path $extract 'CuteCompanion.App.exe'
    [ordered]@{
        schemaVersion = 1
        status = $smokeStatus
        failureType = $failureType
        archive = $archiveName
        archiveSha256 = $hash
        appSha256 = if ([IO.File]::Exists($appBinary)) { (Get-FileHash -LiteralPath $appBinary -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        capture = if ($captureHash) { 'live-01.png' } else { $null }
        captureSha256 = $captureHash
        settingsCapture = if ($settingsCaptureHash) { 'app-settings.png' } else { $null }
        settingsCaptureSha256 = $settingsCaptureHash
        runtimeExecuted = ($smokeStatus -eq 'pass')
        authenticodeTrusted = $false
        completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'smoke-result.json') -Encoding utf8NoBOM
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $tempResolved = [IO.Path]::GetFullPath($temp)
    if ($tempResolved -eq $tempRoot -or -not $tempResolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'SMOKE_TEMP_CONTAINMENT' }
    if ([IO.Directory]::Exists($tempResolved)) { [IO.Directory]::Delete($tempResolved, $true) }
}
