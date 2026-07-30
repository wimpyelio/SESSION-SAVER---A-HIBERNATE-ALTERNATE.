#Requires -Version 5.1
# SessionRestore.ps1 - v2.1
# Restores saved session: apps, Notepad files, VS Code workspaces, browsers, Explorer windows.
#
# CHANGES in v2.1:
#   FIX  1 - Notepad: passes the saved file path (or auto-backup path) as a
#            launch argument so the correct document reopens.
#   FIX  2 - VS Code: passes the saved workspace/folder as a launch argument.
#   FIX  3 - Explorer: removed double-quoting that broke some paths; added a
#            5-attempt retry loop (3s total) for Shell.Application window
#            matching, fixing the race condition on single-process Explorer.
#   FIX  4 - Speed: apps now launch in a batch (600ms gap between each) then
#            a single 3s wait, instead of a 3s wait per app. ~3x faster for
#            typical sessions.

param(
    [string]$SaveDir = "$env:USERPROFILE\WindowsSessionRestore",
    [switch]$Silent   # Passed by the startup scheduled task; hides all prompts
)

Add-Type -AssemblyName System.Windows.Forms

$SessionFile = Join-Path $SaveDir "session.json"

if (-not (Test-Path $SessionFile)) {
    $msg = "No saved session found at:`n$SessionFile`n`nRun 'Save Session Now' from your Desktop,`nor wait - it saves automatically on next shutdown."
    if (-not $Silent) {
        [System.Windows.Forms.MessageBox]::Show(
            $msg, "Session Restore",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    Write-Warning $msg
    exit 1
}

# --------------------------------------------------------------------------
# WinAPI type for window positioning (unchanged from v2.0).
# Guard check prevents "type already defined" crash on re-runs.
# --------------------------------------------------------------------------
$winApiReady = $false
if (-not ([System.Management.Automation.PSTypeName]'RestoreWinAPI').Type) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class RestoreWinAPI {
    public const int  SW_MAXIMIZE    = 3;
    public const int  SW_RESTORE     = 9;
    public const uint SWP_NOZORDER   = 0x0004;
    public const uint SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndAfter,
        int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction Stop
        $winApiReady = $true
    } catch {
        Write-Host "  [WARN] Window positioning unavailable: $_" -ForegroundColor Yellow
    }
} else {
    $winApiReady = $true
}

# --------------------------------------------------------------------------
# FEATURE C (unchanged): Patch browser Preferences file to suppress the
# "Browser didn't shut down correctly - restore pages?" crash banner.
# --------------------------------------------------------------------------
$BrowserPrefPaths = @{
    'chrome'   = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Preferences"
    'msedge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Preferences"
    'brave'    = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Preferences"
    'vivaldi'  = "$env:LOCALAPPDATA\Vivaldi\User Data\Default\Preferences"
    'opera'    = "$env:APPDATA\Opera Software\Opera Stable\Preferences"
}

function Set-BrowserExitNormal {
    param([string]$PrefPath)
    if (-not (Test-Path $PrefPath -ErrorAction SilentlyContinue)) { return }
    try {
        $raw = Get-Content $PrefPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($raw -notmatch '"exit_type"\s*:') { return }
        $patched = $raw -replace '("exit_type"\s*:\s*)"[^"]*"', '$1"Normal"'
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($PrefPath, $patched, $enc)
        Write-Host "    [OK] exit_type patched -> Normal (crash banner suppressed)" -ForegroundColor DarkGreen
    } catch {
        Write-Host ("    [WARN] Could not patch browser prefs: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Helper: apply saved window state/position to a process after launch.
# Called in Phase 4 after the batch wait.
# --------------------------------------------------------------------------
function Set-WindowPosition {
    param($Proc, $App)
    if (-not $winApiReady -or $null -eq $Proc -or $null -eq $App.Bounds) { return }
    try {
        $live = Get-Process -Id $Proc.Id -ErrorAction SilentlyContinue
        if ($null -eq $live -or $live.MainWindowHandle.ToInt64() -eq 0) { return }
        $hwnd = $live.MainWindowHandle
        if ($App.WindowState -eq 'Maximized') {
            [RestoreWinAPI]::ShowWindow($hwnd, [RestoreWinAPI]::SW_MAXIMIZE) | Out-Null
        } elseif ($App.WindowState -eq 'Normal') {
            $b = $App.Bounds
            if ($b.Left -gt -3840 -and $b.Top -gt -2160 -and
                $b.Width -gt 100  -and $b.Height -gt 100) {
                [RestoreWinAPI]::SetWindowPos(
                    $hwnd, [IntPtr]::Zero,
                    $b.Left, $b.Top, $b.Width, $b.Height,
                    [RestoreWinAPI]::SWP_NOZORDER -bor [RestoreWinAPI]::SWP_SHOWWINDOW
                ) | Out-Null
            }
        }
    } catch {}
}

# ==========================================================================
# Load saved session
# ==========================================================================
$session = Get-Content $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ""
Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |      SESSION RESTORE  v2.1               |" -ForegroundColor Cyan
Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Saved   : " + $session.SavedAt)    -ForegroundColor DarkGray
Write-Host ("  Apps    : " + $session.AppCount)   -ForegroundColor DarkGray
$explorerCount = if ($null -ne $session.ExplorerCount) { $session.ExplorerCount } else { 0 }
Write-Host ("  Explorer: " + $explorerCount + " window(s)") -ForegroundColor DarkGray
Write-Host ""

$launched = 0
$skipped  = 0
$failed   = 0

# ==========================================================================
# Phase 1: Pre-launch preparation
# --------------------------------------------------------------------------
# - Validate exe paths (skip missing)
# - Patch browser Preferences (MUST happen before the browser is launched)
# - Build the launch queue with final ArgumentList for each app
# ==========================================================================
$launchQueue = [System.Collections.Generic.List[hashtable]]::new()

foreach ($app in $session.Apps) {

    if (-not (Test-Path $app.Path -ErrorAction SilentlyContinue)) {
        Write-Host ("  [SKIP]    " + $app.ProcessName + " - exe not found: " + $app.Path) -ForegroundColor Yellow
        $skipped++
        continue
    }

    $procLow    = $app.ProcessName.ToLower()
    $launchArgs = $app.LaunchArgs   # May be $null for regular apps (v2.0 sessions)

    if ($app.IsBrowser) {
        # Patch prefs BEFORE queueing so the browser never sees exit_type = Crashed
        if ($BrowserPrefPaths.ContainsKey($procLow)) {
            Set-BrowserExitNormal -PrefPath $BrowserPrefPaths[$procLow]
        }
        $launchArgs = $app.BrowserInfo.Flag
        Write-Host ("  [BROWSER] " + $app.BrowserInfo.Name + " -> restoring tabs...") -ForegroundColor Blue

    } elseif ($procLow -eq 'notepad') {
        # FIX 1: LaunchArgs holds the file path (or backup path) saved by SessionSave
        if (-not [string]::IsNullOrEmpty($launchArgs)) {
            Write-Host ("  [NOTEPAD] " + $launchArgs) -ForegroundColor Green
        } else {
            Write-Host "  [NOTEPAD] (no file - opens blank)" -ForegroundColor Green
        }

    } elseif ($procLow -eq 'code') {
        # FIX 2: LaunchArgs holds the workspace/folder saved by SessionSave
        if (-not [string]::IsNullOrEmpty($launchArgs)) {
            Write-Host ("  [VSCODE]  " + $launchArgs) -ForegroundColor Green
        } else {
            Write-Host "  [VSCODE]  (no workspace saved)" -ForegroundColor Green
        }

    } else {
        Write-Host ("  [APP]     " + $app.ProcessName) -ForegroundColor Green
    }

    $launchQueue.Add(@{ App = $app; Args = $launchArgs })
}

# ==========================================================================
# Phase 2: Batch launch all queued apps
# --------------------------------------------------------------------------
# FIX 4 (Speed): Apps launch with a 600ms gap (just enough to avoid
# disk saturation on spinning drives). No 3s wait per app anymore.
# Process handles are collected for Phase 4 window positioning.
# ==========================================================================
$procHandles = [System.Collections.Generic.List[hashtable]]::new()

foreach ($item in $launchQueue) {
    $app  = $item.App
    $args = $item.Args
    try {
        $startParams = @{
            FilePath    = $app.Path
            PassThru    = $true
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrEmpty($args)) {
            $startParams['ArgumentList'] = $args
        }
        $proc = Start-Process @startParams
        $procHandles.Add(@{ Proc = $proc; App = $app })
        $launched++
    } catch {
        Write-Host ("  [FAIL]    " + $app.ProcessName + " - " + $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
    # Short gap to avoid hammering disk on HDD systems; not a window-ready wait
    Start-Sleep -Milliseconds 600
}

# ==========================================================================
# Phase 3: Single batch wait
# --------------------------------------------------------------------------
# One 3-second wait after ALL apps are launched gives every process time
# to paint its first window before we try to reposition them.
# ==========================================================================
if ($procHandles.Count -gt 0) {
    Write-Host ""
    Write-Host "  Waiting for apps to load..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
}

# ==========================================================================
# Phase 4: Apply window state and position to all launched apps
# ==========================================================================
foreach ($item in $procHandles) {
    Set-WindowPosition -Proc $item.Proc -App $item.App
}

# ==========================================================================
# FEATURE D (FIXED): Restore File Explorer Windows
# --------------------------------------------------------------------------
# ROOT CAUSE of "windows don't open": Start-Process without explicit quoting
# silently fails on paths with spaces (e.g. "C:\My Documents"), and on
# Windows 10/11 single-process Explorer it sometimes opens in an existing
# window instead of a new one, leaving the restore with nothing to position.
#
# FIX 3a - Open method: Shell.Application.Open() is the correct API.
#   * Handles path quoting internally - no spaces issue.
#   * Works on ALL Windows versions (7 multi-process through 11 single-process).
#   * Uses the same COM subsystem as the retry-loop detection below, so
#     the window always appears in Shell.Application.Windows() after it opens.
#
# FIX 3b - Race condition: On Windows 10/11 the new window opens inside the
#           existing single-process Explorer host and takes 1-2s to register.
#           A retry loop (5 x 600ms = 3s max) solves this.
#
# FIX 3c - Path normalisation: TrimEnd('\').ToLower() on both sides so that
#           drive roots (C:\) and mixed-case paths compare correctly.
# ==========================================================================
$explorerList = if ($session.ExplorerPaths) { @($session.ExplorerPaths) } else { @() }

if ($explorerList.Count -gt 0) {
    Write-Host ""
    Write-Host ("  Restoring " + $explorerList.Count + " File Explorer window(s)...") -ForegroundColor Cyan

    foreach ($expWin in $explorerList) {
        try {
            $path = $expWin.Path
            if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
                Write-Host ("  [SKIP]    Explorer: " + $path + " (path no longer exists)") -ForegroundColor Yellow
                $skipped++
                continue
            }

            Write-Host ("  [EXPLORER] " + $path) -ForegroundColor Blue

            # FIX 3a: Shell.Application.Open() - correct cross-version method.
            # Fallback to Start-Process (quoted) only if COM fails.
            $opened = $false
            try {
                $shellOpen = New-Object -ComObject 'Shell.Application' -ErrorAction Stop
                $shellOpen.Open($path)
                $opened = $true
            } catch {}
            if (-not $opened) {
                Start-Process "explorer.exe" -ArgumentList "`"$path`"" -ErrorAction SilentlyContinue
            }

            # FIX 3b & 3c: Retry loop - poll Shell.Application until the window appears
            $matched      = $false
            $normalTarget = $path.TrimEnd('\').ToLower()

            if ($winApiReady -and
                $null -ne $expWin.Left -and $null -ne $expWin.Top -and
                $expWin.Width -gt 50 -and $expWin.Height -gt 50) {

                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    Start-Sleep -Milliseconds 600
                    try {
                        $shellApp2 = New-Object -ComObject 'Shell.Application' -ErrorAction Stop
                        foreach ($win in @($shellApp2.Windows())) {
                            try {
                                if (-not $win.LocationURL)                 { continue }
                                if ($win.LocationURL -notmatch '^file://') { continue }
                                $winPath = $win.Document.Folder.Self.Path
                                if ($winPath.TrimEnd('\').ToLower() -ne $normalTarget) { continue }

                                # Matched - apply saved window position
                                $hwnd = [IntPtr]([int64]$win.HWND)
                                if ($hwnd.ToInt64() -ne 0) {
                                    [RestoreWinAPI]::SetWindowPos(
                                        $hwnd, [IntPtr]::Zero,
                                        $expWin.Left, $expWin.Top,
                                        $expWin.Width, $expWin.Height,
                                        [RestoreWinAPI]::SWP_NOZORDER -bor [RestoreWinAPI]::SWP_SHOWWINDOW
                                    ) | Out-Null
                                }
                                $matched = $true
                                break
                            } catch {}
                        }
                    } catch {}
                    if ($matched) { break }
                }

                if (-not $matched) {
                    Write-Host "    [WARN] Could not locate Explorer window handle after 3s." -ForegroundColor DarkGray
                }
            }

            $launched++

        } catch {
            Write-Host ("  [FAIL]    Explorer " + $expWin.Path + " - " + $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ""
Write-Host "  ------------------------------------------" -ForegroundColor DarkGray
Write-Host ("  Launched : " + $launched) -ForegroundColor Green
if ($skipped -gt 0) { Write-Host ("  Skipped  : " + $skipped + " (exe or path not found)") -ForegroundColor Yellow }
if ($failed  -gt 0) { Write-Host ("  Failed   : " + $failed)  -ForegroundColor Red }
Write-Host ""

# --------------------------------------------------------------------------
# FIX #8 (v2.0, unchanged): ReadKey wrapped in try-catch; skipped in -Silent
# --------------------------------------------------------------------------
if (-not $Silent) {
    Write-Host "  All done! Press any key to close." -ForegroundColor Cyan
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        Read-Host "Press Enter to close"
    }
}
