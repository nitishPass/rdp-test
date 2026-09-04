<#
.SYNOPSIS
    RDP Manager - Bootstrap (Phase 5)
.DESCRIPTION
    Validates config, allocates workspace, configures RDP, and starts aria2 RPC.
#>

[CmdletBinding()]
param (
    [string]$ConfigPath = "$PSScriptRoot\..\config\settings.json"
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param ([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'INFO'{'Cyan'} 'WARN'{'Yellow'} 'ERROR'{'Red'} 'SUCCESS'{'Green'} }
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] [$Level] $Message" -ForegroundColor $color
}

try {
    # 1. Configuration Loading
    Write-Log "Loading configuration from $ConfigPath"
    if (-not (Test-Path $ConfigPath)) { throw "settings.json not found." }
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # 2. Dynamic Storage Detection
    Write-Log "Analyzing storage volumes..."
    $volumes = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 -and $_.Root -match '^[A-Z]:\\$' }
    $bestDrive = $volumes | Sort-Object Free -Descending | Select-Object -First 1
    
    $freeGB = [math]::Round($bestDrive.Free / 1GB, 2)
    Write-Log "Selected Drive $($bestDrive.Name): with $freeGB GB free space." "SUCCESS"

    # 3. Workspace Initialization
    $workspacePath = Join-Path $bestDrive.Root $Config.storage.workspaceRootName
    $statePath = Join-Path $workspacePath $Config.storage.stateFolderName
    $downloadsPath = Join-Path $workspacePath $Config.storage.downloadsFolderName

    $null = New-Item -ItemType Directory -Force -Path $statePath
    $null = New-Item -ItemType Directory -Force -Path $downloadsPath
    Write-Log "Workspace initialized at $workspacePath" "SUCCESS"

    # 4. RDP Idempotent Initialization
    Write-Log "Configuring RDP Services..."
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0
    Enable-NetFirewallRule -DisplayGroup $Config.rdp.firewallGroupName -ErrorAction SilentlyContinue | Out-Null
    
    if ((Get-Service $Config.rdp.serviceName).Status -ne 'Running') {
        Start-Service $Config.rdp.serviceName
    }

    # 5. RDP User Provisioning
    if ($env:RDP_USERNAME -and $env:RDP_PASSWORD) {
        $secPass = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force
        if (-not (Get-LocalUser -Name $env:RDP_USERNAME -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name $env:RDP_USERNAME -Password $secPass -AccountNeverExpires -PasswordNeverExpires | Out-Null
            Add-LocalGroupMember -Group "Administrators" -Member $env:RDP_USERNAME
            Add-LocalGroupMember -Group "Remote Desktop Users" -Member $env:RDP_USERNAME
            Write-Log "RDP User provisioned successfully." "SUCCESS"
        }
    } else { throw "RDP credentials not found in environment variables." }

    # 6. Session State Generation
    $sessionState = @{
        session_id = [guid]::NewGuid().ToString()
        status = "INITIALIZED"
        workspace = @{ drive = $bestDrive.Name; root_path = $workspacePath }
        timestamp = (Get-Date).ToString('o')
    }
    $sessionStateFile = Join-Path $statePath "session.json"
    $sessionState | ConvertTo-Json | Set-Content $sessionStateFile

    # 7. Start aria2c RPC Daemon
    Write-Log "Installing aria2c Download Engine..." "INFO"
    $aria2Path = Join-Path $workspacePath "aria2"
    if (-not (Test-Path $aria2Path)) { New-Item -ItemType Directory -Path $aria2Path | Out-Null }
    
    $aria2Zip = "$env:TEMP\aria2.zip"
    Invoke-WebRequest -Uri "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip" -OutFile $aria2Zip
    Expand-Archive -Path $aria2Zip -DestinationPath $aria2Path -Force
    $aria2Exe = (Get-ChildItem -Path $aria2Path -Filter "aria2c.exe" -Recurse).FullName

    Write-Log "Starting aria2c RPC server on port $($Config.aria2.rpcPort)..." "INFO"
    $ariaArgs = "--enable-rpc --rpc-listen-all=false --rpc-listen-port=$($Config.aria2.rpcPort) --dir=`"$downloadsPath`" --max-concurrent-downloads=$($Config.aria2.maxConcurrent) --split=$($Config.aria2.split) --continue=true"
    Start-Process -FilePath $aria2Exe -ArgumentList $ariaArgs -WindowStyle Hidden
    Write-Log "aria2c running in background." "SUCCESS"

    # 8. Export outputs for GitHub Actions
    "WORKSPACE_ROOT=$workspacePath" | Out-File -FilePath $env:GITHUB_ENV -Append
    Write-Log "Phase 5 Bootstrap Complete." "SUCCESS"

} catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}
