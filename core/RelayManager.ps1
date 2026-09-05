<#
.SYNOPSIS
    RDP Manager - RelayManager (Phase 6.3)
.DESCRIPTION
    Handles rclone cloud synchronization and GitHub API runner handoffs.
#>

function Sync-CloudWorkspace {
    param([string]$WsPath, [string]$CloudName, [string]$RootName, [string]$RpcPort = "6800")
    
    # 1. Force pause and explicitly save the aria2 session to disk
    try {
        $rpc = "http://127.0.0.1:$RpcPort/jsonrpc"
        
        $body1 = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.forcePauseAll`" }"
        Invoke-RestMethod -Uri $rpc -Method Post -Body $body1 -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
        
        $body2 = "{ `"jsonrpc`": `"2.0`", `"id`": `"2`", `"method`": `"aria2.saveSession`" }"
        Invoke-RestMethod -Uri $rpc -Method Post -Body $body2 -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
        
        Start-Sleep -Seconds 4
    } catch { }

    $rclone = Join-Path $WsPath "rclone.exe"
    if (-not (Test-Path $rclone)) { throw "rclone is not installed or configured." }
    
    $cloudTarget = "${CloudName}:${RootName}"
    $confPath = "$env:APPDATA\rclone\rclone.conf"
    $logPath = Join-Path $WsPath "State\rclone_sync.log"
    
    # 2. Push Local -> Cloud (FIXED DEADLOCK: Redirect streams to a log file instead of the invisible console)
    $argsList = @("copy", "`"$WsPath`"", "`"$cloudTarget`"", "--config", "`"$confPath`"", "--exclude", "`"State/bot.log`"", "--exclude", "`"State/rclone_sync.log`"", "--transfers", "4", "--retries", "3", "--local-no-check-updated")
    
    $proc = Start-Process -FilePath $rclone -ArgumentList $argsList -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $logPath
    
    if ($proc.ExitCode -ne 0) { 
        $errLog = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
        throw "Rclone sync failed (Code $($proc.ExitCode)). Details: $errLog" 
    }
    return "✅ Workspace successfully synchronized to Cloud Vault."
}

function Invoke-RunnerRelay {
    param([string]$Repo, [string]$Token)
    if (-not $Token) { throw "GH_TOKEN not found! Cannot trigger next runner." }
    if (-not $Repo) { throw "GITHUB_REPO environment variable not found." }
    
    $headers = @{
        "Accept" = "application/vnd.github+json"
        "Authorization" = "Bearer $Token"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    
    $body = @{ ref = "main"; inputs = @{ is_relay = "true" } } | ConvertTo-Json
    $url = "https://api.github.com/repos/$Repo/actions/workflows/rdp.yml/dispatches"
    
    try {
        Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -ContentType "application/json"
        return "🚀 Relay Signal Sent! Next runner is booting."
    } catch {
        throw "GitHub API Error: $($_.Exception.Message)"
    }
}
