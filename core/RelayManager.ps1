<#
.SYNOPSIS
    RDP Manager - RelayManager (Phase 6)
.DESCRIPTION
    Handles rclone cloud synchronization and GitHub API runner handoffs.
#>

function Sync-CloudWorkspace {
    param([string]$WsPath, [string]$CloudName, [string]$RootName)
    $rclone = Join-Path $WsPath "rclone.exe"
    
    if (-not (Test-Path $rclone)) { throw "rclone is not installed or configured." }
    
    $cloudTarget = "${CloudName}:${RootName}"
    # Push Local -> Cloud. Exclude the live bot log so it doesn't lock.
    $proc = Start-Process -FilePath $rclone -ArgumentList "copy `"$WsPath`" `"$cloudTarget`" --exclude `"State/bot.log`" --transfers 8" -Wait -PassThru
    
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
        Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body
        return "🚀 Relay Signal Sent! Next runner is booting."
    } catch {
        throw "GitHub API Error: $($_.Exception.Message)"
    }
}
