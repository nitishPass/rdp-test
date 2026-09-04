<#
.SYNOPSIS
    RDP Manager - RelayManager (Phase 6.1)
.DESCRIPTION
    Handles rclone cloud synchronization and GitHub API runner handoffs.
#>

function Sync-CloudWorkspace {
    param([string]$WsPath, [string]$CloudName, [string]$RootName, [string]$RpcPort = "6800")
    
    # 1. Safely pause aria2 to flush partial .aria2 files to disk!
    try {
        $rpc = "http://127.0.0.1:$RpcPort/jsonrpc"
        $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.pauseAll`" }"
        Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
    } catch { }

    $rclone = Join-Path $WsPath "rclone.exe"
    if (-not (Test-Path $rclone)) { throw "rclone is not installed or configured." }
    
    $cloudTarget = "${CloudName}:${RootName}"
    $confPath = "$env:APPDATA\rclone\rclone.conf"
    
    # 2. Push Local -> Cloud.
    $proc = Start-Process -FilePath $rclone -ArgumentList "copy `"$WsPath`" `"$cloudTarget`" --config `"$confPath`" --exclude `"State/bot.log`" --transfers 8" -Wait -PassThru -NoNewWindow
    
    if ($proc.ExitCode -ne 0) { throw "Rclone sync failed with exit code $($proc.ExitCode)" }
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
        # CRITICAL: -ContentType application/json is required by GitHub
        Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -ContentType "application/json"
        return "🚀 Relay Signal Sent! Next runner is booting."
    } catch {
        throw "GitHub API Error: $($_.Exception.Message)"
    }
}
