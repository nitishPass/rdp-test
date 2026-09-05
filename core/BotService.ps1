<#
.SYNOPSIS
    RDP Manager - BotService (Phase 6.5)
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

function Get-LiveDashboardText {
    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
    $drvLet = if ($WorkspacePath) { $WorkspacePath.Substring(0,1) } else { "C" }
    $drv = Get-PSDrive -Name $drvLet
    $disk = [math]::Round((($drv.Used) / ($drv.Used + $drv.Free)) * 100, 1)
    $uptime = (Get-Date) - $StartTime
    $upStr = "{0:00}:{1:00}:{2:00}" -f $uptime.Hours, $uptime.Minutes, $uptime.Seconds
    $jStats = Get-JobManagerStats

    $out = "┌─────────────────────────────┐`n│ 🖥️ <b>RDP MANAGER DASHBOARD</b>`n│ ───────────────────────────`n│ 🟢 SYSTEM ONLINE`n│`n"
    $out += "│ CPU  $cpu%`n│ RAM  $ram%`n│ DISK $disk% (${drvLet}:)`n│`n"
    $out += "│ Jobs: $($jStats.Running) RUNNING`n│ Uptime: $upStr`n│ Updated: $((Get-Date).ToString('HH:mm:ss'))`n└─────────────────────────────┘"
    return $out
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -gt 1GB) { return "$([math]::Round($Bytes/1GB, 2)) GB" }
    if ($Bytes -gt 1MB) { return "$([math]::Round($Bytes/1MB, 2)) MB" }
    return "$([math]::Round($Bytes/1KB, 2)) KB"
}

function Get-ProgressBar([double]$Percent) {
    $filled = [math]::Floor($Percent / 10); $empty = 10 - $filled
    return ("█" * $filled) + ("░" * $empty)
}

function Format-ETA([double]$Speed, [double]$Remaining) {
    if ($Speed -le 0) { return "∞" }
    $secs = [math]::Round($Remaining / $Speed)
    $ts = [timespan]::fromseconds($secs)
    if ($ts.Hours -gt 0) { return "{0}h {1}m" -f $ts.Hours, $ts.Minutes }
    if ($ts.Minutes -gt 0) { return "{0}m {1}s" -f $ts.Minutes, $ts.Seconds }
    return "{0}s" -f $ts.Seconds
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
            "/downloads" {
                try {
                    $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.tellActive`" }"
                    $res = Invoke-RestMethod -Uri "http://127.0.0.1:$($Config.aria2.rpcPort)/jsonrpc" -Method Post -Body $body -ContentType "application/json"
                    if ($res.result.Count -eq 0) { Send-TelegramMessage "📥 <b>DOWNLOADS</b>`nNo active downloads."; return }
                    $out = "📥 <b>ACTIVE DOWNLOADS</b>`n"
                    foreach ($d in $res.result) {
                        $pct = if ([double]$d.totalLength -gt 0) { [math]::Round(([double]$d.completedLength / [double]$d.totalLength) * 100, 1) } else { 0 }
                        $spd = Format-Bytes ([double]$d.downloadSpeed)
                        $out += "🔹 GID: <code>$($d.gid)</code> | $pct% | $spd/s`n"
                    }
                    Send-TelegramMessage $out
                } catch { Send-TelegramMessage "⚠️ Cannot reach aria2 engine." }
            }
            "/status" {
                $msgId = Send-TelegramMessage (Get-LiveDashboardText)
                if ($msgId) {
                    $global:DashboardMessageId = $msgId; $global:DashboardLastUpdate = Get-Date
                }
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
            "/diagnostics" {
                $sb = {
                    param($WsPath, $JobStats)
                    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
                    $ram = [math]::Round(((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize - (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory) / (Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize * 100, 1)
                    $drvLet = if ($WsPath) { $WsPath.Substring(0,1) } else { "C" }
                    $freeGb = [math]::Round((Get-PSDrive -Name $drvLet).Free / 1GB, 1)
                    return "🚀 <b>DIAGNOSTICS</b>`n━━━━━━━━━━━━━━━━━━━━`n🖥️ <b>SYSTEM</b>`nCPU: $cpu% | RAM: $ram%`n`n💾 <b>WORKSPACE (${drvLet}:)</b>`nFree Space: $freeGb GB`n`n🟢 <b>ALL SYSTEMS HEALTHY</b>"
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($WorkspacePath, (Get-JobManagerStats))
            }
            "/download" {
                $sb = {
                    param($JobId, $Url, $RpcPort, $CancelDict, $ProgressDict)
                    $rpc = "http://127.0.0.1:$RpcPort/jsonrpc"
                    $safeUrl = $Url -replace '"', '\"'
                    
                    $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.addUri`", `"params`": [[`"$safeUrl`"], {`"max-download-limit`": `"20M`"}] }"
                    $res = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
                    $gid = $res.result
                    if (-not $gid) { throw "Failed to get GID from aria2." }
                    
                    # FIXED: Wake up all downloads in case they were restored from a paused cloud state
                    $unpauseBody = "{ `"jsonrpc`": `"2.0`", `"id`": `"2`", `"method`": `"aria2.unpauseAll`" }"
                    Invoke-RestMethod -Uri $rpc -Method Post -Body $unpauseBody -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
                    
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
                        
                        # FIXED: Removed 'paused' from the kill-switch. Paused jobs just show PAUSED now.
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
                    param($WsPath, $CloudName, $RootName, $CorePath, $RpcPort)
                    . (Join-Path $CorePath "RelayManager.ps1")
                    return Sync-CloudWorkspace -WsPath $WsPath -CloudName $CloudName -RootName $RootName -RpcPort $RpcPort
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($WorkspacePath, $Config.relay.cloudDriveName, $Config.storage.workspaceRootName, $PSScriptRoot, $Config.aria2.rpcPort)
            }
            "/relay" {
                $sb = {
                    param($WsPath, $CloudName, $RootName, $Repo, $Token, $CorePath, $RpcPort)
                    . (Join-Path $CorePath "RelayManager.ps1")
                    $syncRes = Sync-CloudWorkspace -WsPath $WsPath -CloudName $CloudName -RootName $RootName -RpcPort $RpcPort
                    $relayRes = Invoke-RunnerRelay -Repo $Repo -Token $Token
                    return "$syncRes`n$relayRes`n`n⚠️ Shutting down current runner in 10 seconds to allow handoff."
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($WorkspacePath, $Config.relay.cloudDriveName, $Config.storage.workspaceRootName, $env:GITHUB_REPO, $env:GH_TOKEN, $PSScriptRoot, $Config.aria2.rpcPort)
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

    $keys = @($global:JobManager_ProgressDict.Keys)
    foreach ($jId in $keys) {
        if ($global:JobMessageMap.ContainsKey($jId)) {
            $msgData = $global:JobMessageMap[$jId]
            if ((Get-Date) -ge $msgData.LastUpdate.AddSeconds($Config.aria2.progressUpdateSeconds)) {
                $info = $global:JobManager_ProgressDict[$jId]
                if ($info) {
                    $total = [double]$info.totalLength; $done = [double]$info.completedLength; $speed = [double]$info.downloadSpeed
                    $pct = if ($total -gt 0) { [math]::Round(($done / $total) * 100, 1) } else { 0 }
                    $progBar = Get-ProgressBar -Percent $pct
                    $doneStr = Format-Bytes -Bytes $done; $totalStr = Format-Bytes -Bytes $total
                    $spdStr = Format-Bytes -Bytes $speed
                    $etaStr = Format-ETA -Speed $speed -Remaining ($total - $done)
                    
                    $text = "📥 <b>$jId</b>`n━━━━━━━━━━━━━━━━━━━━`n$progBar $pct%`n$doneStr / $totalStr`nSpeed: $spdStr/s`nETA: $etaStr`nStatus: $($info.status.ToUpper())"
                    Edit-TelegramMessage -MessageId $msgData.MessageId -Text $text
                    $msgData.LastUpdate = Get-Date
                }
            }
        }
    }

    if ($global:DashboardMessageId -and ((Get-Date) -ge $global:DashboardLastUpdate.AddSeconds($Config.telegram.dashboardRefreshSeconds))) {
        $global:DashboardLastUpdate = Get-Date
        $dashText = Get-LiveDashboardText
        Edit-TelegramMessage -MessageId $global:DashboardMessageId -Text $dashText
    }

    if ((Get-Date) -ge $StartTime.AddMinutes($Config.relay.autoRelayMinutes)) {
        Write-BotLog "Auto-Relay time reached (340 mins). Triggering handoff." "WARN"
        Send-TelegramMessage "⚠️ <b>RUNNER TIME LIMIT APPROACHING (340 MINS)</b>`nTriggering automatic workspace relay..."
        Route-Command -Command "/relay"
        $StartTime = (Get-Date).AddDays(1) 
    }
}

Write-BotLog "Shutdown requested. Exiting BotService safely." "SUCCESS"
exit 0
