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
v1.0.0

**Tired of having to reboot just because Windows can't properly clean up VRAM before opening game or a local LLM?**

vpurge is a simple script that cycles your GPU off and back on, wiping VRAM clean like a power wash on a greasy driveway. It's the equivalent of chopping an olive with an axe, it works, but anything running on your GPU at the time is getting bisected. Save your work first.

No reinstalls. No driver resets. No "have you tried turning it off and on again?" Well, actually, yes. That's exactly what it does. But *only* the GPU.

---

## How it works

```
1. Detects your primary display adapter (NVIDIA, AMD, Intel, doesn't matter)
2. Saves your current display configuration (resolution, multi-monitor layout, refresh rate)
3. Measures VRAM usage before the purge
4. Spawns a watchdog process (independent of the main terminal)
5. Disables the GPU via PnP
6. GPU goes dark. All displays connected to it go black.
7. Watchdog re-enables the GPU using pnputil (native, reliable) with up to 5 retries
8. Display configuration is restored to exactly how it was
9. VRAM usage is measured again and you see how much was freed
```

The **watchdog** is the key safety mechanism. It runs as a completely separate PowerShell process spawned *before* the GPU is disabled. If the main script dies when the screen goes black, the watchdog keeps running and brings the GPU back. It uses `pnputil.exe` (a native Windows binary) as its primary method, with `Enable-PnpDevice` as fallback.

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

### What to expect

When you run vpurge:

1. It shows your GPU info and asks **Y/N** to confirm
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
| `vpurge.ps1` | Main script — GPU detection, VRAM measurement, display config save/restore, watchdog |
| `install.bat` | Installer — copies files, creates wrapper, adds to PATH, optional Start Menu shortcut |
| `AGENTS.md` | Agent context file for AI-assisted development |

## License

MIT but do whatever you want with it. If it breaks something, you were warned.
