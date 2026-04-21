<#
.SYNOPSIS
    Purges GPU VRAM by cycling the primary display adapter (disable → enable).

.DESCRIPTION
    Automatically detects the PRIMARY display adapter and cycles it
    (disable → wait → enable) to force VRAM release.

    Works with any vendor: NVIDIA, AMD, Intel, or others.

    ⚠ WARNING: ALL displays driven by this GPU will go BLACK briefly.
    ⚠ WARNING: GPU-accelerated apps may crash or hang. SAVE YOUR WORK FIRST.

.PARAMETER WaitSeconds
    Seconds between disable and re-enable (default: 3).

.PARAMETER ListOnly
    List all display adapters with their status. No changes made.

.PARAMETER Force
    Skip the 2-second confirmation countdown.

.EXAMPLE
    .\vpurge.ps1                  # Auto-detect primary GPU and cycle it
    .\vpurge.ps1 -WaitSeconds 5   # Give more time for slow drivers
    .\vpurge.ps1 -ListOnly        # Just show adapter info
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$WaitSeconds = 3,
    [switch]$ListOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════
#  Self-elevate to Administrator via UAC if not already elevated
# ═══════════════════════════════════════════════════════════════

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $argParts = @()
    if ($WaitSeconds -ne 3)  { $argParts += "-WaitSeconds $WaitSeconds" }
    if ($ListOnly)           { $argParts += '-ListOnly' }
    if ($Force)              { $argParts += '-Force' }
    $argString = $argParts -join ' '

    # Write a launcher script that runs vpurge and keeps the window open
    # so the user can see output/errors even after the script finishes.
    $launcherFile = Join-Path $env:TEMP 'vpurge-launcher.ps1'
    $escapedPath = $PSCommandPath -replace "'", "''"
    @"
& '$escapedPath' $argString
`$ec = `$LASTEXITCODE
Write-Host ''
if (`$ec -ne 0) {
    Write-Host 'vpurge exited with error code ' -NoNewline -ForegroundColor Red
    Write-Host `$ec -ForegroundColor Red
}
Write-Host 'Press any key to close...' -NoNewline -ForegroundColor DarkGray
`$null = `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit `$ec
"@ | Set-Content -Path $launcherFile -Encoding UTF8

    Start-Process -FilePath 'powershell.exe' `
                  -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$launcherFile `
                  -Verb RunAs
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════

function Write-Icon($Icon, $Text, $Color = 'Cyan') {
    Write-Host "  $Icon " -ForegroundColor $Color -NoNewline
    Write-Host $Text
}

function Format-Size([uint64]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1GB) { return '{0:N0} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-VRAMUsage {
    <#
    Returns dedicated GPU VRAM usage in bytes.
    Tries multiple methods for cross-vendor compatibility.
    Returns $null if no method works.
    #>
    param([string]$AdapterName)

    # Method 1: GPU Adapter Memory performance counter (Windows 10+)
    try {
        $counters = @(Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop)
        foreach ($sample in $counters.CounterSamples) {
            if ($sample.CookedValue -gt 0 -and $sample.InstanceName -notmatch 'CPU') {
                # Counter value is in bytes
                return [uint64]$sample.CookedValue
            }
        }
    } catch {
        # Counter not available, try next method
    }

    # Method 2: Sum dedicated GPU memory from all processes
    try {
        $total = [uint64]0
        $procs = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -and $_.WorkingSet64 -gt 0 }
        foreach ($p in $procs) {
            try {
                $gpuMem = $p | Select-Object -ExpandProperty 'GPUCommit' -ErrorAction SilentlyContinue
                if ($gpuMem) { $total += [uint64]$gpuMem }
            } catch { }
        }
        if ($total -gt 0) { return $total }
    } catch { }

    # Method 3: NVIDIA-specific nvidia-smi
    if ($AdapterName -match 'NVIDIA') {
        try {
            $output = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $output) {
                # Output is in MiB
                foreach ($line in $output) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match '^\d+') {
                        return [uint64]([int]$matches[0] * 1MB)
                    }
                }
            }
        } catch { }
    }

    return $null
}

# ═══════════════════════════════════════════════════════════════
#  Detect primary adapter (vendor-agnostic)
# ═══════════════════════════════════════════════════════════════

function Find-PrimaryDisplayAdapter {
    <#
    Strategy:
      1. Query WMI Win32_VideoController for all active controllers.
      2. The one actively driving pixels has CurrentHorizontalResolution > 0.
      3. If multiple are active, pick the one with the largest VRAM
         (discrete GPU is typically primary on dual-GPU systems).
      4. Cross-reference with Get-PnpDevice to get the PnP object we need
         for Disable-PnpDevice / Enable-PnpDevice.
    #>

    # --- Step 1: Get all video controllers ---
    $allControllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)

    if ($allControllers.Count -eq 0) {
        return $null
    }

    # --- Step 1b: Filter to active controllers (lenient) ---
    #    Some drivers don't populate Availability or ConfigManagerErrorCode.
    #    Try strict first, then fall back to all.
    $wmiControllers = @($allControllers | Where-Object {
        ($null -ne $_.Availability -and $_.Availability -eq 3) -and
        ($null -ne $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -eq 0)
    })

    if ($wmiControllers.Count -eq 0) {
        # Strict filter removed everything -- relax and use all controllers.
        # Skip the 'Microsoft Basic Display Adapter' if real GPUs exist.
        $realGPUs = @($allControllers | Where-Object {
            $_.Name -notmatch 'Microsoft Basic Display Adapter'
        })
        $wmiControllers = @(if ($realGPUs.Count -gt 0) { $realGPUs } else { $allControllers })
    }

    # --- Step 2: Filter to those actually outputting to a display ---
    $active = @($wmiControllers | Where-Object { $_.CurrentHorizontalResolution -gt 0 })

    # If none has resolution (headless / RDP), fall back to all controllers
    if ($active.Count -eq 0) {
        $active = $wmiControllers
    }

    # --- Step 3: Pick the best candidate ---
    $primary = if ($active.Count -eq 1) {
        $active[0]
    }
    else {
        # Multiple active GPUs → prefer the one with the most VRAM
        # (discrete > integrated in dual-GPU laptops/desktops)
        $active | Sort-Object { [uint64]$_.AdapterRAM } -Descending | Select-Object -First 1
    }

    # --- Step 4: Cross-reference with PnP device ---
    $pnpId = $primary.PNPDeviceID
    $pnpDevice = Get-PnpDevice -InstanceId $pnpId -ErrorAction SilentlyContinue

    if (-not $pnpDevice) {
        # WMI gave us a PnP ID that Get-PnpDevice can't find -- try partial match
        $pnpDevice = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -eq $pnpId } |
            Select-Object -First 1
    }

    # --- Step 5: Get total VRAM ---
    #    WMI AdapterRAM is unreliable (AMD returns 4GB for 20GB cards).
    #    Priority: Registry qwMemorySize > WMI AdapterRAM > nvidia-smi

    $totalVram = [uint64]0

    # Method 1: Registry qwMemorySize (most reliable, works for AMD/NVIDIA/Intel)
    try {
        $pnpId = $primary.PNPDeviceID
        # Extract VEN_XXXX&DEV_XXXX for matching
        $vendorDev = if ($pnpId -match 'VEN_[0-9A-Fa-f]+&DEV_[0-9A-Fa-f]+') { $matches[0] } else { '' }
        $videoKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Video'
        $subkeys = Get-ChildItem $videoKey -ErrorAction SilentlyContinue
        foreach ($sk in $subkeys) {
            $prop = Get-ItemProperty ($sk.PSPath + '\0000') -ErrorAction SilentlyContinue
            if ($prop -and $prop.'HardwareInformation.MemorySize') {
                $matchId = [string]$prop.'MatchingDeviceId'
                if ($vendorDev -and $matchId -and $matchId -like "*$vendorDev*") {
                    $qwVal = (Get-Item ($sk.PSPath + '\0000')).GetValue('HardwareInformation.qwMemorySize')
                    if ($qwVal) {
                        $totalVram = [uint64]$qwVal
                        break
                    }
                }
            }
        }
    } catch { }

    # Method 2: WMI AdapterRAM (often wrong for AMD but better than nothing)
    if ($totalVram -eq 0) {
        $wmiRam = $primary.AdapterRAM
        if ($wmiRam -and $wmiRam -gt 0) {
            $totalVram = [uint64]$wmiRam
        }
    }

    # Method 3: NVIDIA nvidia-smi
    $vendor = Extract-Vendor $primary
    if ($totalVram -eq 0 -and $vendor -eq 'NVIDIA') {
        try {
            $output = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $output) {
                foreach ($line in $output) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match '^\\d+') {
                        $totalVram = [uint64]([int]$matches[0] * 1MB)
                        break
                    }
                }
            }
        } catch { }
    }

    return [PSCustomObject]@{
        PnpDevice  = $pnpDevice
        WmiInfo    = $primary
        Name       = $primary.Name
        Vendor     = Extract-Vendor $primary
        Driver     = $primary.DriverVersion
        VRAM       = $totalVram
        Resolution = if ($primary.CurrentHorizontalResolution -gt 0) {
            '{0}x{1} @ {2}Hz' -f $primary.CurrentHorizontalResolution,
                                 $primary.CurrentVerticalResolution,
                                 $primary.CurrentRefreshRate
        } else { 'N/A (headless)' }
        InstanceId = $pnpId
    }
}

function Extract-Vendor($Controller) {
    $name = $Controller.Name
    $pnpId = $Controller.PNPDeviceID

    if ($pnpId -match 'VEN_10DE')       { return 'NVIDIA' }
    if ($pnpId -match 'VEN_1002')       { return 'AMD' }
    if ($pnpId -match 'VEN_8086')       { return 'Intel' }
    if ($pnpId -match 'VEN_1A03')       { return 'ASPEED' }
    if ($pnpId -match 'VEN_15AD')       { return 'VMware' }
    if ($pnpId -match 'VEN_1234')       { return 'QEMU/Bochs' }
    if ($name -match 'NVIDIA')          { return 'NVIDIA' }
    if ($name -match 'Radeon|AMD')      { return 'AMD' }
    if ($name -match 'Intel')           { return 'Intel' }
    return 'Unknown'
}

# ═══════════════════════════════════════════════════════════════
#  Display Configuration Save/Restore (CCD API)
#
#  Uses QueryDisplayConfig / SetDisplayConfig to snapshot and
#  restore the full multi-monitor layout (resolution, refresh,
#  position, orientation) before cycling the GPU.
#
#  The C# interop types are written to a temp .cs file so both
#  the main process and the watchdog can compile them independently.
# ═══════════════════════════════════════════════════════════════

$csFile = Join-Path $env:TEMP 'vpurge-displayconfig.cs'

$csCode = @'
using System;
using System.Runtime.InteropServices;

public static class DisplayConfigHelper
{
    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_2DREGION { public uint cx; public uint cy; }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_PATH_SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        public int targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct POINTL { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO
    {
        public ulong pixelRate;
        public DISPLAYCONFIG_RATIONAL hSyncFreq;
        public DISPLAYCONFIG_RATIONAL vSyncFreq;
        public DISPLAYCONFIG_2DREGION activeSize;
        public DISPLAYCONFIG_2DREGION totalSize;
        public uint videoStandard;
        public uint scanLineOrdering;
        public DISPLAYCONFIG_RATIONAL syncWidth;
        public DISPLAYCONFIG_RATIONAL syncHeight;
        public uint hBorder;
        public uint vBorder;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_TARGET_MODE
    {
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_SOURCE_MODE
    {
        public uint width;
        public uint height;
        public uint pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct DISPLAYCONFIG_MODE_INFO_UNION
    {
        [FieldOffset(0)] public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(0)] public DISPLAYCONFIG_SOURCE_MODE sourceMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct DISPLAYCONFIG_MODE_INFO
    {
        public uint infoType;
        public uint id;
        public LUID adapterId;
        public DISPLAYCONFIG_MODE_INFO_UNION modeInfo;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int QueryDisplayConfig(
        uint flags,
        ref uint numPathArrayElements,
        IntPtr pathArray,
        ref uint numModeInfoArrayElements,
        IntPtr modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int SetDisplayConfig(
        uint numPathArrayElements,
        IntPtr pathArray,
        uint numModeInfoArrayElements,
        IntPtr modeInfoArray,
        uint flags);

    const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    const uint SDC_APPLY                    = 0x00000001;
    const uint SDC_SAVE_TO_DATABASE         = 0x00000002;
    const uint SDC_ALLOW_CHANGES            = 0x00000004;
    const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;

    public static byte[] Save()
    {
        int pathSize = Marshal.SizeOf(typeof(DISPLAYCONFIG_PATH_INFO));
        int modeSize = Marshal.SizeOf(typeof(DISPLAYCONFIG_MODE_INFO));

        // Start with a generous pre-allocation to avoid the null-pointer sizing call
        // that fails on some systems with ERROR_INVALID_PARAMETER (0x57).
        uint numPaths = 32;
        uint numModes = 64;

        for (int attempt = 0; attempt < 4; attempt++)
        {
            int pathsBytes = (int)numPaths * pathSize;
            int modesBytes = (int)numModes * modeSize;

            IntPtr pPaths = Marshal.AllocHGlobal(pathsBytes);
            IntPtr pModes = Marshal.AllocHGlobal(modesBytes);
            try
            {
                uint queryPaths = numPaths;
                uint queryModes = numModes;
                int hr = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,
                    ref queryPaths, pPaths,
                    ref queryModes, pModes,
                    IntPtr.Zero);

                if (hr == 0)
                {
                    // Success -- queryPaths/queryModes now hold actual counts
                    int realPathsBytes = (int)queryPaths * pathSize;
                    int realModesBytes = (int)queryModes * modeSize;

                    byte[] result = new byte[16 + realPathsBytes + realModesBytes];
                    BitConverter.GetBytes(queryPaths).CopyTo(result, 0);
                    BitConverter.GetBytes(queryModes).CopyTo(result, 4);
                    BitConverter.GetBytes((uint)pathSize).CopyTo(result, 8);
                    BitConverter.GetBytes((uint)modeSize).CopyTo(result, 12);
                    Marshal.Copy(pPaths, result, 16, realPathsBytes);
                    Marshal.Copy(pModes, result, 16 + realPathsBytes, realModesBytes);
                    return result;
                }

                if (hr == 122) // ERROR_INSUFFICIENT_BUFFER -- resize and retry
                {
                    numPaths = queryPaths;
                    numModes = queryModes;
                    continue;
                }

                throw new Exception("QueryDisplayConfig failed: 0x" + hr.ToString("X8"));
            }
            finally
            {
                Marshal.FreeHGlobal(pPaths);
                Marshal.FreeHGlobal(pModes);
            }
        }

        throw new Exception("QueryDisplayConfig: too many retries");
    }

    public static void Restore(byte[] data)
    {
        uint numPaths   = BitConverter.ToUInt32(data, 0);
        uint numModes   = BitConverter.ToUInt32(data, 4);
        int  pathSize   = (int)BitConverter.ToUInt32(data, 8);
        int  modeSize   = (int)BitConverter.ToUInt32(data, 12);
        int  pathsBytes = (int)numPaths * pathSize;
        int  modesBytes = (int)numModes * modeSize;

        IntPtr pPaths = Marshal.AllocHGlobal(pathsBytes);
        IntPtr pModes = Marshal.AllocHGlobal(modesBytes);
        try
        {
            Marshal.Copy(data, 16, pPaths, pathsBytes);
            Marshal.Copy(data, 16 + pathsBytes, pModes, modesBytes);
            uint flags = SDC_APPLY | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES | SDC_USE_SUPPLIED_DISPLAY_CONFIG;
            int hr = SetDisplayConfig(numPaths, pPaths, numModes, pModes, flags);
            if (hr != 0) throw new Exception("SetDisplayConfig failed: 0x" + hr.ToString("X8"));
        }
        finally
        {
            Marshal.FreeHGlobal(pPaths);
            Marshal.FreeHGlobal(pModes);
        }
    }
}
'@

# Write C# source to temp file (shared by main process and watchdog)
Set-Content -Path $csFile -Value $csCode -Encoding UTF8

# Compile in main process
try {
    Add-Type -Path $csFile -ErrorAction Stop
} catch {
    Write-Icon "!" "Display config helper compile failed: $_" Yellow
}

function Save-DisplayConfig {
    param([string]$Path)
    try {
        $bytes = [DisplayConfigHelper]::Save()
        [System.IO.File]::WriteAllBytes($Path, $bytes)
        return $true
    }
    catch {
        Write-Icon "!" "Could not save display config: $_" Yellow
        return $false
    }
}

function Restore-DisplayConfig {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        [DisplayConfigHelper]::Restore($bytes)
        return $true
    }
    catch {
        Write-Icon "!" "Could not restore display config: $_" Yellow
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════
#  List mode
# ═══════════════════════════════════════════════════════════════

if ($ListOnly) {
    Write-Host "`n  ╔══════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║          Display Adapters on this system         ║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor DarkCyan

    $wmiAll = @(Get-CimInstance Win32_VideoController)

    foreach ($c in $wmiAll) {
        $vendor  = Extract-Vendor $c
        $vram    = if ($c.AdapterRAM) { Format-Size $c.AdapterRAM } else { 'N/A' }
        $res     = if ($c.CurrentHorizontalResolution -gt 0) {
            '{0}x{1}' -f $c.CurrentHorizontalResolution, $c.CurrentVerticalResolution
        } else { 'inactive' }
        $primary = if ($c.CurrentHorizontalResolution -gt 0) { 'PRIMARY' } else { 'standby' }
        $status  = if ($c.Availability -eq 3) { 'OK' } else { 'Stopped' }
        $color   = if ($status -eq 'OK' -and $primary -eq 'PRIMARY') { 'Green' }
                    elseif ($status -eq 'OK') { 'Yellow' }
                    else { 'DarkGray' }

        Write-Host "`n  [$primary] " -ForegroundColor $color -NoNewline
        Write-Host $c.Name
        Write-Host "    Vendor:     $vendor" -ForegroundColor DarkGray
        Write-Host "    VRAM:       $vram" -ForegroundColor DarkGray
        Write-Host "    Resolution: $res" -ForegroundColor DarkGray
        Write-Host "    Driver:     $($c.DriverVersion)" -ForegroundColor DarkGray
        Write-Host "    Status:     $status" -ForegroundColor DarkGray
        Write-Host "    PnP ID:     $($c.PNPDeviceID)" -ForegroundColor DarkGray
    }

    Write-Host ""
    return
}

# ═══════════════════════════════════════════════════════════════
#  Auto-detect primary adapter
# ═══════════════════════════════════════════════════════════════

Write-Host "`n  🔍 Detecting primary display adapter..." -ForegroundColor Cyan

$adapter = Find-PrimaryDisplayAdapter

if (-not $adapter -or -not $adapter.PnpDevice) {
    Write-Icon "✖" "Could not detect a primary display adapter." Red
    Write-Host "`n  Possible reasons:" -ForegroundColor DarkGray
    Write-Host "    - No display driver is installed (Microsoft Basic Adapter)" -ForegroundColor DarkGray
    Write-Host "    - Running in a headless / RDP session" -ForegroundColor DarkGray
    Write-Host "    - All GPUs are in an error state" -ForegroundColor DarkGray
    Write-Host "`n  Run with -ListOnly to see what's available." -ForegroundColor DarkGray
    exit 1
}

# ═══════════════════════════════════════════════════════════════
#  Show adapter info
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "  │  PRIMARY GPU DETECTED                            │" -ForegroundColor White
Write-Host "  ├──────────────────────────────────────────────────┤" -ForegroundColor White
Write-Host "  │  Name:       $($adapter.Name)" -ForegroundColor White
Write-Host "  │  Vendor:     $($adapter.Vendor)" -ForegroundColor DarkGray
Write-Host "  │  VRAM:       $(Format-Size $adapter.VRAM)" -ForegroundColor DarkGray
Write-Host "  │  Resolution: $($adapter.Resolution)" -ForegroundColor DarkGray
Write-Host "  │  Driver:     $($adapter.Driver)" -ForegroundColor DarkGray
Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor White

# ═══════════════════════════════════════════════════════════════
#  Confirm & warn
# ═══════════════════════════════════════════════════════════════

if (-not $Force) {
    Write-Host ""
    Write-Host "  This will restart your primary display adapter:" -ForegroundColor Yellow
       Write-Host "    $($adapter.Name)" -ForegroundColor White
    Write-Host ""
    Write-Host "  ALL displays connected to this GPU will go BLACK" -ForegroundColor Yellow
    Write-Host "  for ~${WaitSeconds} seconds while the adapter cycles." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Any application currently using the GPU (browsers," -ForegroundColor Red
    Write-Host "  games, editors, renderers, etc.) will likely CRASH" -ForegroundColor Red
    Write-Host "  and you may lose unsaved work." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Make sure you have saved all your work before proceeding." -ForegroundColor DarkGray
    Write-Host ""
    $answer = Read-Host "  Do you want to continue? [Y/N]"
    if ($answer -notmatch '^[Yy]') {
        Write-Host ""
        Write-Icon "--" "Operation cancelled by user." Yellow
        Write-Host ""
        exit 0
    }
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
#  Cycle: Save config → Watchdog → Disable
#
#  CRITICAL DESIGN: The re-enable runs in a SEPARATE PowerShell
#  process spawned BEFORE the disable. If the main process dies
#  when the GPU goes dark, the watchdog still re-enables it.
#
#  The watchdog also restores the saved display configuration
#  (resolution, refresh, multi-monitor layout) after re-enable.
# ═══════════════════════════════════════════════════════════════

$instanceId = $adapter.InstanceId
$logFile   = Join-Path $env:TEMP 'vpurge-watchdog.log'
$configFile = Join-Path $env:TEMP 'vpurge-displayconfig.bin'
$retries   = 5
$retryWait = 3

# --- Save display configuration BEFORE anything else ---
Write-Icon "💾" "Saving current display configuration..." Cyan
$configSaved = Save-DisplayConfig -Path $configFile
if ($configSaved) {
    Write-Icon "✔" "Display config saved to: $configFile" Green
} else {
    Write-Icon "!" "Display config could not be saved (config restore will be skipped)" Yellow
}

# --- Measure VRAM usage BEFORE purge ---
Write-Icon "📊" "Measuring VRAM usage before purge..." Cyan
$vramBefore = Get-VRAMUsage -AdapterName $adapter.Name
if ($null -ne $vramBefore) {
    Write-Icon "📊" "VRAM in use: $(Format-Size $vramBefore)" White
} else {
    Write-Icon "!" "Could not measure VRAM usage (counters not available)" DarkGray
}

# --- Generate standalone restore script for manual use (if watchdog fails) ---
if ($configSaved) {
    $restoreScript = Join-Path $env:TEMP 'vpurge-restore.ps1'
    @"
`$csFile = '$csFile'
`$configFile = '$configFile'
Add-Type -Path `$csFile -ErrorAction Stop
`$bytes = [System.IO.File]::ReadAllBytes(`$configFile)
[DisplayConfigHelper]::Restore(`$bytes)
Write-Host 'Display configuration restored.' -ForegroundColor Green
"@ | Set-Content -Path $restoreScript -Encoding UTF8
}

# --- Spawn watchdog as a SEPARATE process ---
#     This process will survive even if the main PS dies.
#     It re-enables the GPU AND restores display config.

$watchdogScript = @"
`$ErrorActionPreference = 'Continue'
`$log = '$logFile'
`$configFile = '$configFile'
`$csFile = '$csFile'
`$instanceId = '$instanceId'
`$wait = $WaitSeconds
`$retries = $retries
`$retryWait = $retryWait
`$configSaved = `$$configSaved

function Log(`$msg) {
    Add-Content -Path `$log -Value "[`$(Get-Date -Format 'HH:mm:ss')] `$msg"
}

Log('WATCHDOG STARTED -- waiting {0}s before re-enable...' -f `$wait)

# Pre-compile display config helper during the wait
if (`$configSaved -and (Test-Path `$csFile)) {
    Log('Compiling display config helper...')
    try { Add-Type -Path `$csFile -ErrorAction Stop }
    catch { Log('Add-Type failed: {0}' -f `$_.Exception.Message) }
}

Start-Sleep -Seconds `$wait

for (`$i = 1; `$i -le `$retries; `$i++) {
    Log('Attempt {0}/{1}: pnputil /enable-device...' -f `$i, `$retries)

    # Method 1: pnputil (native, most reliable)
    `$proc = Start-Process -FilePath 'pnputil.exe' `
                           -ArgumentList '/enable-device', `"`$instanceId`" `
                           -NoNewWindow -Wait -PassThru `
                           -ErrorAction SilentlyContinue

    if (`$null -ne `$proc -and `$proc.ExitCode -eq 0) {
        Log('pnputil returned exit code 0 (success)')
    }
    elseif (`$null -ne `$proc) {
        Log('pnputil returned exit code {0}' -f `$proc.ExitCode)
    }
    else {
        Log('pnputil failed to start')
    }

    # Method 2: Enable-PnpDevice as fallback
    Log('Fallback: Enable-PnpDevice...')
    try {
        Enable-PnpDevice -InstanceId `$instanceId -Confirm:`$false -ErrorAction Stop
        Log('Enable-PnpDevice succeeded')
    }
    catch {
        Log('Enable-PnpDevice failed: {0}' -f `$_.Exception.Message)
    }

    # Verify
    Start-Sleep -Seconds `$retryWait
    `$dev = Get-PnpDevice -InstanceId `$instanceId -ErrorAction SilentlyContinue
    if (`$dev -and `$dev.Status -eq 'OK') {
        Log('VERIFY OK -- adapter re-enabled successfully')

        # Restart DWM first to reclaim hardware-accelerated composition
        # Must happen BEFORE config restore, otherwise DWM restart overwrites the restored config
        Log('Restarting DWM for hardware acceleration...')
        try {
            Stop-Process -Name dwm -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
            Log('DWM restarted successfully')
        }
        catch {
            Log('DWM restart failed: {0}' -f `$_.Exception.Message)
        }

        # Restore display configuration AFTER DWM restart so it isn't overwritten
        if (`$configSaved -and (Test-Path `$configFile)) {
            Log('Restoring display configuration...')
            try {
                `$bytes = [System.IO.File]::ReadAllBytes(`$configFile)
                [DisplayConfigHelper]::Restore(`$bytes)
                Log('Display configuration restored successfully')
            }
            catch {
                Log('Display config restore failed: {0}' -f `$_.Exception.Message)
            }
        }

        break
    }

    if (`$i -lt `$retries) {
        Log('Status: {0} -- retrying in {1}s...' -f `$dev.Status, `$retryWait)
    }
    else {
        Log('ALL RETRIES EXHAUSTED -- manual intervention required')
        Log('Re-enable: pnputil /enable-device "' + `$instanceId + '"')
        if (`$configSaved) {
            Log('Restore config: powershell -File "' + `$csFile.Replace('.cs', '-restore.ps1') + '"')
        }
    }
}

Log('WATCHDOG FINISHED')
"@

# Clear previous log
Set-Content -Path $logFile -Value "[$(Get-Date -Format 'HH:mm:ss')] vpurge watchdog for: $($adapter.Name)" -Encoding UTF8

# Write the watchdog script to a temp file and launch it as a separate process
$watchdogFile = Join-Path $env:TEMP 'vpurge-watchdog.ps1'
Set-Content -Path $watchdogFile -Value $watchdogScript -Encoding UTF8

Write-Icon "🛡" "Spawning watchdog (separate process) to re-enable in ${WaitSeconds}s..." Cyan
Start-Process -FilePath 'powershell.exe' `
              -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NonInteractive','-File',"$watchdogFile" `
              -WindowStyle Hidden

# Give the watchdog a moment to initialize
Start-Sleep -Milliseconds 500

# --- Disable ---
Write-Icon "⏳" "Disabling $($adapter.Name)..." Yellow
try {
    Disable-PnpDevice -InstanceId $instanceId -Confirm:$false
}
catch {
    Write-Icon "✖" "Failed to disable: $_" Red
    Write-Icon "⟳" "Attempting emergency re-enable..." Red
    pnputil /enable-device "$instanceId" 2>$null
    Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}

Write-Icon "⏳" "GPU disabled. Watchdog will re-enable in ${WaitSeconds}s..." DarkGray
Write-Host "  (screen may go dark -- the watchdog is independent of this terminal)" -ForegroundColor DarkGray

# ═══════════════════════════════════════════════════════════════
#  Verify & Restore (main process)
# ═══════════════════════════════════════════════════════════════

$totalWait = $WaitSeconds + ($retries * $retryWait) + 5
$elapsed   = 0

while ($elapsed -lt $totalWait) {
    Start-Sleep -Seconds 2
    $elapsed += 2

    $verify = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
    if ($verify -and $verify.Status -eq 'OK') {
        # --- Restore display config AFTER DWM restart (belt & suspenders) ---
        # Watchdog already restarted DWM and restored config.
        # We do NOT restart DWM here because killing dwm.exe from this
        # terminal process kills our own session, preventing the summary output.
        if ($configSaved) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($configFile)
                [DisplayConfigHelper]::Restore($bytes)
            } catch {
                # Already restored by watchdog or config already correct -- ignore
            }
        }

        # --- Measure VRAM usage AFTER purge ---
        $vramAfter = $null
        if ($null -ne $vramBefore) {
            Start-Sleep -Seconds 1
            $vramAfter = Get-VRAMUsage -AdapterName $adapter.Name
        }

        Write-Host ""
        Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║  VRAM PURGE COMPLETE                              ║" -ForegroundColor Green
        Write-Host "  ╠════════════════════════════════════════════════════╣" -ForegroundColor Green
        Write-Host "  ║  $($adapter.Name)" -ForegroundColor Green
        if ($null -ne $vramBefore -and $null -ne $vramAfter) {
            $freed = [uint64]([int64]$vramBefore - [int64]$vramAfter)
            if ($freed -lt 0) { $freed = [uint64]0 }
            Write-Host ("  ║  VRAM before:  {0,10}" -f (Format-Size $vramBefore)) -ForegroundColor White
            Write-Host ("  ║  VRAM after:   {0,10}" -f (Format-Size $vramAfter)) -ForegroundColor White
            Write-Host ("  ║  Freed:        {0,10}" -f (Format-Size $freed)) -ForegroundColor Cyan
        } elseif ($null -ne $vramBefore) {
            Write-Host ("  ║  VRAM before:  {0,10}" -f (Format-Size $vramBefore)) -ForegroundColor White
            Write-Host "  ║  VRAM after:   could not measure" -ForegroundColor DarkGray
        }
        Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        exit 0
    }
}

# If we get here, the main process survived but the adapter isn't back yet
Write-Host ""
Write-Icon "!" "Adapter not back yet. The watchdog may still be retrying." Yellow
Write-Icon "📄" "Check log: $logFile" Yellow
Write-Icon "📄" "Config backup: $configFile" Yellow
if ($configSaved) {
    Write-Host "  Manual restore: powershell -File `"$env:TEMP\vpurge-restore.ps1`"" -ForegroundColor DarkGray
}
Write-Host ""
exit 1
