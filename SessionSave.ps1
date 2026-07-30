#Requires -Version 5.1
# SessionSave.ps1 - v2.1
# Captures open apps + File Explorer windows + browser info + window positions.
# Auto-runs on logoff/shutdown (with -Cleanup) and every 30 minutes (without).
#
# NEW in v2.1:
#   FIX  1 - Notepad: saves the open file path via CIM CommandLine so it
#            reopens the same file on restore.
#   FIX  2 - Notepad: unsaved/untitled documents have their text read via
#            WinAPI (Edit control) and saved to a timestamped backup file.
#   FIX  3 - VS Code: workspace/folder path extracted from CIM CommandLine
#            of the main Code.exe process (the one without --type=).
#   NEW  A - -Cleanup switch: kills non-Windows background processes
#            (no visible window) before saving. Used by the logoff task only.

param(
    [string]$SaveDir = "$env:USERPROFILE\WindowsSessionRestore",
    [switch]$Cleanup   # Passed by logoff task; kills background procs first
)

$SessionFile    = Join-Path $SaveDir "session.json"
$LogFile        = Join-Path $SaveDir "session.log"
$NotepadBackDir = Join-Path $SaveDir "NotepadBackups"

foreach ($dir in @($SaveDir, $NotepadBackDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Write-Log {
    param([string]$Msg, [string]$Color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$ts] $Msg" -ErrorAction SilentlyContinue
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
}

# --------------------------------------------------------------------------
# WinAPI type - expanded in v2.1 to add FindWindowEx + SendMessage for
# reading Notepad text content from its child Edit control.
# Guard check prevents "type already defined" crash on re-runs.
# --------------------------------------------------------------------------
$winApiReady = $false
if (-not ([System.Management.Automation.PSTypeName]'SessionWinAPI').Type) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class SessionWinAPI {
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    // Used to locate Notepad's child Edit control
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindowEx(IntPtr hWndParent, IntPtr hWndChildAfter,
        string lpszClass, string lpszWindow);

    // WM_GETTEXTLENGTH overload (lParam = IntPtr)
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, IntPtr lParam);

    // WM_GETTEXT overload (lParam = StringBuilder)
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, StringBuilder lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@ -ErrorAction Stop
        $winApiReady = $true
    } catch {
        Write-Log "WARNING: Windows API unavailable - some features disabled. Error: $_" "Yellow"
    }
} else {
    $winApiReady = $true
}

# --------------------------------------------------------------------------
# Windows system process whitelist for background cleanup.
# Processes from C:\Windows\ are also protected regardless of this list.
# --------------------------------------------------------------------------
$WindowsSystemProcs = @(
    'System','Registry','smss','csrss','wininit','winlogon','lsass','lsaiso',
    'services','svchost','dllhost','conhost','WUDFHost','WerFault','WerFaultSecure',
    'dwm','explorer','sihost','taskhostw','ctfmon','ApplicationFrameHost',
    'StartMenuExperienceHost','TextInputHost','ShellExperienceHost','LockApp',
    'SearchHost','SearchIndexer','SearchFilterHost','SearchProtocolHost',
    'SystemSettings','RuntimeBroker','UserOOBEBroker','PresentationFontCache',
    'MsMpEng','NisSrv','SecurityHealthSystray','SecurityHealthService',
    'SgrmBroker','MpCmdRun','smartscreen','sppsvc','SppExtComObj',
    'audiodg','fontdrvhost','spoolsv','msdtc','vssvc',
    'AggregatorHost','uhssvc','MoUsoCoreWorker','TiWorker','TrustedInstaller',
    'CompPkgSrv','CompatTelRunner','wsqmcons','wlanext','wmpnetwk',
    'ngen','mscorsvw',
    'powershell','pwsh','cmd','msiexec','taskmgr','regedit',
    'SessionSave','SessionRestore',
    'Idle','MemCompression'
)

# Process names to skip during the app-capture scan (same logic as v2.0).
# explorer.exe is intentionally excluded here; Explorer windows are captured
# separately via Shell.Application COM which can report per-window folder paths.
$IgnoreProcs = @(
    'svchost','System','Registry','smss','csrss','wininit','winlogon','lsass',
    'services','MsMpEng','NisSrv','explorer','dwm','RuntimeBroker','SearchHost',
    'StartMenuExperienceHost','TextInputHost','ShellExperienceHost','LockApp',
    'SystemSettings','SecurityHealthSystray','sihost','taskhostw','ctfmon',
    'dllhost','conhost','WUDFHost','audiodg','fontdrvhost','SearchIndexer',
    'WmiPrvSE','SgrmBroker','AggregatorHost','uhssvc','spoolsv',
    'ApplicationFrameHost','UserOOBEBroker','PresentationFontCache',
    'MoUsoCoreWorker','TiWorker','TrustedInstaller','CompPkgSrv',
    'SkypeApp','YourPhone','HxTsr','powershell','pwsh','cmd',
    'SessionSave','SessionRestore','taskmgr','regedit','msiexec'
)

$Browsers = @{
    'chrome'    = @{ Name = 'Google Chrome';  Flag = '--restore-last-session' }
    'msedge'    = @{ Name = 'Microsoft Edge'; Flag = '--restore-last-session' }
    'brave'     = @{ Name = 'Brave';          Flag = '--restore-last-session' }
    'vivaldi'   = @{ Name = 'Vivaldi';        Flag = '--restore-last-session' }
    'opera'     = @{ Name = 'Opera';          Flag = '--restore-last-session' }
    'firefox'   = @{ Name = 'Firefox';        Flag = '-restore'               }
    'waterfox'  = @{ Name = 'Waterfox';       Flag = '-restore'               }
    'librewolf' = @{ Name = 'LibreWolf';      Flag = '-restore'               }
}

# ==========================================================================
# NEW FEATURE A: Background Process Cleanup
# --------------------------------------------------------------------------
# Kills every background process (no visible window) that is not a Windows
# system process and whose exe does not live in C:\Windows\.
# Runs only when -Cleanup is passed (i.e., on the logoff/shutdown task).
# Runs BEFORE the save so the saved session reflects the cleaned state.
# ==========================================================================
function Invoke-BackgroundCleanup {
    Write-Log "Cleaning background processes before save..." "Cyan"
    $killed = 0
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -gt 4 -and
        $_.Id -ne $PID -and
        $_.MainWindowHandle.ToInt64() -eq 0 -and
        $_.ProcessName -notin $WindowsSystemProcs
    } | ForEach-Object {
        $exePath = $null
        try { $exePath = $_.Path } catch {}
        # Never kill anything living in the Windows directory
        if ($exePath -and $exePath -imatch '^C:\\Windows\\') { return }
        try {
            $name = $_.ProcessName
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
            $killed++
            Write-Log ("  Killed background: " + $name) "DarkGray"
        } catch {}
    }
    Write-Log ("Background cleanup done: " + $killed + " process(es) terminated") "Cyan"
}

if ($Cleanup) { Invoke-BackgroundCleanup }

# ==========================================================================
# FIX 2: Read text from a Notepad window via its child Edit control.
# --------------------------------------------------------------------------
# Classic Notepad (Windows 10) uses class "Edit".
# The newer Windows 10 Notepad (Store update) uses "RichEditD2DPT" as a
# fallback. WM_GETTEXTLENGTH (0x000E) + WM_GETTEXT (0x000D) are standard
# Win32 messages that work on both control types.
# Returns $null on failure or empty content.
# ==========================================================================
function Get-NotepadContent {
    param([IntPtr]$MainHwnd)
    if (-not $winApiReady) { return $null }
    try {
        $editHwnd = [SessionWinAPI]::FindWindowEx($MainHwnd, [IntPtr]::Zero, 'Edit', $null)
        if ($editHwnd.ToInt64() -eq 0) {
            # Fallback for newer Notepad build
            $editHwnd = [SessionWinAPI]::FindWindowEx($MainHwnd, [IntPtr]::Zero, 'RichEditD2DPT', $null)
        }
        if ($editHwnd.ToInt64() -eq 0) { return $null }

        $len = [SessionWinAPI]::SendMessage($editHwnd, 0x000E, 0, [IntPtr]::Zero)
        if ($len -le 0) { return $null }

        $sb = New-Object System.Text.StringBuilder($len + 2)
        [SessionWinAPI]::SendMessage($editHwnd, 0x000D, ($len + 1), $sb) | Out-Null
        $text = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text
    } catch { return $null }
}

# ==========================================================================
# FIX 1: Get the file path a Notepad instance has open, via CIM CommandLine.
# --------------------------------------------------------------------------
# Notepad command line formats:
#   notepad.exe                        -> new/untitled (returns $null)
#   notepad.exe "C:\path\file.txt"     -> quoted path
#   notepad.exe C:\path\file.txt       -> unquoted path (no spaces)
# ==========================================================================
function Get-NotepadFilePath {
    param([int]$Pid)
    try {
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$Pid" -ErrorAction Stop).CommandLine
        if ([string]::IsNullOrEmpty($cl)) { return $null }
        if ($cl -match 'notepad(?:\.exe)?\s+"([^"]+)"') { return $Matches[1] }
        if ($cl -match 'notepad(?:\.exe)?\s+([A-Za-z]:\\[^\s]+)$') { return $Matches[1] }
    } catch {}
    return $null
}

# ==========================================================================
# FIX 3: Get the workspace/folder open in VS Code via CIM CommandLine.
# --------------------------------------------------------------------------
# VS Code spawns multiple Code.exe processes (renderer, gpu-process, etc.).
# Only the MAIN process (no --type= flag) carries the workspace argument.
# Workspace path appears as:
#   "...\Code.exe"  "C:\path\to\project"   -> most common
#   "...\Code.exe"  --folder-uri "vscode-vfs://..." -> remote/virtual
# ==========================================================================
function Get-VSCodeWorkspace {
    try {
        $mainProc = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -notmatch '--type=' } |
            Select-Object -First 1
        if (-not $mainProc) { return $null }
        $cl = $mainProc.CommandLine
        if ([string]::IsNullOrEmpty($cl)) { return $null }

        # Remote/virtual workspace URI
        if ($cl -match '--folder-uri\s+"?([^\s"]+)"?') { return $Matches[1] }
        # Local path (quoted)
        if ($cl -match '"[^"]*[Cc]ode\.exe"\s+"([A-Za-z]:\\.+?)"') { return $Matches[1] }
        # Local path (unquoted, no spaces)
        if ($cl -match '"[^"]*[Cc]ode\.exe"\s+([A-Za-z]:\\[^\s"]+)') { return $Matches[1] }
    } catch {}
    return $null
}

# ==========================================================================
# Main scan - capture all visible user applications
# ==========================================================================
Write-Log "Scanning open applications..." "Cyan"

$apps      = [System.Collections.Generic.List[object]]::new()
$seenPaths = @{}
$seenBrwsr = @{}

$candidates = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle.ToInt64() -ne 0 -and
    $_.MainWindowTitle -ne '' -and
    $_.ProcessName -notin $IgnoreProcs
}

foreach ($p in $candidates) {
    $exePath = $null
    try { $exePath = $p.Path } catch { continue }
    if ([string]::IsNullOrEmpty($exePath)) { continue }
    if (-not (Test-Path $exePath -ErrorAction SilentlyContinue)) { continue }

    $key     = $exePath.ToLower()
    $procLow = $p.ProcessName.ToLower()
    $isBrwsr = $Browsers.ContainsKey($procLow)

    if ($isBrwsr) {
        if ($seenBrwsr.ContainsKey($procLow)) { continue }
        $seenBrwsr[$procLow] = $true
    } else {
        if ($seenPaths.ContainsKey($key)) { continue }
        $seenPaths[$key] = $true
    }

    # Window geometry
    $bounds = $null
    $state  = 'Normal'
    if ($winApiReady) {
        try {
            $rect = New-Object SessionWinAPI+RECT
            if ([SessionWinAPI]::GetWindowRect($p.MainWindowHandle, [ref]$rect)) {
                $bounds = @{
                    Left   = $rect.Left
                    Top    = $rect.Top
                    Width  = $rect.Right  - $rect.Left
                    Height = $rect.Bottom - $rect.Top
                }
            }
            if ([SessionWinAPI]::IsZoomed($p.MainWindowHandle))     { $state = 'Maximized' }
            elseif ([SessionWinAPI]::IsIconic($p.MainWindowHandle)) { $state = 'Minimized'  }
        } catch {}
    }

    # ------------------------------------------------------------------
    # FIX 1 & 2: Notepad - resolve open file path; back up unsaved text
    # ------------------------------------------------------------------
    $launchArgs    = $null
    $notepadBackup = $null

    if ($procLow -eq 'notepad') {
        $filePath = Get-NotepadFilePath -Pid $p.Id
        if ($filePath -and (Test-Path $filePath -ErrorAction SilentlyContinue)) {
            # Notepad has a real file open - pass it as a launch argument
            $launchArgs = "`"$filePath`""
            Write-Log ("    Notepad file: " + $filePath) "DarkGray"
        } else {
            # Untitled / unsaved - read text via WinAPI and save a backup
            $content = Get-NotepadContent -MainHwnd $p.MainWindowHandle
            if (-not [string]::IsNullOrEmpty($content)) {
                $ts       = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
                $backFile = Join-Path $NotepadBackDir ("Notepad_" + $ts + ".txt")
                try {
                    $enc = New-Object System.Text.UTF8Encoding $false
                    [System.IO.File]::WriteAllText($backFile, $content, $enc)
                    $launchArgs    = "`"$backFile`""
                    $notepadBackup = $backFile
                    Write-Log ("    Notepad unsaved -> backed up: " + $backFile) "DarkGray"
                } catch {
                    Write-Log ("    Notepad: could not write backup: " + $_.Exception.Message) "Yellow"
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # FIX 3: VS Code - capture workspace/folder from main process CmdLine
    # ------------------------------------------------------------------
    if ($procLow -eq 'code') {
        $ws = Get-VSCodeWorkspace
        if (-not [string]::IsNullOrEmpty($ws)) {
            $launchArgs = "`"$ws`""
            Write-Log ("    VS Code workspace: " + $ws) "DarkGray"
        }
    }

    $short = $p.MainWindowTitle
    if ($short.Length -gt 60) { $short = $short.Substring(0, 57) + '...' }
    Write-Log ("  + " + $p.ProcessName.PadRight(20) + " | " + $short) "DarkGray"

    $apps.Add([PSCustomObject]@{
        ProcessName   = $p.ProcessName
        Path          = $exePath
        Title         = $p.MainWindowTitle
        IsBrowser     = $isBrwsr
        BrowserInfo   = if ($isBrwsr) { $Browsers[$procLow] } else { $null }
        WindowState   = $state
        Bounds        = $bounds
        LaunchArgs    = $launchArgs    # v2.1: pre-computed args (Notepad file, VSCode ws, etc.)
        NotepadBackup = $notepadBackup # v2.1: path to auto-saved backup (if applicable)
    })
}

# ==========================================================================
# File Explorer window capture (unchanged from v2.0)
# Uses Shell.Application COM to record per-window folder paths.
# ==========================================================================
Write-Log "Scanning File Explorer windows..." "Cyan"
$explorerPaths = [System.Collections.Generic.List[object]]::new()
try {
    $shellApp = New-Object -ComObject 'Shell.Application' -ErrorAction Stop
    foreach ($window in @($shellApp.Windows())) {
        try {
            if (-not $window.LocationURL)                                          { continue }
            if ($window.LocationURL -notmatch '^file://')                         { continue }
            $folderPath = $window.Document.Folder.Self.Path
            if ([string]::IsNullOrEmpty($folderPath))                             { continue }
            if (-not (Test-Path $folderPath -ErrorAction SilentlyContinue))       { continue }

            $explorerPaths.Add([PSCustomObject]@{
                Path   = $folderPath
                Left   = [int]$window.Left
                Top    = [int]$window.Top
                Width  = [int]$window.Width
                Height = [int]$window.Height
            })
            Write-Log ("  + Explorer: " + $folderPath) "DarkGray"
        } catch {}
    }
    Write-Log ("Captured " + $explorerPaths.Count + " File Explorer window(s)") "Cyan"
} catch {
    Write-Log ("WARNING: Could not enumerate File Explorer windows: " + $_) "Yellow"
}

# ==========================================================================
# Write session.json - always overwrites the previous save (single-file)
# ==========================================================================
$payload = @{
    Version       = '2.1'
    SavedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Machine       = $env:COMPUTERNAME
    User          = $env:USERNAME
    AppCount      = $apps.Count
    ExplorerCount = $explorerPaths.Count
    Apps          = $apps
    ExplorerPaths = $explorerPaths
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -Path $SessionFile -Encoding UTF8 -Force

Write-Log ("Saved " + $apps.Count + " app(s) + " + $explorerPaths.Count + " Explorer window(s) -> " + $SessionFile) "Green"
Write-Log "Done." "Cyan"
