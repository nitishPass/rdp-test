<#
.SYNOPSIS
    RDP Manager - Bootstrap (Phase 11.8 - ZERO Foreach Loops / Absolute Stability)
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

    $volumes = Get-PSDrive -PSProvider FileSystem \vert{} Where-Object {$_.Free -gt 0 -and $_.Root -match '^[A-Z]:\\$' }$bestDrive = $volumes \vert{} Sort-Object Free -Descending \vert{} Select-Object -First 1$workspacePath = Join-Path $bestDrive.Root $Config.storage.workspaceRootName
    $statePath = Join-Path $workspacePath$Config.storage.stateFolderName
    $downloadsPath = Join-Path $workspacePath$Config.storage.downloadsFolderName
    
    $null = New-Item -ItemType Directory -Force -Path$statePath
    $null = New-Item -ItemType Directory -Force -Path$downloadsPath
    Write-Log "Workspace initialized at $workspacePath" "SUCCESS"

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
    # THE SECURE VAULT UNLOCK (FOREACH LOOP REMOVED ENTIRELY)
    # ====================================================================
    $secretsFile = Join-Path$workspacePath "System\secrets.json"
    if (Test-Path $secretsFile) {
        Write-Log "Unlocking CloudVault secrets.json..." "INFO"
        $rawVault = Get-Content -Path$secretsFile -Raw
        $vault = ConvertFrom-Json -InputObject$rawVault
        $ghEnv = "$env:GITHUB_ENV"

        # REWRITTEN TO A CLASSIC FOR LOOP (NO 'in' KEYWORD)
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

        "TELEGRAM_BOT_TOKEN=$($env:TELEGRAM_BOT_TOKEN)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TELEGRAM_CHAT_ID=$($env:TELEGRAM_CHAT_ID)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TELEGRAM_ADMIN_ID=$($env:TELEGRAM_ADMIN_ID)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TAILSCALE_AUTH_KEY=$($env:TAILSCALE_AUTH_KEY)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "RDP_USERNAME=$($env:RDP_USERNAME)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "RDP_PASSWORD=$($env:RDP_PASSWORD)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        "GH_TOKEN=$($env:GH_TOKEN)" \vert{} Out-File -FilePath $ghEnv -Append -Encoding utf8
        Write-Log "Secrets loaded, masked, and injected successfully!" "SUCCESS"
    } else {
        Write-Log "CRITICAL: System\secrets.json not found in Google Drive!" "ERROR"
        exit 1
    }

    # ====================================================================
    # POST-LOGIN INJECTION (Parser-Proof Line Generation - NO FOREACH)
    # ====================================================================
    Write-Log "Injecting Parallel Admin Setup Scripts..." "INFO"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 0 -ErrorAction SilentlyContinue

    $desktopPath = "C:\Users\Public\Desktop"
    if (-not (Test-Path $desktopPath)) { New-Item -ItemType Directory -Path $desktopPath -Force \vert{} Out-Null }$startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupPath)) { New-Item -ItemType Directory -Path$startupPath -Force | Out-Null }

    $debloatPs1 = "$desktopPath\01_GreatDebloat.ps1"
    $installPs1 = "$desktopPath\02_SoftwareInstaller.ps1"
    $restorePs1 = "$desktopPath\03_StateRestore.ps1"
    $startupVbs = "$startupPath\00_Init_RDP.vbs"

    # RED TERMINAL: The Great Debloat
    $dLines = @()$dLines += "`$Host.UI.RawUI.WindowTitle = `"RDP INITIALIZATION: 1/3 - The Great Debloat`""
    $dLines += "`$Host.UI.RawUI.BackgroundColor = `"DarkRed`""
    $dLines += "Clear-Host"
    $dLines += "Write-Host `"================================================================`" -ForegroundColor White"
    $dLines += "Write-Host `"   RECLAIMING C: DRIVE SPACE (ADMINISTRATOR)                    `" -ForegroundColor White"
    $dLines += "Write-Host `"================================================================``n`" -ForegroundColor White"
    $dLines += "`$softwareFile = `"$workspacePath\System\software.json`""
    $dLines += "if (Test-Path `$softwareFile) {"
    $dLines += "    `$rawSw = Get-Content -Path `$softwareFile -Raw"
    $dLines += "    `$swData = ConvertFrom-Json -InputObject `$rawSw"
    $dLines += "    `$totalCleaned = 0"
    $dLines += "    if (`$swData.cleanup_paths) {"
    $dLines += "        `$paths = `$swData.cleanup_paths"
    $dLines += "        for (`$i = 0; `$i -lt `$paths.Count; `$i++) {"
    $dLines += "            `$junk = `$paths[`$i]"
    $dLines += "            if (Test-Path `$junk) {"
    $dLines += "                Write-Host `" [X] Obliterating `$junk...`" -ForegroundColor Yellow"
    $dLines += "                Start-Process `"cmd.exe`" -ArgumentList `"/c rmdir /s /q `\`"`$junk`\`"`" -Wait -WindowStyle Hidden"
    $dLines += "                `$totalCleaned++"
    $dLines += "            }"
    $dLines += "        }"
    $dLines += "    }"
    $dLines += "    Write-Host `"``n[+] Cleanup Complete! Removed `$totalCleaned bloat directories.`" -ForegroundColor Green"
    $dLines += "}"
    $dLines += "Write-Host `"``nTerminal closing and cleaning up in 5 seconds...`" -ForegroundColor White"
    $dLines += "Start-Sleep -Seconds 5"
    $dLines += "Remove-Item -Path `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue"
    $dLines += "Stop-Process -Id `$PID"
    $dLines \vert{} Out-File -FilePath$debloatPs1 -Encoding utf8

    # BLUE TERMINAL: Software Installer
    $iLines = @()$iLines += "`$Host.UI.RawUI.WindowTitle = `"RDP INITIALIZATION: 2/3 - Software Installer`""
    $iLines += "`$Host.UI.RawUI.BackgroundColor = `"DarkBlue`""
    $iLines += "Clear-Host"
    $iLines += "Write-Host `"================================================================`" -ForegroundColor Cyan"
    $iLines += "Write-Host `"   DEPLOYING FUTURE-PROOF TECH STACK (ADMINISTRATOR)            `" -ForegroundColor White"
    $iLines += "Write-Host `"================================================================``n`" -ForegroundColor Cyan"
    $iLines += "`$softwareFile = `"$workspacePath\System\software.json`""
    $iLines += "if (Test-Path `$softwareFile) {"
    $iLines += "    `$rawSw = Get-Content -Path `$softwareFile -Raw"
    $iLines += "    `$swData = ConvertFrom-Json -InputObject `$rawSw"
    $iLines += "    `$toInstall = @()"
    $iLines += "    if (`$swData.packages) {"
    $iLines += "        `$pkgs = `$swData.packages"
    $iLines += "        for (`$i = 0; `$i -lt `$pkgs.Count; `$i++) {"
    $iLines += "            `$pkg = `$pkgs[`$i]"
    $iLines += "            if (`$pkg.enabled -eq `$true) { `$toInstall += `$pkg.id }"
    $iLines += "        }"
    $iLines += "    }"
    $iLines += "    if (`$toInstall.Count -gt 0) {"
    $iLines += "        `$pkgString = `$toInstall -join `" `""
    $iLines += "        Write-Host `"[+] Installing: `$pkgString``n`" -ForegroundColor Cyan"
    $iLines += "        Start-Process -FilePath `"choco`" -ArgumentList `"install `$pkgString -y --confirm --force`" -Wait -NoNewWindow"
    $iLines += "        Write-Host `"``n[+] Software stack deployed!`" -ForegroundColor Green"
    $iLines += "    }"
    $iLines += "}"
    $iLines += "Write-Host `"``nTerminal closing and cleaning up in 5 seconds...`" -ForegroundColor Cyan"
    $iLines += "Start-Sleep -Seconds 5"
    $iLines += "Remove-Item -Path `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue"
    $iLines += "Stop-Process -Id `$PID"
    $iLines \vert{} Out-File -FilePath$installPs1 -Encoding utf8

    # GREEN TERMINAL: State Restoration
    $rLines = @()$rLines += "`$Host.UI.RawUI.WindowTitle = `"RDP INITIALIZATION: 3/3 - State Restoration`""
    $rLines += "`$Host.UI.RawUI.BackgroundColor = `"DarkGreen`""
    $rLines += "Clear-Host"
    $rLines += "Write-Host `"================================================================`" -ForegroundColor White"
    $rLines += "Write-Host `"   RESTORING SOFTWARE STATE & APPDATA JUNCTIONS                 `" -ForegroundColor White"
    $rLines += "Write-Host `"================================================================``n`" -ForegroundColor White"
    $rLines += "`$softwareFile = `"$workspacePath\System\software.json`""
    $rLines += "`$appDataState = `"$workspacePath\State\AppData`""
    $rLines += "`$regState = `"$workspacePath\State\Registry`""
    $rLines += "if (-not (Test-Path `$appDataState)) { New-Item -ItemType Directory -Path `$appDataState -Force | Out-Null }"
    $rLines += "if (-not (Test-Path `$regState)) { New-Item -ItemType Directory -Path `$regState -Force | Out-Null }"
    $rLines += "if (Test-Path `$softwareFile) {"
    $rLines += "    `$rawSw = Get-Content -Path `$softwareFile -Raw"
    $rLines += "    `$swData = ConvertFrom-Json -InputObject `$rawSw"
    $rLines += "    Write-Host `"[1/2] Processing AppData Directory Junctions...`" -ForegroundColor Yellow"
    $rLines += "    if (`$swData.state_management.appdata_folders) {"
    $rLines += "        `$folders = `$swData.state_management.appdata_folders"
    $rLines += "        for (`$i = 0; `$i -lt `$folders.Count; `$i++) {"
    $rLines += "            `$folder = `$folders[`$i]"
    $rLines += "            `$targetPath = Join-Path `$appDataState `$folder"
    $rLines += "            `$linkPath = Join-Path `"`$env:USERPROFILE\AppData`" `$folder"
    $rLines += "            if (-not (Test-Path `$targetPath)) { New-Item -ItemType Directory -Path `$targetPath -Force | Out-Null }"
    $rLines += "            if (Test-Path `$linkPath) {"
    $rLines += "                `$item = Get-Item -Path `$linkPath -Force"
    $rLines += "                if (`$item.LinkType -ne `"Junction`") {"
    $rLines += "                    Write-Host `"      [!] Merging existing data: `$folder`" -ForegroundColor Cyan"
    $rLines += "                    Copy-Item -Path `"`$linkPath\*`" -Destination `$targetPath -Recurse -Force -ErrorAction SilentlyContinue"
    $rLines += "                    Remove-Item -Path `$linkPath -Recurse -Force -ErrorAction SilentlyContinue"
    $rLines += "                }"
    $rLines += "            }"
    $rLines += "            if (-not (Test-Path `$linkPath)) {"
    $rLines += "                Write-Host `"      [+] Linking `$folder -> CloudVault`" -ForegroundColor Green"
    $rLines += "                New-Item -ItemType Junction -Path `$linkPath -Target `$targetPath -Force | Out-Null"
    $rLines += "            } else {"
    $rLines += "                Write-Host `"      [v] Verified: `$folder`" -ForegroundColor DarkGray"
    $rLines += "            }"
    $rLines += "        }"
    $rLines += "    }"
    $rLines += "    Write-Host `"``n[2/2] Restoring Registry Hives...`" -ForegroundColor Yellow"
    $rLines += "    if (`$swData.state_management.registry_keys) {"
    $rLines += "        `$keys = `$swData.state_management.registry_keys"
    $rLines += "        for (`$i = 0; `$i -lt `$keys.Count; `$i++) {"
    $rLines += "            `$key = `$keys[`$i]"
    $rLines += "            `$safeName = `$key -replace '[\\/]', '_'"
    $rLines += "            `$regFile = `"`$regState\`$safeName.reg`""
    $rLines += "            if (Test-Path `$regFile) {"
    $rLines += "                Write-Host `"      [+] Importing: `$key`" -ForegroundColor Green"
    $rLines += "                Start-Process `"reg.exe`" -ArgumentList `"import `\`"`$regFile`\`"`" -Wait -WindowStyle Hidden"
    $rLines += "            } else {"
    $rLines += "                Write-Host `"      [-] No backup found for: `$key`" -ForegroundColor DarkGray"
    $rLines += "            }"
    $rLines += "        }"
    $rLines += "    }"
    $rLines += "}"
    $rLines += "Write-Host `"``nTerminal closing and cleaning up in 5 seconds...`" -ForegroundColor White"
    $rLines += "Start-Sleep -Seconds 5"
    $rLines += "Remove-Item -Path `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue"
    $rLines += "Stop-Process -Id `$PID"
    $rLines \vert{} Out-File -FilePath$restorePs1 -Encoding utf8

    # Master VBS Launcher (Safe String Quotes)
    $vLines = @()$vLines += 'Set UAC = CreateObject("Shell.Application")'
    $vLines += 'UAC.ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & "' + $debloatPs1 + '" & Chr(34), "", "runas", 1'
    $vLines += 'UAC.ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & "' + $installPs1 + '" & Chr(34), "", "runas", 1'
    $vLines += 'UAC.ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & "' + $restorePs1 + '" & Chr(34), "", "runas", 1'
    $vLines += 'Set objFSO = CreateObject("Scripting.FileSystemObject")'
    $vLines += 'strScript = Wscript.ScriptFullName'$vLines += 'objFSO.DeleteFile(strScript)'
    $vLines \vert{} Out-File -FilePath$startupVbs -Encoding ascii

    # ====================================================================
    # NATIVE DESKTOP MOUNT SCRIPTS
    # ====================================================================
    $mountVbs = Join-Path$workspacePath "System\mount.vbs"
    $unmountVbs = Join-Path$workspacePath "System\unmount.vbs"
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
    # REGISTRY EXPORTER SCHEDULED TASK (NO FOREACH)
    # ====================================================================
    Write-Log "Configuring Remote Registry Exporter Task..." "INFO"
    $exporterPs1 = Join-Path$workspacePath "System\StateExporter.ps1"
    
    $eLines = @()$eLines += "`$softwareFile = `"$workspacePath\System\software.json`""
    $eLines += "`$regState = `"$workspacePath\State\Registry`""
    $eLines += "if (-not (Test-Path `$regState)) { New-Item -ItemType Directory -Path `$regState -Force | Out-Null }"
    $eLines += "if (Test-Path `$softwareFile) {"
    $eLines += "    `$rawSw = Get-Content -Path `$softwareFile -Raw"
    $eLines += "    `$swData = ConvertFrom-Json -InputObject `$rawSw"
    $eLines += "    if (`$swData.state_management.registry_keys) {"
    $eLines += "        `$keys = `$swData.state_management.registry_keys"
    $eLines += "        for (`$i = 0; `$i -lt `$keys.Count; `$i++) {"
    $eLines += "            `$key = `$keys[`$i]"
    $eLines += "            `$safeName = `$key -replace '[\\/]', '_'"
    $eLines += "            `$regFile = `"`$regState\`$safeName.reg`""
    $eLines += "            Start-Process `"reg.exe`" -ArgumentList `"export `\`"`$key`\`" `\`"`$regFile`\`" /y`" -Wait -WindowStyle Hidden"
    $eLines += "        }"
    $eLines += "    }"
    $eLines += "}"
    $eLines | Out-File -FilePath $exporterPs1 -Encoding utf8$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$exporterPs1`""
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
    Write-Log "Phase 11.8 Bootstrap Complete." "SUCCESS"
    
    $global:LASTEXITCODE = 0

} catch { Write-Log $_.Exception.Message "ERROR"; exit 1 }
