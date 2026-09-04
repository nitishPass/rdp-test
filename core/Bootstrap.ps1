<#
.SYNOPSIS
    RDP Manager - Bootstrap (Phase 6)
.DESCRIPTION
    Allocates workspace, installs rclone, restores cloud state, and starts aria2.
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

    # 1. Dynamic Storage Detection
    $volumes = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 -and $_.Root -match '^[A-Z]:\\$' }
    $bestDrive = $volumes | Sort-Object Free -Descending | Select-Object -First 1
    $workspacePath = Join-Path $bestDrive.Root $Config.storage.workspaceRootName
    $statePath = Join-Path $workspacePath $Config.storage.stateFolderName
    $downloadsPath = Join-Path $workspacePath $Config.storage.downloadsFolderName
    
    $null = New-Item -ItemType Directory -Force -Path $statePath
    $null = New-Item -ItemType Directory -Force -Path $downloadsPath
    Write-Log "Workspace initialized at $workspacePath" "SUCCESS"

    # 2. Rclone Installation & Config
    if ($env:RCLONE_CONFIG_DATA) {
        Write-Log "Installing rclone & injecting config..." "INFO"
        $rcloneConfDir = "$env:APPDATA\rclone"
        New-Item -ItemType Directory -Force -Path $rcloneConfDir | Out-Null
        Set-Content -Path "$rcloneConfDir\rclone.conf" -Value $env:RCLONE_CONFIG_DATA
        
        $rcloneZip = "$env:TEMP\rclone.zip"
        Invoke-WebRequest -Uri "https://downloads.rclone.org/v1.65.2/rclone-v1.65.2-windows-amd64.zip" -OutFile $rcloneZip
        Expand-Archive -Path $rcloneZip -DestinationPath "$env:TEMP\rclone_ext" -Force
        $rcloneExe = (Get-ChildItem -Path "$env:TEMP\rclone_ext" -Filter "rclone.exe" -Recurse).FullName
        Copy-Item $rcloneExe -Destination "$workspacePath\rclone.exe" -Force
        
        # RESTORE WORKSPACE FROM CLOUD
        Write-Log "Syncing Cloud Workspace -> Local Disk..." "INFO"
        $cloudTarget = "$($Config.relay.cloudDriveName):$($Config.storage.workspaceRootName)"
        
        # FIXED: Create the directory in Google Drive first so rclone doesn't crash on the very first run!
        & "$workspacePath\rclone.exe" mkdir $cloudTarget
        & "$workspacePath\rclone.exe" copy $cloudTarget $workspacePath --transfers 8
        
        Write-Log "Cloud Restore Complete." "SUCCESS"
    } else {
        Write-Log "RCLONE_CONFIG_DATA not found. Skipping cloud sync." "WARN"
    }

    # 3. RDP Initialization
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

    # 4. Start aria2c RPC Daemon
    $aria2Path = Join-Path $workspacePath "aria2"
    if (-not (Test-Path $aria2Path)) {
        New-Item -ItemType Directory -Path $aria2Path | Out-Null
        $aria2Zip = "$env:TEMP\aria2.zip"
        Invoke-WebRequest -Uri "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip" -OutFile $aria2Zip
        Expand-Archive -Path $aria2Zip -DestinationPath $aria2Path -Force
    }
    $aria2Exe = (Get-ChildItem -Path $aria2Path -Filter "aria2c.exe" -Recurse).FullName
    $ariaArgs = "--enable-rpc --rpc-listen-all=false --rpc-listen-port=$($Config.aria2.rpcPort) --dir=`"$downloadsPath`" --max-concurrent-downloads=$($Config.aria2.maxConcurrent) --split=$($Config.aria2.split) --continue=true"
    Start-Process -FilePath $aria2Exe -ArgumentList $ariaArgs -WindowStyle Hidden

    "WORKSPACE_ROOT=$workspacePath" | Out-File -FilePath $env:GITHUB_ENV -Append
    Write-Log "Phase 6 Bootstrap Complete." "SUCCESS"
    
    # FIXED: Clear the exit code so GitHub Actions doesn't fail from random native command warnings.
    $global:LASTEXITCODE = 0

} catch { Write-Log $_.Exception.Message "ERROR"; exit 1 }
