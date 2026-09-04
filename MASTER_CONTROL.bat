@echo off
title RDP MASTER CONTROL PANEL
color 0B

:MENU
cls
echo ============================================================
echo               RDP MASTER CONTROL PANEL
echo ============================================================
echo.
echo   [1] 🧹 RUN HEAVY STORAGE CLEANUP (Frees ~80GB)
echo   [2] 🔄 BACKUP TO GOOGLE DRIVE (D:\GoogleDriveSync)
echo   [3] 🗑️ PURGE DEVICE FROM TAILSCALE
echo   [4] 🛑 INITIATE SELF-DESTRUCT (Stops GitHub Action)
echo   [5] ❌ EXIT
echo.
echo ============================================================
set /p choice="Select an option (1-5): "

if "%choice%"=="1" goto CLEANUP
if "%choice%"=="2" goto BACKUP
if "%choice%"=="3" goto PURGE
if "%choice%"=="4" goto DESTRUCT
if "%choice%"=="5" goto EXIT
goto MENU

:CLEANUP
cls
color 0E
echo ============================================================
echo   INITIATING MASSIVE DISK CLEANUP...
echo   (This may take 5-10 minutes. Do not close this window)
echo ============================================================
echo.
powershell -Command "$paths = @('C:\Android', 'C:\hostedtoolcache\windows', 'C:\ghcup', 'C:\rtools45', 'C:\Julia', 'C:\Strawberry', 'C:\mingw64', 'C:\mingw32', 'C:\Miniconda', 'C:\msys64', 'C:\actionarchivecache', 'C:\npm', 'C:\vcpkg', 'C:\SeleniumWebDrivers', 'C:\selenium', 'C:\Program Files\Microsoft Visual Studio', 'C:\Program Files\dotnet', 'C:\Program Files\MongoDB', 'C:\Program Files\MySQL', 'C:\Program Files\Microsoft SQL Server', 'C:\ProgramData\Package Cache'); foreach ($p in $paths) { if (Test-Path $p) { Write-Host 'Deleting: ' $p; cmd.exe /c `"rmdir /s /q `"$p`"`" } }"
echo.
echo [ OK ] Cleanup Complete! Check WizTree for new free space.
pause
goto MENU

:BACKUP
cls
color 1F
echo ============================================================
echo   AUTO-BACKUP SEQUENCE
echo ============================================================
echo.
echo This will upload everything inside D:\GoogleDriveSync to 'RDP_Backup'.
echo IMPORTANT: Make sure you ran 'rclone config' and named it 'gdrive'!
echo.
pause
echo Starting high-speed transfer...
rclone copy "D:\GoogleDriveSync" gdrive:RDP_Backup -P --transfers 16 --drive-chunk-size 128M
echo.
echo [ OK ] Backup Complete!
pause
goto MENU

:PURGE
cls
color 0C
echo ============================================================
echo   TAILSCALE DEVICE PURGE
echo ============================================================
echo.
echo This will permanently delete this machine from your Tailscale network!
pause
echo.
powershell -Command "$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('%TAILSCALE_API_KEY%:')); $tn = [uri]::EscapeDataString('%TAILSCALE_TAILNET%'); $hostName = $env:COMPUTERNAME; $list = Invoke-RestMethod -Uri 'https://api.tailscale.com/api/v2/tailnet/$tn/devices' -Headers @{ Authorization = 'Basic $auth' }; $device = $list.devices | Where-Object { $_.hostname -eq $hostName }; if ($device) { Invoke-RestMethod -Method Delete -Uri 'https://api.tailscale.com/api/v2/device/$($device.id)' -Headers @{ Authorization = 'Basic $auth' }; Write-Host '[ OK ] Device purged successfully!' } else { Write-Host '[ ! ] Could not find device on Tailscale.' }"
echo.
pause
goto MENU

:DESTRUCT
cls
color 4F
echo ============================================================
echo   INITIATING SELF-DESTRUCT...
echo ============================================================
echo.
echo Sending stop signal to GitHub Actions...
echo stop > C:\Users\Public\stop_runner.txt
echo.
echo The server will disconnect in a few seconds.
timeout /t 5 >nul
goto EXIT

:EXIT
exit
