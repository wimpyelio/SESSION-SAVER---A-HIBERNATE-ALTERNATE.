# 🗂️ SESSION SAVER

**Close your laptop lid. Restart. Update. Reboot for no reason at all.**
**Everything you had open comes back — exactly where you left it.**

<p align="left">
  <img src="https://img.shields.io/badge/Windows%207%20SP1-0078D6?style=for-the-badge&logo=windows7&logoColor=white" alt="Windows 7 SP1">
  <img src="https://img.shields.io/badge/Windows%208.1-0078D6?style=for-the-badge&logo=windows8&logoColor=white" alt="Windows 8.1">
  <img src="https://img.shields.io/badge/Windows%2010-0078D6?style=for-the-badge&logo=windows10&logoColor=white" alt="Windows 10">
  <img src="https://img.shields.io/badge/Windows%2011-0078D6?style=for-the-badge&logo=windows11&logoColor=white" alt="Windows 11">
</p>

<p align="left">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/version-2.1-brightgreen?style=flat-square" alt="Version 2.1">
  <img src="https://img.shields.io/badge/install-double--click-blue?style=flat-square" alt="One-click install">
  <img src="https://img.shields.io/badge/admin%20rights-required-orange?style=flat-square" alt="Admin required">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" alt="MIT License">
</p>

---

## ⚡ Quick Install — one command

Open **PowerShell** (no admin needed — the installer handles UAC itself) and paste:

```powershell
$d="$env:TEMP\SessionSaver";New-Item $d -ItemType Directory -Force|Out-Null;'SessionSave.ps1','SessionRestore.ps1','Setup.ps1','UPGRADE.ps1','INSTALL.bat'|ForEach-Object{Invoke-WebRequest "https://raw.githubusercontent.com/YOUR-USERNAME/session-saver/main/$_" -OutFile "$d\$_" -UseBasicParsing};Start-Process "$d\INSTALL.bat"
```

That's it. Downloads all 5 files to a temp folder, then launches the installer. Click **Yes** on the UAC prompt and you're done.

> **Windows 7 / 8.1 users:** Install [WMF 5.1](https://aka.ms/wmf51) first, then run the command above.

---

## What is this?

**Session Saver** is a lightweight, native-PowerShell tool that remembers every app, File Explorer window, and browser tab you had open — and puts it all back automatically the next time you log in. No cloud account, no background service eating RAM, no telemetry. Just two scripts and three Task Scheduler entries doing exactly what Windows should have done in the first place.

Built for people who restart constantly (Windows Update, we're looking at you) and are tired of manually reopening the same 12 windows every single time.

---

## ✨ Features

- **Auto-save every 30 minutes** — plus an immediate save on every logoff, restart, and shutdown.(⚠️THIS FEATURE IS IN DEVELOPMENT PHASE, SO ALWAYS CLICK THE SESSION BUTTON AT END OF YPUR SESSION SAVE IT.)
- **One-click manual save/restore** — desktop shortcuts for "Save Session Now" and "Restore Session".
- **Auto-restore on login** — silently runs ~30 seconds after you sign in, no prompts, no popups.
- **File Explorer windows** — reopens every open folder at its exact saved position and size.
- **Browser tab restore** — Chrome, Edge, Brave, Vivaldi, Opera, Firefox, Waterfox, and LibreWolf all restore their last session automatically, with the "restore pages?" crash banner suppressed.
- **Notepad-aware** — reopens the exact file you had open. If it was an unsaved/untitled document, the text is captured live and auto-backed up to a timestamped `.txt` file so nothing is ever lost.
- **VS Code-aware** — reopens the same folder/workspace instead of a blank window.
- **Window geometry restore** — every app returns to its saved position, size, and maximized/minimized state.
- **Background process cleanup** — at shutdown, stray non-Windows background processes are cleaned up so your next login starts fresh.
- **Self-elevating installer** — one double-click handles UAC, detects fresh installs vs. upgrades, and registers everything automatically.
- **Single JSON snapshot** — no growing history, no clutter, just the latest session.
- **Zero dependencies** — no .NET installs, no third-party modules, nothing to download except this repo.

---

## 📋 Requirements

| Requirement | Details |
|---|---|
| OS | Windows 7 SP1 or later (7 / 8.1 / 10 / 11) |
| PowerShell | 5.1+ ([built into Windows 10/11](https://learn.microsoft.com/powershell/scripting/windows-powershell/install/installing-windows-powershell); Windows 7/8.1 need the free [WMF 5.1](https://aka.ms/wmf51) update) |
| Rights | Administrator (only during install, to register scheduled tasks) |
| Disk | < 5 MB |

---

## 🚀 Installation (IF ONE-LINE COMMAND IS NOT-YOUR-VIBE/ OR FOR CONTRIBUTING)

1. **[Download the latest release](../../releases)** or clone this repo.
2. Extract all 5 files into **one folder** (don't separate them):
   ```
   SessionSave.ps1
   SessionRestore.ps1
   Setup.ps1
   UPGRADE.ps1
   INSTALL.bat
   ```
3. **Double-click `INSTALL.bat`.**
4. Click **Yes** on the UAC prompt.
5. Done. Your session now saves automatically — no further action needed.

The installer detects fresh installs vs. upgrades automatically, so re-running `INSTALL.bat` after pulling an update is always safe.

---

## 🖱️ Usage

Once installed, everything runs on its own:

| Trigger | What happens |
|---|---|
| Every 30 minutes | Session auto-saves in the background |
| Logoff / restart / shutdown | Session saves, background processes are cleaned up |
| ~30 seconds after login | Session restores automatically and silently |
| **"Save Session Now"** desktop shortcut | Manual save on demand |
| **"Restore Session"** desktop shortcut | Manual restore on demand |

Your saved session lives at:
```
%USERPROFILE%\WindowsSessionRestore\session.json
%USERPROFILE%\WindowsSessionRestore\session.log
%USERPROFILE%\WindowsSessionRestore\NotepadBackups\
```

---

## 🛠️ How it works

- **`SessionSave.ps1`** scans running processes for visible windows, captures their exe path, title, position, and state, queries File Explorer via `Shell.Application` COM, and reads command-line arguments via CIM to know exactly which file/folder each app had open.
- **`SessionRestore.ps1`** relaunches everything, reapplies window position/state via `user32.dll`, patches browser `Preferences` files so crash-recovery prompts never appear, and reopens Explorer windows via `Shell.Application.Open()`.
- **`UPGRADE.ps1`** is the smart installer: it self-elevates, detects your current install state, and registers three Task Scheduler entries under `\SessionRestore\`.
- **`Setup.ps1`** is a manual fallback entry point if you prefer to right-click and "Run as Administrator" instead of using `INSTALL.bat`.

No data ever leaves your machine. Everything is stored locally in plain JSON.

---

## 🩹 Troubleshooting

| Problem | Fix |
|---|---|
| Nothing restores after login | Check `%USERPROFILE%\WindowsSessionRestore\session.log` for errors |
| "Execution policy" error | Re-run `INSTALL.bat` — it sets `RemoteSigned` automatically |
| Windows 7/8.1: install fails immediately | Install [WMF 5.1](https://aka.ms/wmf51) first, then re-run `INSTALL.bat` |
| A specific app never restores | Some apps manage their own session state and ignore launch arguments — check the log for `[SKIP]`/`[FAIL]` entries |

---

## 🤝 Contributing

Issues and pull requests are welcome. If you're reporting a bug, please attach the relevant lines from `session.log`.

## 📄 License

[MIT](LICENSE) — do whatever you want with it.
