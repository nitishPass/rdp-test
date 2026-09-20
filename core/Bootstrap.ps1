<#
.SYNOPSIS
    RDP Manager - Bootstrap (Phase 11.5 - UI Parser Bug Fix)
#>

[CmdletBinding()]
param ([string]$ConfigPath = "$PSScriptRoot\..\config\settings.json")
$ErrorActionPreference = 'Continue'

function Write-Log {
    param ([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'INFO'{'Cyan'} 'WARN'{'Yellow'} 'ERROR'{'Red'} 'SUCCESS'{'Green'} }
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] [$Level] $Message" -ForegroundColor $color
}

try {
    $rawConfig = Get-Content -Path$ConfigPath -Raw
    $Config = ConvertFrom-Json -InputObject$rawConfig

    $volumes = Get-PSDrive -PSProvider FileSystem$bestDrive = $null$maxFree = 0
    for ($i = 0; $i -lt$volumes.Count; $i++) {$v = $volumes[$i]
        if ($v.Free -gt $maxFree -and$v.Root -match '^[A-Z]:\\$') {
            $maxFree =$v.Free
            $bestDrive =$v
        }
    }
    
    $workspacePath = Join-Path $bestDrive.Root $Config.storage.workspaceRootName
    $statePath = Join-Path $workspacePath$Config.storage.stateFolderName
    $downloadsPath = Join-Path $workspacePath$Config.storage.downloadsFolderName
    $systemPath = Join-Path$workspacePath "System"
    
    $null = New-Item -ItemType Directory -Force -Path$statePath
    $null = New-Item -ItemType Directory -Force -Path$downloadsPath
    $null = New-Item -ItemType Directory -Force -Path$systemPath
    Write-Log "Workspace initialized at $workspacePath" "SUCCESS"

    $repoSystemPath = Join-Path$PSScriptRoot "..\system"
    if (Test-Path $repoSystemPath) {
        Write-Log "GitOps: Deploying configuration files from GitHub Repository..." "INFO"
        Copy-Item -Path "$repoSystemPath\*" -Destination $systemPath -Recurse -Force
    }

    $publicConf = "C:\Users\Public\rclone.conf"

    if ($env:RCLONE_CONFIG_DATA) {
        Set-Content -Path $publicConf -Value $env:RCLONE_CONFIG_DATA$defaultRcloneDir = "C:\Users\Default\AppData\Roaming\rclone"
        if (-not (Test-Path $defaultRcloneDir)) { 
            $null = New-Item -ItemType Directory -Path$defaultRcloneDir -Force 
        }
        Set-Content -Path "$defaultRcloneDir\rclone.conf" -Value $env:RCLONE_CONFIG_DATA

        $rcloneZip = "$env:TEMP\rclone.zip"
        Invoke-WebRequest -Uri "https://downloads.rclone.org/v1.65.2/rclone-v1.65.2-windows-amd64.zip" -OutFile $rcloneZip
        Expand-Archive -Path $rcloneZip -DestinationPath "$env:TEMP\rclone_ext" -Force
        $rcloneExe = (Get-ChildItem -Path "$env:TEMP\rclone_ext" -Filter "rclone.exe" -Recurse).FullName
        Copy-Item $rcloneExe -Destination "$workspacePath\rclone.exe" -Force
        Copy-Item $rcloneExe -Destination "C:\Windows\rclone.exe" -Force
        
        $cloudTarget = "$($Config.relay.cloudDriveName):$($Config.storage.workspaceRootName)"
        & "$workspacePath\rclone.exe" mkdir $cloudTarget --config$publicConf
        
        $rcloneArgs = @("copy", $cloudTarget, $workspacePath, "--config", $publicConf, "--transfers", "8", "--stats", "10s", "--stats-one-line", "-v")
        & "$workspacePath\rclone.exe" @rcloneArgs
        
        choco install winfsp -y --no-progress
    } else {
        Write-Log "RCLONE_CONFIG_DATA not found. Fatal Error." "ERROR"
        exit 1
    }

    $secretsFile = Join-Path$systemPath "secrets.json"
    if (Test-Path $secretsFile) {
        $rawVault = Get-Content -Path$secretsFile -Raw
        $vault = ConvertFrom-Json -InputObject$rawVault
        $ghEnv = "$env:GITHUB_ENV"

        $vaultProps =$vault.PSObject.Properties
        for ($i = 0; $i -lt$vaultProps.Count; $i++) {$prop = $vaultProps[$i]
            $val = [string]$prop.Value
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                $cleanVal =$val.Trim()
                Write-Host "::add-mask::$cleanVal"
            }
        }

        $env:TELEGRAM_BOT_TOKEN =$vault.telegram_bot_token.Trim()
        $env:TELEGRAM_CHAT_ID   =$vault.telegram_chat_id.Trim()
        $env:TELEGRAM_ADMIN_ID  =$vault.telegram_admin_id.Trim()
        $env:TAILSCALE_AUTH_KEY =$vault.tailscale_auth_key.Trim()
        $env:RDP_USERNAME       =$vault.rdp_username.Trim()
        $env:RDP_PASSWORD       =$vault.rdp_password.Trim()
        $env:GH_TOKEN           =$vault.gh_token.Trim()

        Add-Content -Path $ghEnv -Value "TELEGRAM_BOT_TOKEN=$($env:TELEGRAM_BOT_TOKEN)"
        Add-Content -Path $ghEnv -Value "TELEGRAM_CHAT_ID=$($env:TELEGRAM_CHAT_ID)"
        Add-Content -Path $ghEnv -Value "TELEGRAM_ADMIN_ID=$($env:TELEGRAM_ADMIN_ID)"
        Add-Content -Path $ghEnv -Value "TAILSCALE_AUTH_KEY=$($env:TAILSCALE_AUTH_KEY)"
        Add-Content -Path $ghEnv -Value "RDP_USERNAME=$($env:RDP_USERNAME)"
        Add-Content -Path $ghEnv -Value "RDP_PASSWORD=$($env:RDP_PASSWORD)"
        Add-Content -Path $ghEnv -Value "GH_TOKEN=$($env:GH_TOKEN)"
    } else {
        Write-Log "CRITICAL: System\secrets.json not found! Ensure it remains in Google Drive." "ERROR"
        exit 1
    }

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 0 -ErrorAction SilentlyContinue

    $desktopPath = "C:\Users\Public\Desktop"
    if (-not (Test-Path $desktopPath)) {$null = New-Item -ItemType Directory -Path $desktopPath -Force }$startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupPath)) { $null = New-Item -ItemType Directory -Path$startupPath -Force }

    $debloatPs1 = "$desktopPath\01_GreatDebloat.ps1"
    $installPs1 = "$desktopPath\02_SoftwareInstaller.ps1"
    $restorePs1 = "$desktopPath\03_StateRestore.ps1"
    $startupVbs = "$startupPath\00_Init_RDP.vbs"

    # RED TERMINAL
    $debloatContent = @'$Host.UI.RawUI.WindowTitle = "RDP INITIALIZATION: 1/3 - The Great Debloat"
$Host.UI.RawUI.BackgroundColor = "DarkRed"
Clear-Host
Write-Host "================================================================" -ForegroundColor White
Write-Host "   RECLAIMING C: DRIVE SPACE (ADMINISTRATOR)                    " -ForegroundColor White
Write-Host "================================================================`n" -ForegroundColor White

$softwareFile = "{WORKSPACE_PATH}\System\software.json"
if (Test-Path $softwareFile) {
    $rawSw = Get-Content -Path $softwareFile -Raw
    $swData = ConvertFrom-Json -InputObject $rawSw
    $totalCleaned = 0
    $paths = $swData.cleanup_paths
    if ($paths) {
        for ($i = 0; $i -lt $paths.Count; $i++) {
            $junk = $paths[$i]
            if (Test-Path $junk) {
                Write-Host " [X] Obliterating $junk..." -ForegroundColor Yellow
                $null = Start-Process "cmd.exe" -ArgumentList "/c rmdir /s /q `"$junk`"" -Wait -WindowStyle Hidden
                $totalCleaned++
            }
        }
    }
    Write-Host "`n[+] Cleanup Complete! Removed $totalCleaned bloat directories." -ForegroundColor Green
}
Write-Host "`nTerminal closing and cleaning up in 5 seconds..." -ForegroundColor White
Start-Sleep -Seconds 5
$null = Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Process -Id $PID
'@
    $debloatContent = $debloatContent -replace '\{WORKSPACE_PATH\}', $workspacePath
    Set-Content -Path $debloatPs1 -Value $debloatContent

    # BLUE TERMINAL
    $installContent = @'
$Host.UI.RawUI.WindowTitle = "RDP INITIALIZATION: 2/3 - Software Installer"
$Host.UI.RawUI.BackgroundColor = "DarkBlue"
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   DEPLOYING FUTURE-PROOF TECH STACK (ADMINISTRATOR)            " -ForegroundColor White
Write-Host "================================================================`n" -ForegroundColor Cyan

$softwareFile = "{WORKSPACE_PATH}\System\software.json"
if (Test-Path $softwareFile) {$rawSw = Get-Content -Path $softwareFile -Raw$swData = ConvertFrom-Json -InputObject $rawSw$toInstall = @()
    $pkgs =$swData.packages
    if ($pkgs) {
        for ($i = 0; $i -lt$pkgs.Count; $i++) {$pkg = $pkgs[$i]
            if ($pkg.enabled -eq$true) { $toInstall +=$pkg.id }
        }
    }
    
    if ($toInstall.Count -gt 0) {
        $pkgString =$toInstall -join " "
        Write-Host "[+] Installing: $pkgString`n" -ForegroundColor Cyan
        $null = Start-Process -FilePath "choco" -ArgumentList "install $pkgString -y --confirm --force" -Wait -NoNewWindow
        Write-Host "`n[+] Software stack deployed!" -ForegroundColor Green
    }
}
Write-Host "`nTerminal closing and cleaning up in 5 seconds..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
$null = Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Process -Id $PID
'@
    $installContent = $installContent -replace '\{WORKSPACE_PATH\}', $workspacePath
    Set-Content -Path $installPs1 -Value $installContent

    # GREEN TERMINAL
    $restoreContent = @'
$Host.UI.RawUI.WindowTitle = "RDP INITIALIZATION: 3/3 - State Restoration"
$Host.UI.RawUI.BackgroundColor = "DarkGreen"
Clear-Host
Write-Host "================================================================" -ForegroundColor White
Write-Host "   RESTORING SOFTWARE STATE & APPDATA JUNCTIONS                 " -ForegroundColor White
Write-Host "================================================================`n" -ForegroundColor White

$softwareFile = "{WORKSPACE_PATH}\System\software.json"
$stateDir = "{WORKSPACE_PATH}\State"
$appDataState = "$stateDir\AppData"
$regState = "$stateDir\Registry"

if (-not (Test-Path $appDataState)) { $null = New-Item -ItemType Directory -Path$appDataState -Force }
if (-not (Test-Path $regState)) { $null = New-Item -ItemType Directory -Path$regState -Force }

if (Test-Path $softwareFile) {
    $rawSw = Get-Content -Path$softwareFile -Raw
    $swData = ConvertFrom-Json -InputObject$rawSw
    
    Write-Host "[1/2] Processing AppData Directory Junctions..." -ForegroundColor Yellow
    $folders =$swData.state_management.appdata_folders
    if ($folders) {
        for ($i = 0; $i -lt$folders.Count; $i++) {$folder = $folders[$i]
            $targetPath = Join-Path$appDataState $folder$linkPath = Join-Path "$env:USERPROFILE\AppData" $folder
            
            if (-not (Test-Path $targetPath)) { $null = New-Item -ItemType Directory -Path$targetPath -Force }
            
            if (Test-Path $linkPath) {
                $item = Get-Item$linkPath -Force
                if ($item.LinkType -ne "Junction") {
                    Write-Host "      [!] Merging existing data: $folder" -ForegroundColor Cyan
                    $null = Copy-Item -Path "$linkPath\*" -Destination $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                    $null = Remove-Item -Path$linkPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            
            if (-not (Test-Path $linkPath)) {
                Write-Host "      [+] Linking $folder -> CloudVault" -ForegroundColor Green
                $null = New-Item -ItemType Junction -Path $linkPath -Target$targetPath -Force
            } else {
                Write-Host "      [v] Verified: $folder" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "`n[2/2] Restoring Registry Hives..." -ForegroundColor Yellow
    $keys = $swData.state_management.registry_keys
    if ($keys) {
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $key = $keys[$i]
            $safeName = $key -replace '[\\/]', '_'
            $regFile = "$regState\$safeName.reg"
            if (Test-Path $regFile) {
                Write-Host "      [+] Importing: $key" -ForegroundColor Green
                $null = Start-Process "reg.exe" -ArgumentList "import `"$regFile`"" -Wait -WindowStyle Hidden
            } else {
                Write-Host "      [-] No backup found for: $key" -ForegroundColor DarkGray
            }
        }
    }
}
Write-Host "`nTerminal closing and cleaning up in 5 seconds..." -ForegroundColor White
Start-Sleep -Seconds 5
$null = Remove-Item -Path$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Process -Id $PID
'@
    $restoreContent = $restoreContent -replace '\{WORKSPACE_PATH\}',$workspacePath
    Set-Content -Path $restorePs1 -Value$restoreContent

    $vbsContent = "Set UAC = CreateObject(""Shell.Application"")`r`n"
    $vbsContent += "UAC.ShellExecute ""powershell.exe"", ""-NoProfile -ExecutionPolicy Bypass -File "" & Chr(34) & ""$debloatPs1"" & Chr(34), """", ""runas"", 1`r`n"
    $vbsContent += "UAC.ShellExecute ""powershell.exe"", ""-NoProfile -ExecutionPolicy Bypass -File "" & Chr(34) & ""$installPs1"" & Chr(34), """", ""runas"", 1`r`n"
    $vbsContent += "UAC.ShellExecute ""powershell.exe"", ""-NoProfile -ExecutionPolicy Bypass -File "" & Chr(34) & ""$restorePs1"" & Chr(34), """", ""runas"", 1`r`n"
    $vbsContent += "Set objFSO = CreateObject(""Scripting.FileSystemObject"")`r`n"
    $vbsContent += "strScript = Wscript.ScriptFullName`r`n"
    $vbsContent += "objFSO.DeleteFile(strScript)`r`n"
    Set-Content -Path $startupVbs -Value$vbsContent

    $mountVbs = Join-Path$systemPath "mount.vbs"
    $unmountVbs = Join-Path$systemPath "unmount.vbs"
    if (Test-Path $mountVbs) {
        Copy-Item -Path $mountVbs -Destination "$desktopPath\mount.vbs" -Force
        $autoMount = "$startupPath\mount.vbs"
        Copy-Item -Path $mountVbs -Destination$autoMount -Force
    }
    if (Test-Path $unmountVbs) { Copy-Item -Path $unmountVbs -Destination "$desktopPath\unmount.vbs" -Force }

    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0
    if ((Get-Service $Config.rdp.serviceName).Status -ne 'Running') { Start-Service$Config.rdp.serviceName }
    if ($env:RDP_USERNAME -and$env:RDP_PASSWORD) {
        $secPass = ConvertTo-SecureString$env:RDP_PASSWORD -AsPlainText -Force
        if (-not (Get-LocalUser -Name $env:RDP_USERNAME -ErrorAction SilentlyContinue)) {$null = New-LocalUser -Name $env:RDP_USERNAME -Password$secPass -AccountNeverExpires -PasswordNeverExpires
            Add-LocalGroupMember -Group "Administrators" -Member $env:RDP_USERNAME
            Add-LocalGroupMember -Group "Remote Desktop Users" -Member $env:RDP_USERNAME
        }
    }

    Write-Log "Configuring Remote Registry Exporter Task..." "INFO"
    $exporterPs1 = Join-Path$systemPath "StateExporter.ps1"
    $exporterContent = @'$softwareFile = "{WORKSPACE_PATH}\System\software.json"
$regState = "{WORKSPACE_PATH}\State\Registry"
if (-not (Test-Path $regState)) { $null = New-Item -ItemType Directory -Path$regState -Force }
if (Test-Path $softwareFile) {
    $rawSw = Get-Content -Path$softwareFile -Raw
    $swData = ConvertFrom-Json -InputObject$rawSw
    $keys =$swData.state_management.registry_keys
    if ($keys) {
        for ($i = 0; $i -lt$keys.Count; $i++) {$key = $keys[$i]
            $safeName =$key -replace '[\\/]', '_'
            $regFile = "$regState\$safeName.reg"
            $null = Start-Process "reg.exe" -ArgumentList "export `"$key`" `"$regFile`" /y" -Wait -WindowStyle Hidden
        }
    }
}
'@
    $exporterContent = $exporterContent -replace '\{WORKSPACE_PATH\}',$workspacePath
    Set-Content -Path $exporterPs1 -Value $exporterContent$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$exporterPs1`""
    $principal = New-ScheduledTaskPrincipal -UserId $env:RDP_USERNAME -LogonType Interactive -RunLevel Highest$task = New-ScheduledTask -Action $action -Principal$principal
    $null = Register-ScheduledTask -TaskName "RDPStateExport" -InputObject $task -Force

    if ($env:TAILSCALE_AUTH_KEY) {
        choco install tailscale -y --no-progress
        $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
        if (Test-Path $tsPath) {
            & $tsPath up --authkey=$env:TAILSCALE_AUTH_KEY --hostname="RDP-Worker-$env:GITHUB_RUN_ID" --reset
        }
    }

    $aria2Path = Join-Path$workspacePath "aria2"
    if (-not (Test-Path $aria2Path)) {
        $null = New-Item -ItemType Directory -Path$aria2Path
        $aria2Zip = "$env:TEMP\aria2.zip"
        Invoke-WebRequest -Uri "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip" -OutFile $aria2Zip
        Expand-Archive -Path $aria2Zip -DestinationPath$aria2Path -Force
    }
    
    $sessionFile = Join-Path$statePath "aria2.session"
    if (-not (Test-Path $sessionFile)) { $null = New-Item -ItemType File -Path$sessionFile -Force }

    $aria2Exe = (Get-ChildItem -Path$aria2Path -Filter "aria2c.exe" -Recurse).FullName
    $ariaArgs = "--enable-rpc --rpc-listen-all=false --rpc-listen-port=$($Config.aria2.rpcPort) --dir=`"$downloadsPath`" --max-concurrent-downloads=$($Config.aria2.maxConcurrent) --split=$($Config.aria2.split) --continue=true --save-session=`"$sessionFile`" --input-file=`"$sessionFile`""
    $null = Start-Process -FilePath $aria2Exe -ArgumentList$ariaArgs -WindowStyle Hidden

    "WORKSPACE_ROOT=$workspacePath" \vert{} Out-File -FilePath $env:GITHUB_ENV -Append
    Write-Log "Phase 11.5 Bootstrap Complete." "SUCCESS"
    
    $global:LASTEXITCODE = 0

} catch { Write-Log $_.Exception.Message "ERROR"; exit 1 }
