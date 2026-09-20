<#
.SYNOPSIS
    RDP Manager - Bootstrap (Phase 11.3 - GitOps Architecture & Secret Isolation)
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
    $Config = Get-Content$ConfigPath -Raw | ConvertFrom-Json

    $volumes = Get-PSDrive -PSProvider FileSystem \vert{} Where-Object {$_.Free -gt 0 -and $_.Root -match '^[A-Z]:\\$' }$bestDrive = $volumes \vert{} Sort-Object Free -Descending \vert{} Select-Object -First 1$workspacePath = Join-Path $bestDrive.Root $Config.storage.workspaceRootName
    $statePath = Join-Path $workspacePath$Config.storage.stateFolderName
    $downloadsPath = Join-Path $workspacePath$Config.storage.downloadsFolderName
    $systemPath = Join-Path$workspacePath "System"
    
    $null = New-Item -ItemType Directory -Force -Path$statePath
    $null = New-Item -ItemType Directory -Force -Path$downloadsPath
    $null = New-Item -ItemType Directory -Force -Path$systemPath
    Write-Log "Workspace initialized at $workspacePath" "SUCCESS"

    # ====================================================================
    # GITOPS DEPLOYMENT: Injecting Repo Configs before CloudVault Merge
    # ====================================================================
    $repoSystemPath = Join-Path$PSScriptRoot "..\system"
    if (Test-Path $repoSystemPath) {
        Write-Log "GitOps: Deploying configuration files from GitHub Repository..." "INFO"
        Copy-Item -Path "$repoSystemPath\*" -Destination $systemPath -Recurse -Force
        Write-Log "Local system scripts deployed to Workspace." "SUCCESS"
    } else {
        Write-Log "GitOps: No 'system' folder found in GitHub repo. Relying on CloudVault." "WARN"
    }
    # ====================================================================

    $publicConf = "C:\Users\Public\rclone.conf"

    if ($env:RCLONE_CONFIG_DATA) {
        Write-Log "Installing rclone & setting OS-Native Configs..." "INFO"
        Set-Content -Path $publicConf -Value $env:RCLONE_CONFIG_DATA$defaultRcloneDir = "C:\Users\Default\AppData\Roaming\rclone"
        if (-not (Test-Path $defaultRcloneDir)) { New-Item -ItemType Directory -Path$defaultRcloneDir -Force | Out-Null }
        Set-Content -Path "$defaultRcloneDir\rclone.conf" -Value $env:RCLONE_CONFIG_DATA

        $rcloneZip = "$env:TEMP\rclone.zip"
        Invoke-WebRequest -Uri "https://downloads.rclone.org/v1.65.2/rclone-v1.65.2-windows-amd64.zip" -OutFile $rcloneZip
        Expand-Archive -Path $rcloneZip -DestinationPath "$env:TEMP\rclone_ext" -Force
        $rcloneExe = (Get-ChildItem -Path "$env:TEMP\rclone_ext" -Filter "rclone.exe" -Recurse).FullName
        Copy-Item $rcloneExe -Destination "$workspacePath\rclone.exe" -Force
        Copy-Item $rcloneExe -Destination "C:\Windows\rclone.exe" -Force
        
        Write-Log "Syncing Cloud Workspace -> Local Disk..." "INFO"
        $cloudTarget = "$($Config.relay.cloudDriveName):$($Config.storage.workspaceRootName)"
        
        & "$workspacePath\rclone.exe" mkdir $cloudTarget --config$publicConf
        
        Write-Log "Downloading workspace & System Vault from Google Drive..." "WARN"
        $rcloneArgs = @("copy", $cloudTarget, $workspacePath, "--config", $publicConf, "--transfers", "8", "--stats", "10s", "--stats-one-line", "-v")
        & "$workspacePath\rclone.exe" @rcloneArgs
        
        Write-Log "Cloud Restore Complete." "SUCCESS"
        Write-Log "Installing WinFsp for Rclone Virtual Drive Mounting..." "INFO"
        choco install winfsp -y --no-progress | Out-Null
        
    } else {
        Write-Log "RCLONE_CONFIG_DATA not found. Fatal Error." "ERROR"
        exit 1
    }

    # ====================================================================
    # THE SECURE VAULT UNLOCK (secrets.json is explicitly read here)
    # ====================================================================
    $secretsFile = Join-Path$systemPath "secrets.json"
    if (Test-Path $secretsFile) {
        Write-Log "Unlocking CloudVault secrets.json..." "INFO"
        $vault = Get-Content$secretsFile -Raw | ConvertFrom-Json
        $ghEnv = "$env:GITHUB_ENV"

        foreach ($prop in$vault.PSObject.Properties) {
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

        "TELEGRAM_BOT_TOKEN=$($env:TELEGRAM_BOT_TOKEN)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TELEGRAM_CHAT_ID=$($env:TELEGRAM_CHAT_ID)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TELEGRAM_ADMIN_ID=$($env:TELEGRAM_ADMIN_ID)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TAILSCALE_AUTH_KEY=$($env:TAILSCALE_AUTH_KEY)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "RDP_USERNAME=$($env:RDP_USERNAME)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "RDP_PASSWORD=$($env:RDP_PASSWORD)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "GH_TOKEN=$($env:GH_TOKEN)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        Write-Log "Secrets loaded, masked, and injected successfully!" "SUCCESS"
    } else {
        Write-Log "CRITICAL: System\secrets.json not found! Ensure it remains in Google Drive." "ERROR"
        exit 1
    }

    # ====================================================================
    # POST-LOGIN INJECTION (Debloat, Software, and STATE RESTORATION)
    # ====================================================================
    Write-Log "Injecting Parallel Admin Setup & State Scripts..." "INFO"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 0 -ErrorAction SilentlyContinue

    $desktopPath = "C:\Users\Public\Desktop"
    if (-not (Test-Path $desktopPath)) { New-Item -ItemType Directory -Path $desktopPath -Force \vert{} Out-Null }$startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupPath)) { New-Item -ItemType Directory -Path$startupPath -Force | Out-Null }

    $debloatPs1 = "$desktopPath\01_GreatDebloat.ps1"
    $installPs1 = "$desktopPath\02_SoftwareInstaller.ps1"
    $restorePs1 = "$desktopPath\03_StateRestore.ps1"
    $startupVbs = "$startupPath\00_Init_RDP.vbs"

    # RED TERMINAL: The Great Debloat 
    $debloatContent = @'$Host.UI.RawUI.WindowTitle = "RDP INITIALIZATION: 1/3 - The Great Debloat"
$Host.UI.RawUI.BackgroundColor = "DarkRed"
Clear-Host
Write-Host "================================================================" -ForegroundColor White
Write-Host "   RECLAIMING C: DRIVE SPACE (ADMINISTRATOR)                    " -ForegroundColor White
Write-Host "================================================================`n" -ForegroundColor White

$softwareFile = "{WORKSPACE_PATH}\System\software.json"
if (Test-Path $softwareFile) {
    $swData = Get-Content $softwareFile -Raw | ConvertFrom-Json
    $totalCleaned = 0
    if ($swData.cleanup_paths) {
        foreach ($junk in $swData.cleanup_paths) {
            if (Test-Path $junk) {
                Write-Host " [X] Obliterating $junk..." -ForegroundColor Yellow
                Start-Process "cmd.exe" -ArgumentList "/c rmdir /s /q `"$junk`"" -Wait -WindowStyle Hidden
                $totalCleaned++
            }
        }
    }
    Write-Host "`n[+] Cleanup Complete! Removed $totalCleaned bloat directories." -ForegroundColor Green
}
Write-Host "`nTerminal closing and cleaning up in 5 seconds..." -ForegroundColor White
Start-Sleep -Seconds 5
Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Process -Id $PID
'@
    $debloatContent = $debloatContent -replace '\{WORKSPACE_PATH\}', $workspacePath
    Set-Content -Path $debloatPs1 -Value $debloatContent

    # BLUE TERMINAL: Software Installer
    $installContent = @'
$Host.UI.RawUI.WindowTitle = "RDP INITIALIZATION: 2/3 - Software Installer"
$Host.UI.RawUI.BackgroundColor = "DarkBlue"
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   DEPLOYING FUTURE-PROOF TECH STACK (ADMINISTRATOR)            " -ForegroundColor White
Write-Host "================================================================`n" -ForegroundColor Cyan

$softwareFile = "{WORKSPACE_PATH}\System\software.json"
if (Test-Path $softwareFile) {$swData = Get-Content $softwareFile -Raw \vert{} ConvertFrom-Json$toInstall = @()
    if ($swData.packages) {
        foreach ($pkg in$swData.packages) {
            if ($pkg.enabled -eq$true) { $toInstall +=$pkg.id }
        }
    }
    
    if ($toInstall.Count -gt 0) {
        $pkgString =$toInstall -join " "
        Write-Host "[+] Installing: $pkgString`n" -ForegroundColor Cyan
        Start-Process -FilePath "choco" -ArgumentList "install $pkgString -y --confirm --force" -Wait -NoNewWindow
        Write-Host "`n[+] Software stack deployed!" -ForegroundColor Green
    }
}
Write-Host "`nTerminal closing and cleaning up in 5 seconds..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Process -Id $PID
'@
    $installContent = $installContent -replace '\{WORKSPACE_PATH\}', $workspacePath
    Set-Content -Path $installPs1 -Value $installContent

    # GREEN TERMINAL: State & AppData Restoration
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

if (-not (Test-Path $appDataState)) { New-Item -ItemType Directory -Path$appDataState -Force | Out-Null }
if (-not (Test-Path $regState)) { New-Item -ItemType Directory -Path$regState -Force | Out-Null }

if (Test-Path $softwareFile) {
    $swData = Get-Content$softwareFile -Raw | ConvertFrom-Json
    
    Write-Host "[1/2] Processing AppData Directory Junctions..." -ForegroundColor Yellow
    if ($swData.state_management.appdata_folders) {
        foreach ($folder in$swData.state_management.appdata_folders) {
            $targetPath = Join-Path$appDataState $folder$linkPath = Join-Path "$env:USERPROFILE\AppData" $folder
            
            if (-not (Test-Path $targetPath)) { New-Item -ItemType Directory -Path$targetPath -Force | Out-Null }
            
            if (Test-Path $linkPath) {
                $item = Get-Item$linkPath -Force
                if ($item.LinkType -ne "Junction") {
                    Write-Host "      [!] Merging existing data: $folder" -ForegroundColor Cyan
                    Copy-Item -Path "$linkPath\*" -Destination $targetPath -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path $linkPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            
            if (-not (Test-Path $linkPath)) {
                Write-Host "      [+] Linking $folder -> CloudVault" -ForegroundColor Green
                New-Item -ItemType Junction -Path $linkPath -Target$targetPath -Force | Out-Null
            } else {
                Write-Host "      [v] Verified: $folder" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "`n[2/2] Restoring Registry Hives..." -ForegroundColor Yellow
    if ($swData.state_management.registry_keys) {
        foreach ($key in $swData.state_management.registry_keys) {
            $safeName = $key -replace '[\\/]', '_'
            $regFile = "$regState\$safeName.reg"
            if (Test-Path $regFile) {
                Write-Host "      [+] Importing: $key" -ForegroundColor Green
                Start-Process "reg.exe" -ArgumentList "import `"$regFile`"" -Wait -WindowStyle Hidden
            } else {
                Write-Host "      [-] No backup found for: $key" -ForegroundColor DarkGray
            }
        }
    }
}
Write-Host "`nTerminal closing and cleaning up in 5 seconds..." -ForegroundColor White
Start-Sleep -Seconds 5
Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Process -Id $PID
'@
    $restoreContent = $restoreContent -replace '\{WORKSPACE_PATH\}',$workspacePath
    Set-Content -Path $restorePs1 -Value$restoreContent

    # Master VBS Launcher
    $vbsContent = "Set UAC = CreateObject(""Shell.Application"")`r`n"
    $vbsContent += "UAC.ShellExecute ""powershell.exe"", ""-NoProfile -ExecutionPolicy Bypass -File "" & Chr(34) & ""$debloatPs1"" & Chr(34), """", ""runas"", 1`r`n"
    $vbsContent += "UAC.ShellExecute ""powershell.exe"", ""-NoProfile -ExecutionPolicy Bypass -File "" & Chr(34) & ""$installPs1"" & Chr(34), """", ""runas"", 1`r`n"
    $vbsContent += "UAC.ShellExecute ""powershell.exe"", ""-NoProfile -ExecutionPolicy Bypass -File "" & Chr(34) & ""$restorePs1"" & Chr(34), """", ""runas"", 1`r`n"
    $vbsContent += "Set objFSO = CreateObject(""Scripting.FileSystemObject"")`r`n"
    $vbsContent += "strScript = Wscript.ScriptFullName`r`n"
    $vbsContent += "objFSO.DeleteFile(strScript)`r`n"
    Set-Content -Path $startupVbs -Value$vbsContent

    # ====================================================================
    # NATIVE DESKTOP MOUNT SCRIPTS (Pulled from GitHub repo copy)
    # ====================================================================
    $mountVbs = Join-Path$systemPath "mount.vbs"
    $unmountVbs = Join-Path$systemPath "unmount.vbs"
    if (Test-Path $mountVbs) {
        Copy-Item -Path $mountVbs -Destination "$desktopPath\mount.vbs" -Force
        $autoMount = "$startupPath\mount.vbs"
        Copy-Item -Path $mountVbs -Destination$autoMount -Force
    }
    if (Test-Path $unmountVbs) { Copy-Item -Path $unmountVbs -Destination "$desktopPath\unmount.vbs" -Force }

    # RDP Initialization
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0
    if ((Get-Service $Config.rdp.serviceName).Status -ne 'Running') { Start-Service$Config.rdp.serviceName }
    if ($env:RDP_USERNAME -and$env:RDP_PASSWORD) {
        $secPass = ConvertTo-SecureString$env:RDP_PASSWORD -AsPlainText -Force
        if (-not (Get-LocalUser -Name $env:RDP_USERNAME -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name $env:RDP_USERNAME -Password$secPass -AccountNeverExpires -PasswordNeverExpires | Out-Null
            Add-LocalGroupMember -Group "Administrators" -Member $env:RDP_USERNAME
            Add-LocalGroupMember -Group "Remote Desktop Users" -Member $env:RDP_USERNAME
        }
    }

    # ====================================================================
    # REGISTRY EXPORTER SCHEDULED TASK
    # ====================================================================
    Write-Log "Configuring Remote Registry Exporter Task..." "INFO"
    $exporterPs1 = Join-Path$systemPath "StateExporter.ps1"
    $exporterContent = @'$softwareFile = "{WORKSPACE_PATH}\System\software.json"
$regState = "{WORKSPACE_PATH}\State\Registry"
if (-not (Test-Path $regState)) { New-Item -ItemType Directory -Path$regState -Force | Out-Null }
if (Test-Path $softwareFile) {
    $swData = Get-Content$softwareFile -Raw | ConvertFrom-Json
    if ($swData.state_management.registry_keys) {
        foreach ($key in$swData.state_management.registry_keys) {
            $safeName =$key -replace '[\\/]', '_'
            $regFile = "$regState\$safeName.reg"
            Start-Process "reg.exe" -ArgumentList "export `"$key`" `"$regFile`" /y" -Wait -WindowStyle Hidden
        }
    }
}
'@
    $exporterContent = $exporterContent -replace '\{WORKSPACE_PATH\}',$workspacePath
    Set-Content -Path $exporterPs1 -Value $exporterContent$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$exporterPs1`""
    $principal = New-ScheduledTaskPrincipal -UserId $env:RDP_USERNAME -LogonType Interactive -RunLevel Highest$task = New-ScheduledTask -Action $action -Principal$principal
    Register-ScheduledTask -TaskName "RDPStateExport" -InputObject $task -Force | Out-Null

    # Tailscale Setup
    if ($env:TAILSCALE_AUTH_KEY) {
        choco install tailscale -y --no-progress | Out-Null
        $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
        if (Test-Path $tsPath) {
            & $tsPath up --authkey=$env:TAILSCALE_AUTH_KEY --hostname="RDP-Worker-$env:GITHUB_RUN_ID" --reset
            $tsIp = (& $tsPath ip -4 2>$null).Trim()
            Write-Log "Tailscale connected successfully!" "SUCCESS"
        }
    }

    # aria2 Initialization
    $aria2Path = Join-Path$workspacePath "aria2"
    if (-not (Test-Path $aria2Path)) {
        New-Item -ItemType Directory -Path $aria2Path | Out-Null
        $aria2Zip = "$env:TEMP\aria2.zip"
        Invoke-WebRequest -Uri "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip" -OutFile $aria2Zip
        Expand-Archive -Path $aria2Zip -DestinationPath$aria2Path -Force
    }
    
    $sessionFile = Join-Path$statePath "aria2.session"
    if (-not (Test-Path $sessionFile)) { New-Item -ItemType File -Path$sessionFile -Force | Out-Null }

    $aria2Exe = (Get-ChildItem -Path$aria2Path -Filter "aria2c.exe" -Recurse).FullName
    $ariaArgs = "--enable-rpc --rpc-listen-all=false --rpc-listen-port=$($Config.aria2.rpcPort) --dir=`"$downloadsPath`" --max-concurrent-downloads=$($Config.aria2.maxConcurrent) --split=$($Config.aria2.split) --continue=true --save-session=`"$sessionFile`" --input-file=`"$sessionFile`""
    Start-Process -FilePath $aria2Exe -ArgumentList$ariaArgs -WindowStyle Hidden

    "WORKSPACE_ROOT=$workspacePath" \vert{} Out-File -FilePath $env:GITHUB_ENV -Append
    Write-Log "Phase 11.3 Bootstrap Complete." "SUCCESS"
    
    $global:LASTEXITCODE = 0

} catch { Write-Log $_.Exception.Message "ERROR"; exit 1 }
