@echo off
setlocal

set "SATNET_DIR=C:\Satnet"
set "EXE_NAME=satnet.exe"
set "DOWNLOAD_URL=https://satnet.cv/windows.exe"
set "LOG_FILE=%SATNET_DIR%\satnet.log"

:: Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Please run as Administrator.
    pause
    exit /b 1
)

cls
echo =========================================
echo      Welcome to the Satnet Installer
echo =========================================
echo.
echo By installing this software, you agree to share your internet bandwidth.
echo.
echo Terms ^& Conditions:
echo 1. You authorize this device to act as a proxy node.
echo 2. We are not responsible for traffic passed through your node.
echo 3. You may uninstall at any time using 'satnet-uninstall'.
echo.

set /p confirm="Do you accept these terms? (y/N): "
if /i not "%confirm%"=="y" (
    echo Installation aborted.
    pause
    exit /b 1
)

echo.
echo Starting installation...

:: Create directory
if not exist "%SATNET_DIR%" mkdir "%SATNET_DIR%"
cd /d "%SATNET_DIR%"

:: Download the executable
echo Downloading client binary from %DOWNLOAD_URL%...
powershell -Command "Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%EXE_NAME%'"

if not exist "%EXE_NAME%" (
    echo Error: Download failed. Please check your internet connection or URL.
    pause
    exit /b 1
)

echo.
echo Launching client to generate Node ID...
echo Please wait 5 seconds...

:: Run temporarily to capture the initial output (Node ID)
start /b "" cmd /c "%EXE_NAME% > init_capture.log 2>&1"

:: Wait for the application to initialize and print the ID
timeout /t 5 /nobreak >nul

echo.
echo =========================================
echo          CLIENT OUTPUT LOG
echo =========================================
if exist init_capture.log (
    type init_capture.log
    :: Append initial capture to the main log for history
    type init_capture.log >> "%LOG_FILE%"
    del init_capture.log
) else (
    echo No output captured.
)
echo =========================================
echo.

:: Kill the temporary process so we can register it as a proper service
taskkill /F /IM "%EXE_NAME%" >nul 2>&1

echo Configuring Startup Task...
:: Create a scheduled task to run as SYSTEM on startup, piping output to log
schtasks /create /tn "SatnetClient" /tr "cmd /c \"\"%SATNET_DIR%\%EXE_NAME%\"\" >> \"%LOG_FILE%\" 2>>&1" /sc onstart /ru SYSTEM /f >nul

echo Starting background service...
schtasks /run /tn "SatnetClient" >nul

:: Create the uninstaller script
(
echo @echo off
echo echo Stopping service...
echo schtasks /end /tn "SatnetClient" 2^>nul
echo schtasks /delete /tn "SatnetClient" /f 2^>nul
echo taskkill /F /IM "%EXE_NAME%" 2^>nul
echo echo Removing files...
echo rmdir /s /q "%SATNET_DIR%"
echo del "%%SystemRoot%%\satnet-uninstall.bat"
echo echo Satnet uninstalled successfully.
echo pause
) > "%SystemRoot%\satnet-uninstall.bat"

echo.
echo Success! Satnet is installed.
echo The application will run automatically when the computer starts.
echo If it doesnt run immediately, or goes offline, restarting your PC will fix it.
echo.
echo To uninstall, run: satnet-uninstall
echo.
pause
