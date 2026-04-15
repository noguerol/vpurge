@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =================================================================
rem  vpurge - Windows installer
rem  Installs vpurge system-wide so you can run it from anywhere.
rem =================================================================

chcp 65001 >nul 2>&1
title vpurge installer

rem -- Resolve source directory BEFORE elevating --
set "SOURCE_DIR=%~dp0"
if "%SOURCE_DIR:~-1%"=="\" set "SOURCE_DIR=%SOURCE_DIR:~0,-1%"

rem -- Self-elevate to Administrator --
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo   Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath cmd.exe -ArgumentList '/c', '\"%SOURCE_DIR%\install.bat\"' -Verb RunAs -WorkingDirectory '%SOURCE_DIR%'"
    exit /b
)

rem -- Configuration --
set "INSTALL_DIR=%ProgramFiles%\vpurge"
set "WRAPPER=%INSTALL_DIR%\vpurge.cmd"
set "PS1_FILE=%INSTALL_DIR%\vpurge.ps1"
set "SOURCE_PS1=%SOURCE_DIR%\vpurge.ps1"
set "STARTMENU_DIR=%ProgramData%\Microsoft\Windows\Start Menu\Programs\vpurge"
set "SHORTCUT=%STARTMENU_DIR%\vpurge.lnk"

rem -- Banner --
echo.
echo   ========================================
echo      vpurge installer for Windows
echo   ========================================
echo.
echo   Source : %SOURCE_PS1%
echo   Target : %INSTALL_DIR%
echo.

rem -- Check source file exists --
if not exist "%SOURCE_PS1%" (
    echo   [ERROR] vpurge.ps1 not found.
    echo.
    echo   Expected: %SOURCE_PS1%
    echo   Source dir contents:
    dir /b "%SOURCE_DIR%\*" 2>nul
    echo.
    pause
    exit /b 1
)

rem -- Already installed? --
if exist "%PS1_FILE%" (
    echo   vpurge is already installed. Options:
    echo.
    echo     [R] Reinstall ^(update^)
    echo     [U] Uninstall
    echo     [C] Cancel
    echo.
    set /p "CHOICE=  Your choice [R/U/C]: "
    if /i "!CHOICE!"=="R" (
        echo.
        call :do_install
        goto :done
    )
    if /i "!CHOICE!"=="U" (
        echo.
        call :do_uninstall
        goto :done
    )
    echo.
    echo   Cancelled.
    goto :done
)

rem -- Fresh install --
call :do_install
goto :done

rem =================================================================
rem  INSTALL
rem =================================================================
:do_install

rem --- Kill any running vpurge/watchdog processes ---
echo   [0/3] Stopping any running vpurge processes ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue |" ^
    "Where-Object { $_.CommandLine -like '*vpurge*' } |" ^
    "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue };" ^
    "Write-Host '   Done.'"
timeout /t 2 /nobreak >nul 2>&1

rem --- Remove old files forcefully ---
if exist "%INSTALL_DIR%" (
    echo   Removing old installation ...
    del /f /q "%PS1_FILE%" >nul 2>&1
    del /f /q "%WRAPPER%" >nul 2>&1
    del /f /q "%INSTALL_DIR%\vpurge.ico" >nul 2>&1
)

rem --- Create directory ---
if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
    if !errorLevel! neq 0 (
        echo   [ERROR] Failed to create %INSTALL_DIR%
        pause
        exit /b 1
    )
)

rem --- Copy PS1 using PowerShell to preserve BOM UTF-8 ---
echo   [1/3] Copying vpurge.ps1 ...
set "COPY_OK=FAIL"
for /f "delims=" %%R in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Copy-Item -Path '%SOURCE_PS1%' -Destination '%PS1_FILE%' -Force -ErrorAction Stop; Write-Host 'OK' } catch { Write-Host ('FAIL: ' + $_.Exception.Message) }"') do set "COPY_OK=%%R"
echo   Copy result: !COPY_OK!
if not "!COPY_OK!"=="OK" (
    echo   [ERROR] Failed to copy vpurge.ps1
    echo   !COPY_OK!
    pause
    exit /b 1
)

rem --- Create wrapper CMD ---
echo   [2/3] Creating vpurge.cmd wrapper ...
> "%WRAPPER%" (
    echo @echo off
    echo rem -- vpurge wrapper --
    echo powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%" %%*
)

rem --- Verify files exist ---
echo   [verify] Checking installed files ...
if not exist "%PS1_FILE%" (
    echo   [ERROR] vpurge.ps1 not found after copy!
    pause
    exit /b 1
)
if not exist "%WRAPPER%" (
    echo   [ERROR] vpurge.cmd not found after creation!
    pause
    exit /b 1
)
echo   [verify] Files OK.

rem --- Add to system PATH ---
echo   [3/3] Adding to system PATH ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$add = '%INSTALL_DIR%';" ^
    "$old = [Environment]::GetEnvironmentVariable('Path','Machine');" ^
    "if ($old -notlike \"*$add*\") {" ^
    "    [Environment]::SetEnvironmentVariable('Path', $old + ';' + $add, 'Machine');" ^
    "    Write-Host '   PATH updated.';" ^
    "} else {" ^
    "    Write-Host '   Already in PATH.';" ^
    "}"

if !errorLevel! neq 0 (
    echo   [WARNING] PATH update may have failed. Trying manual method ...
    set "PATH_KEY=HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    for /f "tokens=2,*" %%A in ('reg query "!PATH_KEY!" /v Path 2^>nul ^| findstr /i "Path"') do set "CURRENT_PATH=%%B"
    echo !CURRENT_PATH! | findstr /i /c:"%INSTALL_DIR%" >nul
    if !errorLevel! neq 0 (
        reg add "!PATH_KEY!" /v Path /t REG_EXPAND_SZ /d "!CURRENT_PATH!;%INSTALL_DIR%" /f >nul 2>&1
        if !errorLevel! equ 0 (
            echo   [OK] PATH updated via registry.
        ) else (
            echo   [ERROR] Could not update PATH. Add manually: %INSTALL_DIR%
        )
    )
)

rem --- Start Menu shortcut ---
echo.
set /p "STARTMENU=  Add Start Menu shortcut? [Y/N]: "
if /i "!STARTMENU!"=="Y" (
    call :do_shortcut
) else (
    echo   Skipping Start Menu shortcut.
)

echo.
echo   ========================================
echo   OK  vpurge installed successfully!
echo   ========================================
echo.
echo   Location : %INSTALL_DIR%
echo.
echo   Files installed:
dir /b "%INSTALL_DIR%\*" 2>nul
echo.
echo   Usage:
echo     vpurge            Purge VRAM on primary GPU
echo     vpurge -ListOnly  List all display adapters
echo     vpurge -Force     Skip countdown
echo.
echo   NOTE: Close and reopen terminals for PATH to take effect.
echo.
goto :eof

rem =================================================================
rem  START MENU SHORTCUT
rem =================================================================
:do_shortcut

if not exist "%STARTMENU_DIR%" mkdir "%STARTMENU_DIR%"

rem --- Generate custom infinity icon ---
echo   Generating custom icon ...
set "ICON_FILE=%INSTALL_DIR%\vpurge.ico"
set "ICON_PS1=%TEMP%\vpurge_makeicon.ps1"

(
    echo Add-Type -AssemblyName System.Drawing
    echo.
    echo $size = 256
    echo $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb^)
    echo $g = [System.Drawing.Graphics]::FromImage($bmp^)
    echo $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    echo $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    echo $g.Clear([System.Drawing.Color]::Transparent^)
    echo.
    echo $green = [System.Drawing.Color]::FromArgb(255, 0, 200, 110^)
    echo.
    echo $font = New-Object System.Drawing.Font('Segoe UI Symbol', 180, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel^)
    echo $sf = New-Object System.Drawing.StringFormat
    echo $sf.Alignment = [System.Drawing.StringAlignment]::Center
    echo $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    echo $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size^)
    echo $g.DrawString([char]0x221E, $font, (New-Object System.Drawing.SolidBrush($green^)^), $rect, $sf^)
    echo $g.Dispose(^)
    echo.
    echo $pngStream = New-Object System.IO.MemoryStream
    echo $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png^)
    echo $pngBytes = $pngStream.ToArray(^)
    echo $pngStream.Dispose(^)
    echo.
    echo $icoPath = '%INSTALL_DIR%\vpurge.ico'
    echo $fs = [System.IO.File]::Create($icoPath^)
    echo $bw = New-Object System.IO.BinaryWriter($fs^)
    echo $bw.Write([UInt16]0^)
    echo $bw.Write([UInt16]1^)
    echo $bw.Write([UInt16]1^)
    echo $bw.Write([Byte]0^)
    echo $bw.Write([Byte]0^)
    echo $bw.Write([Byte]0^)
    echo $bw.Write([Byte]0^)
    echo $bw.Write([UInt16]1^)
    echo $bw.Write([UInt16]32^)
    echo $bw.Write([UInt32]$pngBytes.Length^)
    echo $bw.Write([UInt32]22^)
    echo $bw.Write($pngBytes^)
    echo $bw.Dispose(^)
    echo $fs.Dispose(^)
    echo Write-Host 'OK'
) > "%ICON_PS1%"

set "ICON_RESULT=FAIL"
for /f "delims=" %%R in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ICON_PS1%" 2^>^&1') do set "ICON_RESULT=%%R"
del "%ICON_PS1%" >nul 2>&1

if not "!ICON_RESULT!"=="OK" (
    echo   [WARNING] Icon generation failed, using system default.
    set "ICON_REF=%SystemRoot%\System32\shell32.dll,220"
) else (
    echo   [OK] Custom icon created: %ICON_FILE%
    set "ICON_REF=%ICON_FILE%"
)

rem --- Create shortcut ---
echo   Creating Start Menu shortcut ...
set "VBS=%TEMP%\vpurge_shortcut.vbs"
> "%VBS%" (
    echo Set ws = WScript.CreateObject("WScript.Shell"^)
    echo Set lnk = ws.CreateShortcut("%SHORTCUT%"^)
    echo lnk.TargetPath = "%WRAPPER%"
    echo lnk.Arguments = "-Force"
    echo lnk.WorkingDirectory = "%INSTALL_DIR%"
    echo lnk.Description = "Purge GPU VRAM"
    echo lnk.IconLocation = "!ICON_REF!"
    echo lnk.Save
    echo WScript.Echo "OK"
)
set "VBS_RESULT=FAIL"
for /f "delims=" %%R in ('cscript //nologo "%VBS%" 2^>^&1') do set "VBS_RESULT=%%R"
del "%VBS%" >nul 2>&1

if "!VBS_RESULT!"=="OK" (
    echo   [OK] Shortcut created: %SHORTCUT%
) else (
    echo   [ERROR] Failed to create shortcut via VBS. Trying PowerShell ...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$ws = New-Object -ComObject WScript.Shell;" ^
        "$sc = $ws.CreateShortcut('%SHORTCUT%');" ^
        "$sc.TargetPath = '%WRAPPER%';" ^
        "$sc.Arguments = '-Force';" ^
        "$sc.WorkingDirectory = '%INSTALL_DIR%';" ^
        "$sc.Description = 'Purge GPU VRAM';" ^
        "$sc.IconLocation = '!ICON_REF!';" ^
        "$sc.Save();"
    if !errorLevel! equ 0 (
        echo   [OK] Shortcut created via PowerShell.
    ) else (
        echo   [ERROR] Could not create shortcut.
    )
)

goto :eof

rem =================================================================
rem  UNINSTALL
rem =================================================================
:do_uninstall

echo   [1/3] Removing files ...
if exist "%INSTALL_DIR%" (
    rd /s /q "%INSTALL_DIR%"
    echo          Deleted %INSTALL_DIR%
) else (
    echo          Directory not found, skipping.
)

echo   [2/3] Removing from PATH ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$remove = '%INSTALL_DIR%';" ^
    "$old = [Environment]::GetEnvironmentVariable('Path','Machine');" ^
    "if ($old -like \"*$remove*\") {" ^
    "    $new = ($old -split ';' | Where-Object { $_ -ne $remove }) -join ';';" ^
    "    [Environment]::SetEnvironmentVariable('Path', $new, 'Machine');" ^
    "    Write-Host '   PATH updated.';" ^
    "} else {" ^
    "    Write-Host '   Not in PATH.';" ^
    "}"

echo   [3/3] Removing Start Menu shortcut ...
if exist "%STARTMENU_DIR%" (
    rd /s /q "%STARTMENU_DIR%"
    echo          Deleted %STARTMENU_DIR%
) else (
    echo          Not found, skipping.
)

echo.
echo   OK  vpurge uninstalled.
echo.
goto :eof

rem -- Done --
:done
pause
exit /b
