<#
.SYNOPSIS
    Clears browser caches and ALL temp files (however persistent) to free disk space.

.DESCRIPTION
    Portable -- uses environment variables only, works on any Windows user
    account without edits. Covers Chrome, Brave, Edge, Opera, Opera GX,
    Vivaldi, and Firefox caches, plus OS junk: %TEMP%/%TMP%, CrashDumps,
    shader caches, thumbnail cache, Windows Error Reporting, INetCache/
    WebCache, font cache, jump lists, recent items, minidumps.

    Persistence handling (what makes this different from a plain Remove-Item):
      - Strips ReadOnly / Hidden / System attributes before every delete,
        since attribute-protected files are the #1 reason cleanup scripts
        silently leave junk behind.
      - Kills known browser/updater/crash-handler processes that hold locks.
      - Takes ownership + resets ACLs (icacls) on admin-only targets so
        permission-denied files can actually be removed.
      - Anything still locked after all that (open handle from a running
        service, AV scan, etc.) is scheduled for deletion on next reboot
        via the Windows MoveFileEx API -- so it WILL be gone, just not
        instantly, instead of being silently skipped.

    -Aggressive unlocks system-level targets that need Administrator:
    C:\Windows\Temp, Prefetch, Windows Update download cache, Delivery
    Optimization cache, Panther setup logs, every user profile's temp
    folder (not just yours), empties Recycle Bin, flushes DNS cache.

    -DryRun previews what would be deleted without deleting anything.

.PARAMETER Aggressive
    Also clears system-wide junk that requires Administrator privileges,
    including other user profiles' temp folders.

.PARAMETER DryRun
    Show what would be removed without deleting anything.

.PARAMETER SkipBrowsers
    Skip browser cache clearing, junk-folder cleanup only.

.EXAMPLE
    .\Clear-SystemCache.ps1
    Run standard user-level cleanup.

.EXAMPLE
    .\Clear-SystemCache.ps1 -Aggressive
    Run full cleanup including system-level targets (needs admin; run
    PowerShell "as administrator" first, or the script will tell you).

.EXAMPLE
    .\Clear-SystemCache.ps1 -Aggressive -DryRun
    See exactly what an aggressive run would delete, without touching anything.
#>

[CmdletBinding()]
param(
    [switch]$Aggressive,
    [switch]$DryRun,
    [switch]$SkipBrowsers
)

$LogPath = Join-Path $PSScriptRoot "CleanupLog.txt"
try { Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue | Out-Null } catch { }

trap {
    Write-Host ""
    Write-Host "SCRIPT ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    continue
}

$ErrorActionPreference = 'SilentlyContinue'
$Global:LeftoverReport   = @()
$Global:TotalFreedMB     = 0
$Global:RebootScheduled  = @()

# --- Win32 MoveFileEx for "delete on next reboot" fallback ------------------
$MoveFileExSig = @"
using System;
using System.Runtime.InteropServices;
public class NativeReboot {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;
}
"@
if (-not ("NativeReboot" -as [type])) {
    Add-Type -TypeDefinition $MoveFileExSig -ErrorAction SilentlyContinue
}

function Schedule-DeleteOnReboot {
    param([string]$FilePath)
    if ($DryRun) { return }
    try {
        $ok = [NativeReboot]::MoveFileEx($FilePath, $null, [NativeReboot]::MOVEFILE_DELAY_UNTIL_REBOOT)
        if ($ok) { $Global:RebootScheduled += $FilePath }
        return $ok
    } catch { return $false }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Kill-BlockingProcesses {
    # Main + background/helper/updater/crash-handler processes that
    # commonly hold locks on browser profile, cache, or temp files.
    $names = @(
        "chrome", "chrome_proxy", "GoogleCrashHandler", "GoogleCrashHandler64",
        "GoogleUpdate", "GoogleUpdateBroker", "GoogleUpdateOnDemand",
        "brave", "brave_crashpad_handler",
        "msedge", "msedgewebview2", "MicrosoftEdgeUpdate",
        "opera", "opera_crashreporter", "opera_gx",
        "vivaldi",
        "firefox", "plugin-container", "crashreporter",
        "SearchProtocolHost", "SearchFilterHost", "WerFault", "WerFaultSecure",
        "TiWorker"
    )
    foreach ($n in $names) {
        Get-Process -Name $n | Stop-Process -Force
    }
}

function Clear-BlockingAttributes {
    # Strip ReadOnly / Hidden / System attributes so Remove-Item can
    # actually touch them. This alone clears a large share of "stubborn" files.
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Attributes -band ([System.IO.FileAttributes]::ReadOnly -bor
                                   [System.IO.FileAttributes]::Hidden -bor
                                   [System.IO.FileAttributes]::System)) {
            try { $_.Attributes = 'Normal' } catch { }
        }
    }
}

function Take-Ownership {
    # Admin-only: reset ownership + ACLs on a path so permission-denied
    # deletes stop failing. Only used under -Aggressive with admin rights.
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    takeown /F "$Path" /R /D Y 2>$null | Out-Null
    icacls "$Path" /grant "*S-1-5-32-544:F" /T /C /Q 2>$null | Out-Null
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $bytes = (Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    if ($bytes) { return [math]::Round($bytes / 1MB, 2) } else { return 0 }
}

function Remove-PathContents {
    param([string]$Path, [int]$MaxAttempts = 3, [switch]$UseOwnership)
    if (-not (Test-Path $Path)) { return }

    $beforeMB = Get-FolderSizeMB -Path $Path

    if ($DryRun) {
        $count = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue).Count
        Write-Host "[DRY RUN] Would clear: $Path  ($count items, $beforeMB MB)" -ForegroundColor Magenta
        return
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Clear-BlockingAttributes -Path $Path
        Remove-Item "$Path\*" -Recurse -Force -ErrorAction SilentlyContinue
        $leftover = Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $leftover) {
            Write-Host "Cleared: $Path  (freed ~$beforeMB MB)" -ForegroundColor Green
            $Global:TotalFreedMB += $beforeMB
            return
        }
        Write-Host "Locked/protected files remain in $Path (attempt $i)..." -ForegroundColor Yellow
        Kill-BlockingProcesses
        if ($UseOwnership -and $isAdmin) { Take-Ownership -Path $Path }
        Start-Sleep -Seconds 1
    }

    # Final pass: whatever is still standing gets scheduled for deletion on reboot.
    $leftover = Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    $scheduledCount = 0
    foreach ($f in $leftover) {
        if (Schedule-DeleteOnReboot -FilePath $f.FullName) { $scheduledCount++ }
    }

    $afterMB = Get-FolderSizeMB -Path $Path
    $freedMB = [math]::Round($beforeMB - $afterMB, 2)
    if ($freedMB -gt 0) { $Global:TotalFreedMB += $freedMB }

    $stillLeftover = Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue
    if ($scheduledCount -gt 0) {
        Write-Host "Partially cleared: $Path -- $scheduledCount locked file(s) scheduled for delete on next reboot." -ForegroundColor DarkYellow
    }
    if ($stillLeftover) {
        $Global:LeftoverReport += [PSCustomObject]@{
            Folder    = $Path
            ItemCount = $stillLeftover.Count
            SizeMB    = $afterMB
            Sample    = ($stillLeftover | Select-Object -First 5 -ExpandProperty FullName) -join "; "
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host "=== Windows Cache & Temp File Cleaner ===" -ForegroundColor Cyan
if ($DryRun)      { Write-Host "Mode: DRY RUN (nothing will be deleted)" -ForegroundColor Magenta }
if ($Aggressive)  { Write-Host "Mode: AGGRESSIVE (includes system-level targets)" -ForegroundColor Red }
$isAdmin = Test-IsAdmin
if ($Aggressive -and -not $isAdmin) {
    Write-Host ""
    Write-Host "WARNING: -Aggressive was requested but this session is not running as Administrator." -ForegroundColor Red
    Write-Host "System-level targets (Windows\Temp, Prefetch, Windows Update cache, Delivery Optimization," -ForegroundColor Red
    Write-Host "other user profiles' temp folders, ownership takeover) will be skipped." -ForegroundColor Red
    Write-Host "Re-run PowerShell 'as administrator' to include them." -ForegroundColor Red
}

# --- User-level junk (no admin required) -----------------------------------
Write-Host ""
Write-Host "=== Closing browsers and helper/updater processes ===" -ForegroundColor Cyan
if (-not $DryRun) { Kill-BlockingProcesses; Start-Sleep -Seconds 2 }

Write-Host "=== Clearing temp files & system junk (%TEMP%, CrashDumps, shader caches, thumbnails, INetCache, font cache, jump lists) ===" -ForegroundColor Cyan
$junkPaths = @(
    "$env:TEMP",
    "$env:TMP",
    "$env:LOCALAPPDATA\Temp",
    "$env:LOCALAPPDATA\CrashDumps",
    "$env:LOCALAPPDATA\D3DSCache",
    "$env:LOCALAPPDATA\NVIDIA",
    "$env:LOCALAPPDATA\NVIDIA Corporation",
    "$env:LOCALAPPDATA\AMD",
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer",           # thumbnail cache (thumbcache_*.db)
    "$env:LOCALAPPDATA\Microsoft\Windows\WER",                 # Windows Error Reporting dumps
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",           # IE/Edge legacy web cache
    "$env:LOCALAPPDATA\Microsoft\Windows\WebCache",
    "$env:LOCALAPPDATA\Microsoft\Windows\Recent",              # recent items / jump lists
    "$env:LOCALAPPDATA\Microsoft\Windows\Recent\AutomaticDestinations",
    "$env:LOCALAPPDATA\Microsoft\Windows\Recent\CustomDestinations",
    "$env:LOCALAPPDATA\Microsoft\FontCache",
    "$env:LOCALAPPDATA\Microsoft\Terminal Server Client\Cache",
    "$env:LOCALAPPDATA\Microsoft\Windows\PowerShell\StartupProfileData"
)
foreach ($path in $junkPaths) { Remove-PathContents -Path $path }

# --- Browser caches (portable -- detects any profile that exists) -----------
if (-not $SkipBrowsers) {
    Write-Host "=== Clearing browser caches ===" -ForegroundColor Cyan
    $cachePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Opera Software\Opera Stable\Cache",
        "$env:LOCALAPPDATA\Opera Software\Opera GX Stable\Cache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\Default\Cache",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*.default-release\cache2",
        "$env:APPDATA\Mozilla\Firefox\Profiles\*.default\cache2"
    )
    foreach ($path in $cachePaths) {
        Get-Item $path -ErrorAction SilentlyContinue | ForEach-Object { Remove-PathContents -Path $_.FullName }
    }
}

# --- pip cache ---------------------------------------------------------------
Write-Host "=== Purging pip cache ===" -ForegroundColor Cyan
if (Get-Command pip -ErrorAction SilentlyContinue) {
    if ($DryRun) { Write-Host "[DRY RUN] Would run: pip cache purge" -ForegroundColor Magenta }
    else { pip cache purge }
} else {
    Write-Host "pip not found in PATH, skipped."
}

# --- Aggressive / admin-only targets ----------------------------------------
if ($Aggressive -and $isAdmin) {
    Write-Host ""
    Write-Host "=== Aggressive mode: system-level cleanup ===" -ForegroundColor Red

    $systemPaths = @(
        "C:\Windows\Temp",
        "C:\Windows\Prefetch",
        "C:\Windows\SoftwareDistribution\Download",             # Windows Update leftovers
        "C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache",
        "C:\Windows\Panther",                                    # setup/upgrade logs, can be large & stale
        "C:\Windows\Minidump",
        "C:\Windows\LiveKernelReports",
        "C:\ProgramData\Microsoft\Windows\WER"
    )
    foreach ($path in $systemPaths) { Remove-PathContents -Path $path -UseOwnership }

    Write-Host "=== Sweeping temp folders for every user profile on this machine ===" -ForegroundColor Red
    $userTempFolders = Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
        ForEach-Object { Join-Path $_.FullName "AppData\Local\Temp" }
    foreach ($path in $userTempFolders) { Remove-PathContents -Path $path -UseOwnership }

    Write-Host "=== Emptying Recycle Bin ===" -ForegroundColor Red
    if ($DryRun) {
        Write-Host "[DRY RUN] Would empty Recycle Bin" -ForegroundColor Magenta
    } else {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Host "Recycle Bin emptied."
    }

    Write-Host "=== Flushing DNS cache ===" -ForegroundColor Red
    if ($DryRun) {
        Write-Host "[DRY RUN] Would run: ipconfig /flushdns" -ForegroundColor Magenta
    } else {
        ipconfig /flushdns | Out-Null
        Write-Host "DNS cache flushed."
    }
}

# --- Summary / report ---------------------------------------------------------
Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. Nothing was deleted." -ForegroundColor Magenta
} else {
    if ($Global:RebootScheduled.Count -gt 0) {
        Write-Host "$($Global:RebootScheduled.Count) locked file(s) scheduled for deletion on next reboot (they resisted every live attempt)." -ForegroundColor Yellow
    }
    if ($Global:LeftoverReport.Count -eq 0) {
        Write-Host "Done. Everything cleared (or scheduled for reboot-delete). Freed ~$([math]::Round($Global:TotalFreedMB,2)) MB." -ForegroundColor Green
    } else {
        Write-Host "Done. Freed ~$([math]::Round($Global:TotalFreedMB,2)) MB. Some items still could not be purged or scheduled:" -ForegroundColor Red
        $Global:LeftoverReport | Format-Table Folder, ItemCount, SizeMB -AutoSize

        $reportPath = Join-Path $PSScriptRoot "cleanup-report.txt"
        $lines = @("Cleanup report - $(Get-Date)", "Freed: ~$([math]::Round($Global:TotalFreedMB,2)) MB", "Scheduled for reboot-delete: $($Global:RebootScheduled.Count)", "")
        foreach ($r in $Global:LeftoverReport) {
            $lines += "Folder:     $($r.Folder)"
            $lines += "Items left: $($r.ItemCount)  ($($r.SizeMB) MB)"
            $lines += "Examples:   $($r.Sample)"
            $lines += ""
        }
        $lines += "These are directories, not individual files -- MoveFileEx reboot-scheduling only applies to files,"
        $lines += "so empty locked directories can still show up here even after their contents are gone."
        $lines += "Re-run the script after a reboot to clear anything left behind."
        $lines -join "`r`n" | Out-File -FilePath $reportPath -Encoding UTF8
        Write-Host "Full report saved to: $reportPath" -ForegroundColor Cyan
    }
}

try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }

# --- Keep window open when launched by double-click -------------------------
if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ""
    Write-Host "Log saved to: $LogPath" -ForegroundColor DarkGray
    Write-Host "Press any key to close this window..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
