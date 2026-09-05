<#
.SYNOPSIS
    RDP Manager - Bootstrap (Phase 9.3 - Auto-Mount & OS Native Integration)
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
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $volumes = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 -and $_.Root -match '^[A-Z]:\\$' }
    $bestDrive = $volumes | Sort-Object Free -Descending | Select-Object -First 1
    $workspacePath = Join-Path $bestDrive.Root $Config.storage.workspaceRootName
    $statePath = Join-Path $workspacePath $Config.storage.stateFolderName
    $downloadsPath = Join-Path $workspacePath $Config.storage.downloadsFolderName
    
    $null = New-Item -ItemType Directory -Force -Path $statePath
    $null = New-Item -ItemType Directory -Force -Path $downloadsPath
    Write-Log "Workspace initialized at $workspacePath" "SUCCESS"

    $publicConf = "C:\Users\Public\rclone.conf"

    if ($env:RCLONE_CONFIG_DATA) {
        Write-Log "Installing rclone & setting OS-Native Configs..." "INFO"
        Set-Content -Path $publicConf -Value $env:RCLONE_CONFIG_DATA
        
        $defaultRcloneDir = "C:\Users\Default\AppData\Roaming\rclone"
        if (-not (Test-Path $defaultRcloneDir)) { New-Item -ItemType Directory -Path $defaultRcloneDir -Force | Out-Null }
        Set-Content -Path "$defaultRcloneDir\rclone.conf" -Value $env:RCLONE_CONFIG_DATA

        $rcloneZip = "$env:TEMP\rclone.zip"
        Invoke-WebRequest -Uri "https://downloads.rclone.org/v1.65.2/rclone-v1.65.2-windows-amd64.zip" -OutFile $rcloneZip
        Expand-Archive -Path $rcloneZip -DestinationPath "$env:TEMP\rclone_ext" -Force
        $rcloneExe = (Get-ChildItem -Path "$env:TEMP\rclone_ext" -Filter "rclone.exe" -Recurse).FullName
        Copy-Item $rcloneExe -Destination "$workspacePath\rclone.exe" -Force
        Copy-Item $rcloneExe -Destination "C:\Windows\rclone.exe" -Force
        
        Write-Log "Syncing Cloud Workspace -> Local Disk..." "INFO"
        $cloudTarget = "$($Config.relay.cloudDriveName):$($Config.storage.workspaceRootName)"
        
        & "$workspacePath\rclone.exe" mkdir $cloudTarget --config $publicConf
        
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
    # THE SECURE VAULT UNLOCK
    # ====================================================================
    $secretsFile = Join-Path $workspacePath "System\secrets.json"
    if (Test-Path $secretsFile) {
        Write-Log "Unlocking CloudVault secrets.json..." "INFO"
        $vault = Get-Content $secretsFile -Raw | ConvertFrom-Json
        $ghEnv = "$env:GITHUB_ENV"

        foreach ($prop in $vault.PSObject.Properties) {
            $val = [string]$prop.Value
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                $cleanVal = $val.Trim()
                Write-Host "::add-mask::$cleanVal"
            }
        }

        $env:TELEGRAM_BOT_TOKEN = $vault.telegram_bot_token.Trim()
        $env:TELEGRAM_CHAT_ID   = $vault.telegram_chat_id.Trim()
        $env:TELEGRAM_ADMIN_ID  = $vault.telegram_admin_id.Trim()
        $env:TAILSCALE_AUTH_KEY = $vault.tailscale_auth_key.Trim()
        $env:RDP_USERNAME       = $vault.rdp_username.Trim()
        $env:RDP_PASSWORD       = $vault.rdp_password.Trim()
        $env:GH_TOKEN           = $vault.gh_token.Trim()

        "TELEGRAM_BOT_TOKEN=$($env:TELEGRAM_BOT_TOKEN)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TELEGRAM_CHAT_ID=$($env:TELEGRAM_CHAT_ID)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TELEGRAM_ADMIN_ID=$($env:TELEGRAM_ADMIN_ID)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        "TAILSCALE_AUTH_KEY=$($env:TAILSCALE_AUTH_KEY)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        "RDP_USERNAME=$($env:RDP_USERNAME)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        "RDP_PASSWORD=$($env:RDP_PASSWORD)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        "GH_TOKEN=$($env:GH_TOKEN)" | Out-File -FilePath $ghEnv -Append -Encoding utf8
        Write-Log "Secrets loaded, masked, and injected successfully!" "SUCCESS"
    } else {
        Write-Log "CRITICAL: System\secrets.json not found in Google Drive!" "ERROR"
        exit 1
    }

    # ====================================================================
    # AUTO-MOUNT & DESKTOP SCRIPT DEPLOYMENT
    # ====================================================================
    $desktopPath = "C:\Users\Public\Desktop"
    if (-not (Test-Path $desktopPath)) { New-Item -ItemType Directory -Path $desktopPath -Force | Out-Null }
    
    # [NEW] The Windows Global Startup Folder
    $startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupPath)) { New-Item -ItemType Directory -Path $startupPath -Force | Out-Null }
    
    $mountVbs = Join-Path $workspacePath "System\mount.vbs"
    $unmountVbs = Join-Path $workspacePath "System\unmount.vbs"
    
    if (Test-Path $mountVbs) {
        Copy-Item -Path $mountVbs -Destination "$desktopPath\mount.vbs" -Force
        # [NEW] Copy to Startup so it auto-executes on RDP Login!
        Copy-Item -Path $mountVbs -Destination "$startupPath\mount.vbs" -Force
        Write-Log "Deployed custom mount.vbs to Desktop and Auto-Startup." "SUCCESS"
    }
    if (Test-Path $unmountVbs) {
        Copy-Item -Path $unmountVbs -Destination "$desktopPath\unmount.vbs" -Force
        Write-Log "Deployed custom unmount.vbs to Desktop." "SUCCESS"
    }

    # RDP Initialization
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0
    Enable-NetFirewallRule -DisplayGroup $Config.rdp.firewallGroupName -ErrorAction SilentlyContinue | Out-Null
    if ((Get-Service $Config.rdp.serviceName).Status -ne 'Running') { Start-Service $Config.rdp.serviceName }
    if ($env:RDP_USERNAME -and $env:RDP_PASSWORD) {
        $secPass = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force
        if (-not (Get-LocalUser -Name $env:RDP_USERNAME -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name $env:RDP_USERNAME -Password $secPass -AccountNeverExpires -PasswordNeverExpires | Out-Null
            Add-LocalGroupMember -Group "Administrators" -Member $env:RDP_USERNAME
            Add-LocalGroupMember -Group "Remote Desktop Users" -Member $env:RDP_USERNAME
        }
    }

    # Tailscale Setup
    if ($env:TAILSCALE_AUTH_KEY) {
        Write-Log "Installing Tailscale VPN via Chocolatey..." "INFO"
        choco install tailscale -y --no-progress | Out-Null
        $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
        if (Test-Path $tsPath) {
            Write-Log "Authenticating Tailscale network..." "INFO"
            & $tsPath up --authkey=$env:TAILSCALE_AUTH_KEY --hostname="RDP-Worker-$env:GITHUB_RUN_ID" --reset
            
            $tsIp = (& $tsPath ip -4 2>$null).Trim()
            Write-Log "Tailscale connected successfully!" "SUCCESS"
            Write-Log "==========================================" "SUCCESS"
            Write-Log "🖥️ RDP IP ADDRESS: $tsIp" "SUCCESS"
            Write-Log "==========================================" "SUCCESS"
        }
    }

    # aria2 Initialization
    $aria2Path = Join-Path $workspacePath "aria2"
    if (-not (Test-Path $aria2Path)) {
        New-Item -ItemType Directory -Path $aria2Path | Out-Null
        $aria2Zip = "$env:TEMP\aria2.zip"
        Invoke-WebRequest -Uri "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip" -OutFile $aria2Zip
        Expand-Archive -Path $aria2Zip -DestinationPath $aria2Path -Force
    }
    
    $sessionFile = Join-Path $statePath "aria2.session"
    if (-not (Test-Path $sessionFile)) { New-Item -ItemType File -Path $sessionFile -Force | Out-Null }

    $aria2Exe = (Get-ChildItem -Path $aria2Path -Filter "aria2c.exe" -Recurse).FullName
    $ariaArgs = "--enable-rpc --rpc-listen-all=false --rpc-listen-port=$($Config.aria2.rpcPort) --dir=`"$downloadsPath`" --max-concurrent-downloads=$($Config.aria2.maxConcurrent) --split=$($Config.aria2.split) --continue=true --save-session=`"$sessionFile`" --input-file=`"$sessionFile`""
    Start-Process -FilePath $aria2Exe -ArgumentList $ariaArgs -WindowStyle Hidden

    "WORKSPACE_ROOT=$workspacePath" | Out-File -FilePath $env:GITHUB_ENV -Append
    Write-Log "Phase 9.3 Bootstrap Complete." "SUCCESS"
    
    $global:LASTEXITCODE = 0

} catch { Write-Log $_.Exception.Message "ERROR"; exit 1 }
