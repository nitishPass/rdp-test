<#
.SYNOPSIS
    RDP Manager - RelayManager (Phase 8.6 - System Vault Protection)
#>

function Sync-CloudWorkspace {
    param([string]$WsPath, [string]$CloudName, [string]$RootName, [string]$RpcPort = "6800", [string]$JobId = "", $ProgDict = $null)
    
    function Set-Status([string]$Msg, [int]$Pct) {
        if ($JobId -and $null -ne $ProgDict) { $ProgDict[$JobId] = @{ type="sys"; msg=$Msg; pct=$Pct } }
    }

    Set-Status "Flushing I/O & Pausing Downloads..." 10
    try {
        $rpc = "http://127.0.0.1:$RpcPort/jsonrpc"
        Invoke-RestMethod -Uri $rpc -Method Post -Body "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.forcePauseAll`" }" -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
        Invoke-RestMethod -Uri $rpc -Method Post -Body "{ `"jsonrpc`": `"2.0`", `"id`": `"2`", `"method`": `"aria2.saveSession`" }" -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
    } catch { }

    Set-Status "Archiving System Logs..." 25
    $logDest = Join-Path $WsPath "LogsArchive"
    if (-not (Test-Path $logDest)) { New-Item -ItemType Directory -Path $logDest | Out-Null }
    $timeStamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    Copy-Item -Path (Join-Path $WsPath "State\bot.log") -Destination (Join-Path $logDest "bot_$timeStamp.log") -ErrorAction SilentlyContinue

    $rclone = Join-Path $WsPath "rclone.exe"
    if (-not (Test-Path $rclone)) { throw "rclone is not installed or configured." }
    
    $cloudTarget = "${CloudName}:${RootName}"
    $confPath = "C:\Users\Public\rclone.conf"
    $rcloneLog = Join-Path $WsPath "State\rclone_sync.log"
    
    Set-Status "Pushing files to CloudVault (Gigabit Mode Active)..." 50
    
    # [FIX] --exclude "System/**" ensures your master scripts/secrets in Google Drive are NEVER overwritten!
    $rcloneArgs = @(
        "copy", $WsPath, $cloudTarget, 
        "--config", $confPath, 
        "--exclude", "State/bot.log", 
        "--exclude", "State/rclone_sync.log", 
        "--exclude", "System/**",
        "--transfers", "8", 
        "--checkers", "8",
        "--drive-chunk-size", "512M",
        "--retries", "3", 
        "--local-no-check-updated", 
        "--log-file", $rcloneLog, 
        "--log-level", "INFO"
    )
    
    & $rclone @rcloneArgs 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) { 
        $errLog = Get-Content $rcloneLog -Raw -ErrorAction SilentlyContinue
        throw "Rclone sync failed (Code $LASTEXITCODE). Details: $errLog" 
    }

    Copy-Item -Path $rcloneLog -Destination (Join-Path $logDest "rclone_$timeStamp.log") -ErrorAction SilentlyContinue

    Set-Status "Cloud Sync Complete!" 100
    return "✅ Workspace & Logs successfully synchronized to Cloud Vault."
}

function Invoke-RunnerRelay {
    param([string]$Repo, [string]$Token, [string]$JobId = "", $ProgDict = $null)
    
    if ($JobId -and $null -ne $ProgDict) { $ProgDict[$JobId] = @{ type="sys"; msg="Dispatching GitHub API Handoff..."; pct=100 } }
    
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
