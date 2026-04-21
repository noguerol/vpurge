```                                                                
 
 ██▒   █▓ ██▓███   █    ██  ██▀███    ▄████ ▓█████ 
▓██░   █▒▓██░  ██▒ ██  ▓██▒▓██ ▒ ██▒ ██▒ ▀█▒▓█   ▀ 
 ▓██  █▒░▓██░ ██▓▒▓██  ▒██░▓██ ░▄█ ▒▒██░▄▄▄░▒███   
  ▒██ █░░▒██▄█▓▒ ▒▓▓█  ░██░▒██▀▀█▄  ░▓█  ██▓▒▓█  ▄ 
   ▒▀█░  ▒██▒ ░  ░▒▒█████▓ ░██▓ ▒██▒░▒▓███▀▒░▒████▒
   ░ ▐░  ▒▓▒░ ░  ░░▒▓▒ ▒ ▒ ░ ▒▓ ░▒▓░ ░▒   ▒ ░░ ▒░ ░
   ░ ░░  ░▒ ░     ░░▒░ ░ ░   ░▒ ░ ▒░  ░   ░  ░ ░  ░
     ░░  ░░        ░░░ ░ ░   ░░   ░ ░ ░   ░    ░   
      ░              ░        ░           ░    ░  ░
     ░           

```
# vpurge 
v1.1.0

**Tired of having to reboot just because Windows can't properly clean up VRAM before opening a game or a local LLM?**

vpurge is a simple script that cycles your GPU off and back on, wiping VRAM clean like a power wash on a greasy driveway. It's the equivalent of chopping an olive with an axe — it works, but anything running on your GPU at the time is getting bisected. Save your work first.

No reinstalls. No driver resets. No "have you tried turning it off and on again?" Well, actually, yes. That's exactly what it does. But *only* the GPU.

---

## What's new in v1.1.0

- **DWM restart for hardware acceleration** — After the GPU is re-enabled, the Desktop Window Manager is automatically restarted to ensure Windows reclaims GPU-accelerated composition. Without this, the desktop could feel sluggish after a purge (software rendering fallback).
- **Fixed `PropertyNotFoundStrict` crash** — On systems with a single GPU, an inline `if` expression could unwrap a single-element array to a scalar, causing a `StrictMode` crash. All pipeline assignments are now explicitly wrapped with `@()`.
- **Fixed truncated script ending** — Missing closing braces at end of file caused immediate parse failure on launch.

---

## How it works

```
 1. Detects your primary display adapter (NVIDIA, AMD, Intel — doesn't matter)
 2. Saves your current display configuration (resolution, multi-monitor layout, refresh rate)
 3. Measures VRAM usage before the purge
 4. Spawns a watchdog process (independent of the main terminal)
 5. Disables the GPU via PnP
 6. GPU goes dark. All displays connected to it go black.
 7. Watchdog re-enables the GPU using pnputil (native, reliable) with up to 5 retries
 8. Watchdog restarts DWM (Desktop Window Manager) to reclaim hardware acceleration
 9. Watchdog restores display configuration to exactly how it was
10. Main process measures VRAM again and shows how much was freed
```

The **watchdog** is the key safety mechanism. It runs as a completely separate PowerShell process spawned *before* the GPU is disabled. If the main script dies when the screen goes black, the watchdog keeps running and brings the GPU back.

### Why restart DWM?

When the GPU is cycled, Windows' Desktop Window Manager may fall back to **software rendering** (WARP). This causes the entire desktop to feel sluggish — dragging windows stutters, animations lag, and scrolling is choppy. Restarting `dwm.exe` forces Windows to re-initialize the composition stack and reclaim the GPU for hardware-accelerated rendering.

The DWM restart runs **only in the watchdog** (a hidden, detached process). The main terminal process cannot restart DWM because killing `dwm.exe` from within an interactive terminal kills the hosting session, preventing the final VRAM summary from being displayed.

## Install

Double-click `install.bat` (requires admin, will auto-elevate via UAC).

This will:
- Copy `vpurge.ps1` to `%ProgramFiles%\vpurge\`
- Create a `vpurge.cmd` wrapper and add it to system PATH
- Optionally add a Start Menu shortcut with a custom ∞ icon

After installing, **close and reopen** any open terminals so the PATH change takes effect.

## Usage

```powershell
vpurge                  # Purge VRAM on primary GPU (with confirmation prompt)
vpurge -ListOnly        # List all display adapters, no changes made
vpurge -Force           # Skip the confirmation prompt
vpurge -WaitSeconds 5   # Wait 5 seconds before re-enabling (default: 3)
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-WaitSeconds` | `3` | Seconds between disabling and re-enabling the GPU |
| `-ListOnly` | — | List all display adapters with status info, then exit |
| `-Force` | — | Skip the Y/N confirmation prompt |

### What to expect

When you run vpurge:

1. It shows your GPU info and asks **Y/N** to confirm (unless `-Force`)
2. It saves your display config and measures VRAM
3. Your screen goes **black** for a few seconds
4. Everything comes back with a summary like this:

```
  ╔════════════════════════════════════════════════════╗
  ║  VRAM PURGE COMPLETE                                                     ║
  ╠════════════════════════════════════════════════════╣
  ║  NVIDIA GeForce RTX 4090
  ║  VRAM before:    6,144 MB
  ║  VRAM after:       128 MB
  ║  Freed:          6,016 MB
  ╚════════════════════════════════════════════════════╝
```

## Uninstall

Run `install.bat` again and choose **[U]ninstall**, or manually:

```powershell
rd /s /q "C:\Program Files\vpurge"
rd /s /q "%ProgramData%\Microsoft\Windows\Start Menu\Programs\vpurge"
# Then remove vpurge from your system PATH
```

## Architecture

### Execution flow

```
┌─────────────────────────────────────────────────────────┐
│                     MAIN PROCESS                        │
│  (runs in the user's terminal)                          │
│                                                         │
│  1. Self-elevate to admin via UAC                       │
│  2. Detect primary GPU (WMI + PnP cross-reference)      │
│  3. Save display config (CCD API → binary blob)         │
│  4. Measure VRAM usage (perf counters / nvidia-smi)     │
│  5. Spawn WATCHDOG as hidden process                    │
│  6. Disable GPU (Disable-PnpDevice)                     │
│  7. Poll until adapter comes back                       │
│  8. Restore display config (belt & suspenders)          │
│  9. Measure VRAM again, show summary                    │
└────────────────────┬────────────────────────────────────┘
                     │ spawned before step 6
┌────────────────────▼────────────────────────────────────┐
│              WATCHDOG PROCESS                           │
│  (hidden, detached PowerShell)                          │
│                                                         │
│  1. Wait WaitSeconds (default: 3)                       │
│  2. Compile C# display config helper during wait        │
│  3. Re-enable GPU: pnputil → Enable-PnpDevice (x5)     │
│  4. Restart DWM (Stop-Process dwm -Force)               │
│  5. Restore display config (SetDisplayConfig CCD API)   │
│  6. Log everything to %TEMP%\vpurge-watchdog.log        │
└─────────────────────────────────────────────────────────┘
```

### GPU detection

`Find-PrimaryDisplayAdapter` uses a cascading filter:

1. `Get-CimInstance Win32_VideoController` → all controllers
2. **Strict filter**: `Availability -eq 3` AND `ConfigManagerErrorCode -eq 0`
3. If strict removes everything → **relax**: all except "Microsoft Basic Display Adapter"
4. **Active filter**: `CurrentHorizontalResolution -gt 0` (driving a display)
5. If multiple active → pick highest `AdapterRAM`
6. Cross-reference with `Get-PnpDevice` for the `InstanceId` needed by `Disable-PnpDevice`

> **PS 5.1 gotcha**: Inline `if` expressions unwrap single-element arrays to scalars. All assignments use explicit `@()` wrapping to prevent `PropertyNotFoundStrict` errors under `Set-StrictMode -Version Latest`.

### VRAM detection

**Total VRAM** (cascading, first wins):

| Priority | Method | Notes |
|---|---|---|
| 1 | Registry `HardwareInformation.qwMemorySize` | Most reliable. Matches by `VEN_XXXX&DEV_XXXX` from PnP ID. |
| 2 | WMI `AdapterRAM` | Unreliable for AMD (reports 4 GB for 20 GB cards). |
| 3 | `nvidia-smi --query-gpu=memory.total` | NVIDIA only. |

**VRAM usage** (`Get-VRAMUsage`, cascading):

| Priority | Method | Notes |
|---|---|---|
| 1 | Perf counter `\GPU Adapter Memory(*)\Dedicated Usage` | Windows 10+, vendor-agnostic. |
| 2 | Sum of process `GPUCommit` properties | Fallback. |
| 3 | `nvidia-smi --query-gpu=memory.used` | NVIDIA only. |

### Display config save/restore

Uses the Windows CCD (Connecting and Configuring Displays) API via C# interop:

- `QueryDisplayConfig` with `QDC_ONLY_ACTIVE_PATHS` captures the full topology
- `SetDisplayConfig` with `SDC_APPLY | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES | SDC_USE_SUPPLIED_DISPLAY_CONFIG` restores it exactly
- Buffers are pre-allocated (32 paths, 64 modes) to avoid a null-pointer sizing call that fails with `ERROR_INVALID_PARAMETER`
- C# source compiled via `Add-Type` from `$env:TEMP\vpurge-displayconfig.cs`
- Blob format: `[4B numPaths][4B numModes][4B pathSize][4B modeSize][paths bytes][modes bytes]`

### Watchdog safety net

The watchdog is what prevents a forced reboot if something goes wrong:

- Written to `$env:TEMP\vpurge-watchdog.ps1`, launched as **hidden** `powershell.exe`
- Compiles the C# display config helper during the wait period (before GPU goes dark)
- Re-enable via `pnputil.exe` (native binary, works when WMI/CIM is degraded) with `Enable-PnpDevice` as fallback
- Up to **5 retries** with 3s between each
- Restarts DWM **before** restoring display config (order matters — DWM restart overwrites the layout)
- All activity logged to `$env:TEMP\vpurge-watchdog.log`
- A standalone restore script is generated at `$env:TEMP\vpurge-restore.ps1`

### Installer (`install.bat`)

| Step | Action |
|---|---|
| `[0/3]` | Kill running vpurge/watchdog processes via `Get-CimInstance Win32_Process` |
| `[1/3]` | Copy `.ps1` via PowerShell `Copy-Item` (preserves BOM UTF-8) |
| `[2/3]` | Create `vpurge.cmd` wrapper |
| `[3/3]` | Add to system PATH (PowerShell + registry fallback) |
| Optional | Start Menu shortcut with custom ∞ icon (PNG-in-ICO via `System.Drawing`) |

## Requirements

- **Windows 10/11** (uses CCD API, GPU performance counters, PnP cmdlets)
- **PowerShell 5.1+**
- **Administrator privileges** (auto-requested via UAC)

## Limitations

- All displays connected to the target GPU will go black during the cycle
- GPU-accelerated applications (browsers, games, editors, renderers) **will likely crash**
- Not tested on laptops with hybrid GPU setups (use at your own risk)
- VRAM measurement relies on Windows GPU performance counters — may not work on all systems

## Files

| File | Purpose |
|---|---|
| `vpurge.ps1` | Main script — GPU detection, VRAM measurement, display config save/restore, watchdog, DWM restart (~905 lines) |
| `install.bat` | Installer — copies files, creates wrapper, adds to PATH, optional Start Menu shortcut |
| `AGENTS.md` | Agent context file for AI-assisted development |

## License

MIT but do whatever you want with it. If it breaks something, you were warned.
