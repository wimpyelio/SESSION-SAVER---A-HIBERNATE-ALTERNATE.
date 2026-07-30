#Requires -Version 5.1
# UPGRADE.ps1 - Windows Session Restore v2.1 - Smart Installer
# Compatible : Windows 7 SP1 + WMF 5.1  |  Windows 8.1  |  Windows 10  |  Windows 11
# Entry point: double-click INSTALL.bat (recommended) or right-click -> Run as Administrator.
#
# Automatically detects the current installation state and acts accordingly:
#
#   FRESH       : No prior installation found.
#                 Installs all tasks and shortcuts for Version 2.
#
#   V1_UPGRADE  : Version 1 tasks detected (OnLogoff + Periodic present,
#                 OnStartup absent). Stops running instances, backs up the
#                 saved session, overwrites old tasks with v2 equivalents,
#                 and registers the new OnStartup (auto-restore) task.
#
#   V2_REINSTALL: Version 2 already fully installed (all three tasks present).
#                 Stops running instances and re-registers everything so
#                 tasks point to the current script location (useful when
#                 the scripts folder has moved since the original install).
#
# Nothing is deleted that the user might need:
#   - session.json (saved session) is never touched.
#   - A timestamped JSON backup is created during a V1_UPGRADE.
#   - Old script files at a different location are left in place; the tasks
#     and shortcuts are simply updated to point to the new location.

[CmdletBinding()]
param()

Set-StrictMode -Off   # Keeps $null comparisons safe without adding verbosity

# ===========================================================================
# Output helpers  (all pure ASCII - see BugReport.txt BUG #8)
# ===========================================================================
function Write-Step {
    param([int]$N, [int]$T, [string]$Label)
    Write-Host ("  [{0}/{1}] {2}..." -f $N, $T, $Label) -ForegroundColor Yellow
}
function Write-OK   { param([string]$M) Write-Host ("        [OK]   " + $M) -ForegroundColor Green    }
function Write-Warn { param([string]$M) Write-Host ("        [WARN] " + $M) -ForegroundColor Yellow   }
function Write-Fail { param([string]$M) Write-Host ("        [FAIL] " + $M) -ForegroundColor Red      }
function Write-Info { param([string]$M) Write-Host ("               " + $M) -ForegroundColor DarkGray }

# ===========================================================================
# Phase 0: Self-elevation
# See Setup.ps1 FIX #9 for why we do this instead of #Requires -RunAsAdmin.
# ===========================================================================
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = if ($PSCommandPath) { $PSCommandPath }
            elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
            else { $null }
    if ($self) {
        Write-Host "  Requesting elevation - click YES at the UAC prompt..." -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs `
                -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$self`"" `
                -ErrorAction Stop
        } catch {
            Write-Host "  ERROR: Elevation denied or failed." -ForegroundColor Red
            Write-Host "  Run via INSTALL.bat, or right-click UPGRADE.ps1 -> Run as Administrator." -ForegroundColor Yellow
            Read-Host "  Press Enter to exit"
        }
    } else {
        Write-Host "  ERROR: Cannot determine script path. Run via INSTALL.bat." -ForegroundColor Red
        Read-Host "  Press Enter to exit"
    }
    exit
}

# ===========================================================================
# OS version gate - Windows 7 SP1 (6.1.7601) is the minimum.
# Older builds lack LogoffTrigger support in Task Scheduler and WMF 5.1.
# Windows 7 users must install WMF 5.1 first: https://aka.ms/wmf51
# ===========================================================================
$_osVer = [System.Environment]::OSVersion.Version
if ($_osVer.Major -lt 6 -or ($_osVer.Major -eq 6 -and $_osVer.Minor -lt 1)) {
    Write-Host ""
    Write-Host "  ERROR: Windows 7 SP1 or later is required." -ForegroundColor Red
    Write-Host "  Your OS version: $_osVer" -ForegroundColor DarkGray
    Read-Host "  Press Enter to exit"
    exit 1
}

# ===========================================================================
# Path resolution
# See Setup.ps1 FIX #10/#11 for why PSCommandPath / PSScriptRoot are preferred.
# ===========================================================================
$ScriptDir     = if ($PSScriptRoot) { $PSScriptRoot }
                 else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SaveScript    = Join-Path $ScriptDir "SessionSave.ps1"
$RestoreScript = Join-Path $ScriptDir "SessionRestore.ps1"
$SessionDir    = "$env:USERPROFILE\WindowsSessionRestore"
$SessionFile   = Join-Path $SessionDir "session.json"
$LogFile       = Join-Path $SessionDir "session.log"

foreach ($f in @($SaveScript, $RestoreScript)) {
    if (-not (Test-Path $f)) {
        Write-Host ""
        Write-Host "  ERROR: Missing required file: $f" -ForegroundColor Red
        Write-Host "  The following files must all be in the same folder:" -ForegroundColor Yellow
        Write-Host "    SessionSave.ps1   SessionRestore.ps1   UPGRADE.ps1   INSTALL.bat" -ForegroundColor Gray
        Write-Host ""
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

# ===========================================================================
# Phase 1: Detect installation state
# Heuristic:
#   OnLogoff absent                        -> FRESH        (nothing installed)
#   OnLogoff present, OnStartup absent     -> V1_UPGRADE   (v1 registered only 2 tasks)
#   OnLogoff present, OnStartup present    -> V2_REINSTALL (v2 already fully installed)
#
# Each task is searched in \SessionRestore\ first, then in the root folder as
# a fallback for the rare case where Setup.ps1's COM pre-create step failed
# and Register-ScheduledTask fell back to the root folder.
# ===========================================================================
function Find-Task {
    param([string]$Name)
    $t = Get-ScheduledTask -TaskPath '\SessionRestore\' -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) {
        $t = Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction SilentlyContinue
    }
    return $t
}

$logoffTask   = Find-Task 'WinSessionRestore_OnLogoff'
$periodicTask = Find-Task 'WinSessionRestore_Periodic'
$startupTask  = Find-Task 'WinSessionRestore_OnStartup'

if (-not $logoffTask -and -not $periodicTask) {
    $mode = 'FRESH'
} elseif (-not $startupTask) {
    $mode = 'V1_UPGRADE'
} else {
    $mode = 'V2_REINSTALL'
}

# Extract old script directory from the existing logoff task's action arguments.
# The argument string looks like:
#   -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File "C:\...\SessionSave.ps1"
# We parse the -File value to find where the old scripts live.
$oldScriptDir = $null
$sourceTask   = if ($logoffTask) { $logoffTask } else { $periodicTask }
if ($sourceTask) {
    $rawArgs = $sourceTask.Actions[0].Arguments
    if ($rawArgs -match '-File\s+"([^"]+)"') {
        $oldScriptDir = Split-Path -Parent $Matches[1]
    } elseif ($rawArgs -match '-File\s+(\S+)') {
        $oldScriptDir = Split-Path -Parent $Matches[1]
    }
}

# Determine total step count for the progress display
switch ($mode) {
    'FRESH'       { $totalSteps = 6 }  # policy + folder + logoff + periodic + startup + shortcuts
    'V1_UPGRADE'  { $totalSteps = 8 }  # stop + backup + policy + folder + logoff + periodic + startup + shortcuts
    'V2_REINSTALL'{ $totalSteps = 7 }  # stop + policy + folder + logoff + periodic + startup + shortcuts
}

# ===========================================================================
# Banner
# ===========================================================================
Write-Host ""
Write-Host "  +====================================================+" -ForegroundColor Magenta
Write-Host "  |   Windows Session Restore  -  Smart Installer     |" -ForegroundColor Magenta
Write-Host "  |   Version 2.1                                      |" -ForegroundColor Magenta
Write-Host "  +====================================================+" -ForegroundColor Magenta
Write-Host ""
Write-Host ("  Install location : " + $ScriptDir) -ForegroundColor DarkGray

switch ($mode) {
    'FRESH' {
        Write-Host "  Mode             : Fresh install" -ForegroundColor Cyan
    }
    'V1_UPGRADE' {
        Write-Host "  Mode             : Upgrade  v1 -> v2" -ForegroundColor Green
        if ($oldScriptDir) {
            Write-Host ("  Previous install : " + $oldScriptDir) -ForegroundColor DarkGray
        }
    }
    'V2_REINSTALL' {
        Write-Host "  Mode             : Reinstall / update v2" -ForegroundColor Cyan
        if ($oldScriptDir) {
            Write-Host ("  Previous install : " + $oldScriptDir) -ForegroundColor DarkGray
        }
    }
}
Write-Host ""

$step = 0

# ===========================================================================
# Phase 2: Pre-upgrade steps  (V1_UPGRADE and V2_REINSTALL only)
# ===========================================================================
if ($mode -in @('V1_UPGRADE', 'V2_REINSTALL')) {

    # -- Stop running script processes and task instances -------------------
    $step++
    Write-Step $step $totalSteps "Stopping running instances"
    $stopped = 0

    # Kill any powershell.exe / pwsh.exe process whose command line references
    # one of our scripts. CIM is used because Get-Process does not expose
    # CommandLine. Running as Administrator, CIM always has access.
    try {
        $targetScripts = @('SessionSave.ps1', 'SessionRestore.ps1')
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $cl = $_.CommandLine
            $cl -and ($targetScripts | Where-Object { $cl -match [regex]::Escape($_) })
        } | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $stopped++ } catch {}
        }
    } catch {
        Write-Warn "CIM process query failed: $($_.Exception.Message)"
    }

    # Stop any currently-running task instances via Stop-ScheduledTask.
    # Errors are silenced because the task may not be running at all.
    foreach ($tn in @('WinSessionRestore_OnLogoff', 'WinSessionRestore_Periodic', 'WinSessionRestore_OnStartup')) {
        Stop-ScheduledTask -TaskPath '\SessionRestore\' -TaskName $tn -ErrorAction SilentlyContinue
        Stop-ScheduledTask -TaskPath '\'               -TaskName $tn -ErrorAction SilentlyContinue
    }

    if ($stopped -gt 0) {
        Write-OK ("Stopped " + $stopped + " running script process(es)")
    } else {
        Write-OK "No running script instances found"
    }

    # -- Back up session data (V1_UPGRADE only) ----------------------------
    # V2_REINSTALL skips this because session.json is already in v2 format.
    # The backup is safety-net only; session.json is fully forward-compatible.
    if ($mode -eq 'V1_UPGRADE') {
        $step++
        Write-Step $step $totalSteps "Backing up Version 1 session data"

        $backedUp = $false
        if (Test-Path $SessionFile) {
            try {
                if (-not (Test-Path $SessionDir)) {
                    New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null
                }
                $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
                $bakJson = Join-Path $SessionDir ("session_v1_backup_" + $ts + ".json")
                Copy-Item $SessionFile $bakJson -Force -ErrorAction Stop
                Write-OK ("session.json  ->  session_v1_backup_" + $ts + ".json")
                Write-Info "Your saved apps and window positions are preserved"
                $backedUp = $true
            } catch {
                Write-Warn ("Backup failed: " + $_.Exception.Message)
                Write-Info "The original session.json is still in place and untouched"
            }
        } else {
            Write-OK "No existing session data found (clean user profile)"
        }

        # Also snapshot the log so old diagnostic info is not lost
        if ($backedUp -and (Test-Path $LogFile)) {
            try {
                $ts2 = Get-Date -Format 'yyyyMMdd_HHmmss'
                Copy-Item $LogFile (Join-Path $SessionDir ("session_v1_" + $ts2 + ".log")) -Force -ErrorAction Stop
            } catch {}
        }
    }
}

# ===========================================================================
# Phase 3: Install Version 2
# This section runs for ALL modes (FRESH, V1_UPGRADE, V2_REINSTALL).
# Every Register-ScheduledTask call uses -Force so existing tasks are
# overwritten in-place rather than failing on duplicates.
# ===========================================================================

# Build XML-safe strings once; reused across all three task registrations.
# Ampersands in paths (rare but possible) must be entity-escaped in XML.
$xmlUser        = ("$env:USERDOMAIN\$env:USERNAME") -replace '&', '&amp;'
$xmlSavePath    = $SaveScript    -replace '&', '&amp;'
$xmlRestorePath = $RestoreScript -replace '&', '&amp;'

# -- [Step] PowerShell execution policy ------------------------------------
$step++
Write-Step $step $totalSteps "Setting PowerShell execution policy"
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
    Write-OK "RemoteSigned set for LocalMachine"
} catch {
    Write-Warn ("Could not set policy: " + $_.Exception.Message)
    Write-Info "Installation continues - scripts may still work under an existing permissive policy"
}

# -- [Step] Task Scheduler folder ------------------------------------------
# See Setup.ps1 FIX #13: Register-ScheduledTask silently fails on some
# Windows 10 builds when -TaskPath points to a folder that does not exist.
# Pre-creating the folder via COM avoids that silent failure entirely.
$step++
Write-Step $step $totalSteps "Preparing Task Scheduler library folder"
try {
    $svc = New-Object -ComObject 'Schedule.Service' -ErrorAction Stop
    $svc.Connect()
    $root = $svc.GetFolder('\')
    try { $root.CreateFolder('SessionRestore') | Out-Null } catch {}
    Write-OK "Folder \SessionRestore\ is ready"
} catch {
    Write-Warn ("Task Scheduler COM failed: " + $_.Exception.Message)
    Write-Info "Tasks will be registered in the root folder as a fallback"
}

# -- [Step] Logoff / shutdown auto-save task --------------------------------
# See Setup.ps1 FIX #14 (CRITICAL) for why XML is used here instead of
# New-ScheduledTaskTrigger -AtLogOff (which does not exist in any released
# version of PowerShell). <LogoffTrigger> fires on sign-out AND shutdown.
$step++
Write-Step $step $totalSteps "Registering auto-save on logoff / shutdown"

$xmlSaveArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File &quot;" + $xmlSavePath + "&quot; -Cleanup"
$logoffXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Save Windows session on logoff or shutdown (Windows Session Restore v2)</Description>
  </RegistrationInfo>
  <Triggers>
    <LogoffTrigger><Enabled>true</Enabled></LogoffTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$xmlUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$xmlSaveArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
try {
    Register-ScheduledTask -Xml $logoffXml `
        -TaskName 'WinSessionRestore_OnLogoff' -TaskPath '\SessionRestore\' -Force | Out-Null
    Write-OK "WinSessionRestore_OnLogoff   (fires on sign-out and shutdown)"
} catch {
    Write-Fail ("Logoff task: " + $_.Exception.Message)
    Write-Info "Sessions will still be saved every 30 minutes by the periodic task"
}

# -- [Step] Periodic 30-minute auto-save task --------------------------------
# See Setup.ps1 FIX #15 for why -RepetitionDuration is required.
# Omitting it causes the repetition to silently stop after ~1 day on
# Windows 10 builds 1903 and later.
$step++
Write-Step $step $totalSteps "Registering 30-minute periodic auto-save"
try {
    $psArgs          = "-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$SaveScript`""
    $periodicAction  = New-ScheduledTaskAction  -Execute 'powershell.exe' -Argument $psArgs
    $periodicTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650)       # 10 yrs = effectively infinite
    $periodicSettings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit         (New-TimeSpan -Minutes 3) `
        -StopIfGoingOnBatteries     $false `
        -DisallowStartIfOnBatteries $false `
        -MultipleInstances          IgnoreNew
    $periodicPrincipal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
    Register-ScheduledTask `
        -TaskName  'WinSessionRestore_Periodic' -TaskPath '\SessionRestore\' `
        -Action    $periodicAction -Trigger $periodicTrigger `
        -Settings  $periodicSettings -Principal $periodicPrincipal -Force | Out-Null
    Write-OK "WinSessionRestore_Periodic   (every 30 minutes, indefinitely)"
} catch {
    Write-Fail ("Periodic task: " + $_.Exception.Message)
}

# -- [Step] Startup auto-restore task (new in v2) --------------------------
# Runs SessionRestore.ps1 -Silent 30 seconds after the user logs in.
# LeastPrivilege is intentional: restoring apps does not need admin rights,
# and HighestAvailable would trigger a UAC prompt on every single login.
# -WindowStyle Hidden keeps the console invisible; -Silent suppresses all
# interactive prompts so the restore runs completely in the background.
$step++
$startupLabel = "Registering auto-restore on startup"
if ($mode -eq 'V1_UPGRADE') { $startupLabel = $startupLabel + " (NEW in v2)" }
Write-Step $step $totalSteps $startupLabel

$xmlRestoreArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File &quot;" + $xmlRestorePath + "&quot; -Silent"
$startupXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Restore saved Windows session automatically after login (Windows Session Restore v2)</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Delay>PT30S</Delay>
      <Enabled>true</Enabled>
      <UserId>$xmlUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$xmlUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$xmlRestoreArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
try {
    Register-ScheduledTask -Xml $startupXml `
        -TaskName 'WinSessionRestore_OnStartup' -TaskPath '\SessionRestore\' -Force | Out-Null
    Write-OK "WinSessionRestore_OnStartup  (30 seconds after login, hidden)"
} catch {
    Write-Fail ("Startup task: " + $_.Exception.Message)
    Write-Info "Use the 'Restore Session' Desktop shortcut manually after each reboot"
}

# -- [Step] Desktop shortcuts ----------------------------------------------
# Always recreated so they point to the current $ScriptDir even if the
# scripts have been moved since the previous install.
# Shell32.dll indices 23 and 259 are stable across all Windows 10 builds.
# See Setup.ps1 FIX #16 for why imageres.dll indices were abandoned.
$step++
Write-Step $step $totalSteps "Creating / updating Desktop shortcuts"
try {
    $wsh     = New-Object -ComObject WScript.Shell -ErrorAction Stop
    $desktop = [Environment]::GetFolderPath('Desktop')

    $lnkRestore                  = $wsh.CreateShortcut("$desktop\Restore Session.lnk")
    $lnkRestore.TargetPath       = 'powershell.exe'
    $lnkRestore.Arguments        = "-ExecutionPolicy Bypass -NoProfile -File `"$RestoreScript`""
    $lnkRestore.WorkingDirectory = $ScriptDir
    $lnkRestore.IconLocation     = '%SystemRoot%\System32\shell32.dll,23'
    $lnkRestore.Description      = 'Restore your previous Windows session'
    $lnkRestore.WindowStyle      = 1
    $lnkRestore.Save()

    $lnkSave                  = $wsh.CreateShortcut("$desktop\Save Session Now.lnk")
    $lnkSave.TargetPath       = 'powershell.exe'
    $lnkSave.Arguments        = "-ExecutionPolicy Bypass -NoProfile -File `"$SaveScript`""
    $lnkSave.WorkingDirectory = $ScriptDir
    $lnkSave.IconLocation     = '%SystemRoot%\System32\shell32.dll,259'
    $lnkSave.Description      = 'Manually save your current Windows session'
    $lnkSave.WindowStyle      = 1
    $lnkSave.Save()

    Write-OK "'Restore Session'  on Desktop -> SessionRestore.ps1"
    Write-OK "'Save Session Now' on Desktop -> SessionSave.ps1"
} catch {
    Write-Fail ("Shortcut creation: " + $_.Exception.Message)
}

# ===========================================================================
# Phase 4: Post-install summary and optional session restore
# ===========================================================================
Write-Host ""
Write-Host "  +====================================================+" -ForegroundColor Green
Write-Host "  |   Installation Complete!                           |" -ForegroundColor Green
Write-Host "  +====================================================+" -ForegroundColor Green
Write-Host ""

switch ($mode) {

    'FRESH' {
        Write-Host "  Version 2 installed successfully (fresh install)." -ForegroundColor Green
        Write-Host ""
        Write-Host "  ACTION REQUIRED:" -ForegroundColor Yellow
        Write-Host "    Click 'Save Session Now' on your Desktop right now to" -ForegroundColor Yellow
        Write-Host "    create your first session file. Auto-restore has nothing" -ForegroundColor Yellow
        Write-Host "    to work with until at least one save exists." -ForegroundColor Yellow
    }

    'V1_UPGRADE' {
        Write-Host "  Successfully upgraded: Version 1 -> Version 2." -ForegroundColor Green
        Write-Host ""
        Write-Host "  What is new in Version 2:" -ForegroundColor White
        Write-Host "    [+] File Explorer windows save and restore with their folder paths"   -ForegroundColor Cyan
        Write-Host "    [+] Browser tabs restore silently - no 'restore session?' prompt"    -ForegroundColor Cyan
        Write-Host "    [+] Session restores automatically 30 seconds after login"           -ForegroundColor Cyan
        Write-Host "    [+] Session saves automatically on every logoff and shutdown"        -ForegroundColor Cyan
        Write-Host "    [+] Only the latest session is kept (no stale data accumulates)"    -ForegroundColor Cyan
        Write-Host "    [+] Notepad files reopen the same document; unsaved text is backed up" -ForegroundColor Cyan
        Write-Host "    [+] VS Code reopens the correct workspace/folder"                    -ForegroundColor Cyan
        Write-Host "    [+] Background processes are cleaned up at shutdown"                 -ForegroundColor Cyan
        Write-Host "    [+] Session restore is ~3x faster (batch launch)"                   -ForegroundColor Cyan
        if (Test-Path $SessionFile) {
            Write-Host ""
            Write-Host "  Your v1 saved session is intact and ready to restore." -ForegroundColor Green
        }
        if ($oldScriptDir -and ($oldScriptDir.TrimEnd('\') -ne $ScriptDir.TrimEnd('\'))) {
            Write-Host ""
            Write-Host "  Old v1 script files are still at:" -ForegroundColor DarkGray
            Write-Host ("    " + $oldScriptDir) -ForegroundColor DarkGray
            Write-Host "  They are no longer used. You can safely delete that folder." -ForegroundColor DarkGray
        }
    }

    'V2_REINSTALL' {
        Write-Host "  Version 2 reinstalled successfully." -ForegroundColor Green
        Write-Host "  All tasks and shortcuts now point to the current script location." -ForegroundColor DarkGray
        if ($oldScriptDir -and ($oldScriptDir.TrimEnd('\') -ne $ScriptDir.TrimEnd('\'))) {
            Write-Host ""
            Write-Host "  Old script files at the previous location are no longer used:" -ForegroundColor DarkGray
            Write-Host ("    " + $oldScriptDir) -ForegroundColor DarkGray
            Write-Host "  You can safely delete that folder." -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "  Active scheduled tasks:" -ForegroundColor White
Write-Host "    WinSessionRestore_OnLogoff   saves on every sign-out / shutdown" -ForegroundColor Gray
Write-Host "    WinSessionRestore_Periodic   saves every 30 minutes (background)"   -ForegroundColor Gray
Write-Host "    WinSessionRestore_OnStartup  restores 30 seconds after login"       -ForegroundColor Gray
Write-Host ""
Write-Host "  To disable auto-restore:" -ForegroundColor DarkGray
Write-Host "    Task Scheduler -> Task Scheduler Library -> SessionRestore" -ForegroundColor DarkGray
Write-Host "    -> Right-click WinSessionRestore_OnStartup -> Disable"     -ForegroundColor DarkGray
Write-Host ""

# Offer to launch SessionRestore.ps1 right now if a session file exists.
# For FRESH installs there is nothing to restore yet, so we skip the offer.
if (Test-Path $SessionFile) {
    Write-Host "  A saved session was found. Restore it now? [Y/N]  " -NoNewline -ForegroundColor Cyan
    $doRestore = $false
    try {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host $key.Character
        $doRestore = $key.Character -in @('Y', 'y')
    } catch {
        $answer = Read-Host ""
        $doRestore = $answer -match '^[Yy]'
    }

    if ($doRestore) {
        Write-Host ""
        Write-Host "  Launching Session Restore..." -ForegroundColor Cyan
        # Run in a new visible window so the user sees what is being opened.
        Start-Process powershell.exe `
            -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$RestoreScript`"" `
            -ErrorAction SilentlyContinue
    } else {
        Write-Host ""
        Write-Host "  OK. Use the 'Restore Session' shortcut on your Desktop whenever you are ready." -ForegroundColor DarkGray
    }
} else {
    # FRESH install - prompt user to take the first save
    Write-Host "  Press any key to close this window, then click 'Save Session Now'." -ForegroundColor Gray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host "" }
}
