# vpurge

CLI tool for Windows that **purges GPU VRAM** by cycling the primary display adapter (disable → wait → enable) — no reboot required.

## Files

| File | Purpose |
|---|---|
| `vpurge.ps1` | Main PowerShell script. Detects the primary GPU via WMI + PnP, disables it, waits, re-enables it. |
| `install.bat` | System-wide installer. Copies files to `%ProgramFiles%\vpurge\`, creates a `.cmd` wrapper, adds to system PATH. Self-elevates to admin via UAC. |
| `AGENTS.md` | This file. Agent context for re-opening the project. |

## Architecture

### `vpurge.ps1`

- **Requires**: Admin (`#Requires -RunAsAdministrator`)
- **Parameters**: `-WaitSeconds` (default 3), `-ListOnly`, `-Force`
- **Supports ShouldProcess** (works with `-WhatIf`)
- **Detection flow** (`Find-PrimaryDisplayAdapter`):
  1. Query WMI `Win32_VideoController` for active controllers (`Availability -eq 3`)
  2. Filter to those with `CurrentHorizontalResolution > 0` (actually driving a display)
  3. If multiple, pick highest `AdapterRAM` (discrete > integrated)
  4. Cross-reference with `Get-PnpDevice` to get the object for `Disable-PnpDevice`/`Enable-PnpDevice`
- **Vendor detection** (`Extract-Vendor`): checks PCI Vendor ID from PnP device string (`VEN_10DE` = NVIDIA, `VEN_1002` = AMD, `VEN_8086` = Intel, etc.)
- **Cycle flow** (watchdog pattern):
  1. Show recovery `pnputil` command to user BEFORE screen goes dark
  2. Spawn **watchdog process** (separate `powershell.exe`, hidden window) that sleeps then re-enables
  3. Disable GPU (main process)
  4. Main process polls for GPU status in a loop
  5. If main process dies → watchdog still runs independently and re-enables
- **Watchdog**: uses `pnputil.exe` (native, no PS dependency) as primary, `Enable-PnpDevice` as fallback, up to 5 retries, logs everything to `%TEMP%\vpurge-watchdog.log`
- **Safety**: 3-second countdown (skippable with `-Force`), emergency re-enable on disable failure, recovery command shown before going dark

### `install.bat`

- **Self-elevates** to admin via `powershell Start-Process -Verb RunAs`
- **Install steps**: mkdir → copy `.ps1` → generate `.cmd` wrapper → update system PATH
- **Uninstall**: removes directory + cleans PATH
- **Reinstall**: if already installed, prompts R/U/C
- Wrapper auto-elevates and runs PS1 with `-ExecutionPolicy Bypass`

## Key APIs Used

- `Get-CimInstance Win32_VideoController` — GPU info and VRAM
- `Get-PnpDevice` / `Disable-PnpDevice` / `Enable-PnpDevice` — device cycling
- `[Environment]::SetEnvironmentVariable('Path','Machine')` — system PATH management

## Constraints

- Windows only (PowerShell 5.1+, uses `CmdletBinding`, `CimInstance`, `PnpDevice` cmdlets)
- Requires administrator privileges
- All displays on the target GPU go black during the cycle
- GPU-accelerated apps may crash — user must save work first
