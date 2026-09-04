<#
.SYNOPSIS
    RDP Manager - BotService (Phase 6)
#>

$ErrorActionPreference = 'Continue'
$StartTime = Get-Date
$WorkspacePath = $env:WORKSPACE_ROOT
$LogFile = if ($WorkspacePath) { Join-Path $WorkspacePath "State\bot.log" } else { "C:\Users\Public\Desktop\bot_emergency.log" }

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    if ($env:TELEGRAM_BOT_TOKEN) { $Message = $Message.Replace($env:TELEGRAM_BOT_TOKEN, "[REDACTED_TOKEN]") }
    $logEntry = "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry; Write-Host $logEntry
}

Write-BotLog "=== BOT SERVICE (PHASE 6) STARTED ===" "INFO"
$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) { Write-BotLog "Missing credentials!"; exit 1 }
$ApiUrl = "https://api.telegram.org/bot$BotToken"
$Offset = 0; $JobCounter = 1
$global:DashboardMessageId = $null; $global:DashboardLastUpdate = [DateTime]::MinValue
$global:JobMessageMap = @{}
$global:ShutdownRequested = $false

. (Join-Path $PSScriptRoot "JobManager.ps1")
. (Join-Path $PSScriptRoot "RelayManager.ps1")
Initialize-JobManager

function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML")
    try {
        $payload = @{ chat_id = $AllowedChatId; text = $Text; parse_mode = $ParseMode }
        $resp = Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $payload
        return $resp.result.message_id
    } catch { }
}

function Edit-TelegramMessage {
    param ([string]$MessageId, [string]$Text, [string]$ParseMode = "HTML")
    try {
        $payload = @{ chat_id = $AllowedChatId; message_id = $MessageId; text = $Text; parse_mode = $ParseMode }
        Invoke-RestMethod -Uri "$ApiUrl/editMessageText" -Method Post -Body $payload | Out-Null
    } catch { }
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -gt 1GB) { return "$([math]::Round($Bytes/1GB, 2)) GB" }
    if ($Bytes -gt 1MB) { return "$([math]::Round($Bytes/1MB, 2)) MB" }
    return "$([math]::Round($Bytes/1KB, 2)) KB"
}

function Route-Command {
    param ([string]$CommandText)
    $cleanCommand = $CommandText.Trim() -replace '@\S+', ''
    $parts = $cleanCommand -split '\s+', 2
    $cmd = $parts[0].ToLower()
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    if ($Config.telegram.commands.lightweight -contains $cmd) {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/jobs" { Send-TelegramMessage (Get-ActiveJobsFormatted) }
            "/help" { Send-TelegramMessage "🤖 <b>Commands:</b>`n/download URL - Start download`n/downloads - View queue`n/workspace - Cloud State`n/backup - Force Cloud Sync`n/relay - Hand off to next runner" }
            "/cancel" {
                $target = $args.ToUpper().Trim()
                if ($global:JobManager_Jobs.ContainsKey($target)) {
                    $global:JobManager_CancelDict[$target] = $true
                    Send-TelegramMessage "🛑 Cancellation requested for <code>$target</code>"
                }
            }
            "/workspace" {
                $drvLet = $WorkspacePath.Substring(0,1)
                $size = Format-Bytes ((Get-ChildItem $WorkspacePath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
                $rcloneStat = if (Test-Path "$WorkspacePath\rclone.exe") { "🟢 CONFIGURED" } else { "🔴 MISSING" }
                Send-TelegramMessage "☁️ <b>WORKSPACE STATE</b>`n━━━━━━━━━━━━━━━━━━━━`nPath: <code>$WorkspacePath</code>`nLocal Size: $size`nRclone: $rcloneStat`n`n<i>Use /backup to sync to CloudVault.</i>"
            }
        }
        return
    }

    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        $msgId = Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd"
        if ($msgId) { $global:JobMessageMap[$jobId] = @{ MessageId = $msgId; LastUpdate = Get-Date } }
        
        switch ($cmd) {
            "/download" {
                $sb = {
                    param($JobId, $Url, $RpcPort, $CancelDict, $ProgressDict)
                    $rpc = "http://127.0.0.1:$RpcPort/jsonrpc"
                    $safeUrl = $Url -replace '"', '\"'
                    $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.addUri`", `"params`": [[`"$safeUrl`"]] }"
                    $res = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
                    $gid = $res.result
                    if (-not $gid) { throw "Failed to get GID from aria2." }
                    
                    $completed = $false
                    while (-not $completed) {
                        Start-Sleep -Seconds 2
                        if ($CancelDict.ContainsKey($JobId)) {
                            $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.remove`", `"params`": [`"$gid`"] }"
                            Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json" | Out-Null
                            throw "Cancelled by user (Data preserved)."
                        }
                        $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.tellStatus`", `"params`": [`"$gid`"] }"
                        $statusRes = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
                        $info = $statusRes.result
                        $ProgressDict[$JobId] = $info
                        if ($info.status -eq "complete" -or $info.status -eq "error" -or $info.status -eq "removed") {
                            $completed = $true
                            if ($info.status -eq "error") { throw "Aria2 Error: $($info.errorCode)" }
                        }
                    }
                    return "✅ Download successfully completed!"
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($jobId, $args, $Config.aria2.rpcPort, $global:JobManager_CancelDict, $global:JobManager_ProgressDict)
            }
            "/backup" {
                $sb = {
                    param($WsPath, $CloudName, $RootName)
                    return Sync-CloudWorkspace -WsPath $WsPath -CloudName $CloudName -RootName $RootName
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($WorkspacePath, $Config.relay.cloudDriveName, $Config.storage.workspaceRootName)
            }
            "/relay" {
                $sb = {
                    param($WsPath, $CloudName, $RootName, $Repo, $Token)
                    $syncRes = Sync-CloudWorkspace -WsPath $WsPath -CloudName $CloudName -RootName $RootName
                    $relayRes = Invoke-RunnerRelay -Repo $Repo -Token $Token
                    return "$syncRes`n$relayRes`n`n⚠️ Shutting down current runner in 10 seconds to allow handoff."
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($WorkspacePath, $Config.relay.cloudDriveName, $Config.storage.workspaceRootName, $env:GITHUB_REPO, $env:GH_TOKEN)
            }
        }
    }
}

if ($env:IS_RELAY -eq 'true') { Send-TelegramMessage "🔄 <b>RELAY RESTORE COMPLETE</b>`nNew GitHub runner successfully took over the workspace." }
else { Send-TelegramMessage "🚀 <b>BotService Started</b>`nReady for commands." }

while (-not $global:ShutdownRequested) {
    try {
        $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$Offset&timeout=$($Config.telegram.longPollingTimeoutSeconds)" -Method Get -TimeoutSec ($Config.telegram.longPollingTimeoutSeconds + 5)
        if ($updates.ok -and $updates.result.Count -gt 0) {
            foreach ($update in $updates.result) {
                $Offset = $update.update_id + 1
                $msg = $update.message
                if (-not $msg.text) { continue }
                if ([string]$msg.chat.id -ne $AllowedChatId -or [string]$msg.from.id -ne $AdminUserId) { continue }
                Route-Command -Command $msg.text
            }
        }
    } catch { }

    $jobEvents = Invoke-JobManagerTick
    foreach ($event in $jobEvents) {
        if ($global:JobMessageMap.ContainsKey($event.JobId)) {
            $msgId = $global:JobMessageMap[$event.JobId].MessageId
            if ($event.Event -eq 'COMPLETED') { 
                Edit-TelegramMessage -MessageId $msgId -Text "✅ <b>$($event.JobId) COMPLETED</b>`n`n$($event.Result)" 
                if ($event.Command -eq '/relay') { 
                    Start-Sleep -Seconds 10
                    $global:ShutdownRequested = $true 
                }
            }
            elseif ($event.Event -eq 'FAILED') { Edit-TelegramMessage -MessageId $msgId -Text "❌ <b>$($event.JobId) FAILED</b>`n`nReason: $($event.Result)" }
            $global:JobMessageMap.Remove($event.JobId)
        }
    }

    # Auto-Relay Timer Check
    if ((Get-Date) -ge $StartTime.AddMinutes($Config.relay.autoRelayMinutes)) {
        Write-BotLog "Auto-Relay time reached (340 mins). Triggering handoff." "WARN"
        Send-TelegramMessage "⚠️ <b>RUNNER TIME LIMIT APPROACHING (340 MINS)</b>`nTriggering automatic workspace relay..."
        Route-Command -Command "/relay"
        $StartTime = (Get-Date).AddDays(1) # Prevent re-triggering while shutting down
    }
}

Write-BotLog "Shutdown requested. Exiting BotService safely." "SUCCESS"
exit 0
