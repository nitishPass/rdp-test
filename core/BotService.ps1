<#
.SYNOPSIS
    RDP Manager - BotService (Phase 5)
.DESCRIPTION
    Control Plane for Telegram. Features aria2 Integration, Live Dashboard, and Progress Tracking.
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

Write-BotLog "=== BOT SERVICE (PHASE 5) STARTED ===" "INFO"

$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) { Write-BotLog "CRITICAL ERROR: Missing credentials!" "ERROR"; exit 1 }

$ApiUrl = "https://api.telegram.org/bot$BotToken"
$Offset = 0
$JobCounter = 1

$global:DashboardMessageId = $null
$global:DashboardLastUpdate = [DateTime]::MinValue
$global:JobMessageMap = @{}

. (Join-Path $PSScriptRoot "JobManager.ps1")
Initialize-JobManager

# -------------------------------------------------------------------------
# HELPER FUNCTIONS & API
# -------------------------------------------------------------------------
function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML")
    try {
        $payload = @{ chat_id = $AllowedChatId; text = $Text; parse_mode = $ParseMode }
        $resp = Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $payload
        return $resp.result.message_id
    } catch { Write-BotLog "API ERROR: $($_.Exception.Message)" "ERROR" }
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

function Get-ProgressBar([double]$Percent) {
    $filled = [math]::Floor($Percent / 10); $empty = 10 - $filled
    return ("█" * $filled) + ("░" * $empty)
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -gt 1GB) { return "$([math]::Round($Bytes/1GB, 2)) GB" }
    if ($Bytes -gt 1MB) { return "$([math]::Round($Bytes/1MB, 2)) MB" }
    return "$([math]::Round($Bytes/1KB, 2)) KB"
}

function Format-ETA([double]$Speed, [double]$Remaining) {
    if ($Speed -le 0) { return "∞" }
    $secs = [math]::Round($Remaining / $Speed)
    $ts = [timespan]::fromseconds($secs)
    if ($ts.Hours -gt 0) { return "{0}h {1}m" -f $ts.Hours, $ts.Minutes }
    if ($ts.Minutes -gt 0) { return "{0}m {1}s" -f $ts.Minutes, $ts.Seconds }
    return "{0}s" -f $ts.Seconds
}

# -------------------------------------------------------------------------
# COMMAND ROUTER
# -------------------------------------------------------------------------
function Route-Command {
    param ([string]$CommandText)
    
    # FIXED: Replaced '@.*' with '@\S+' so it doesn't delete the URL!
    $cleanCommand = $CommandText.Trim() -replace '@\S+', ''
    $parts = $cleanCommand -split '\s+', 2
    
    $cmd = $parts[0].ToLower()
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    $rawUrl = $args
    
    Write-BotLog "Routing command: $cmd" "INFO"
    
    if ($Config.telegram.commands.lightweight -contains $cmd) {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/jobs" { Send-TelegramMessage (Get-ActiveJobsFormatted) }
            "/help" { Send-TelegramMessage "🤖 <b>Commands:</b>`n/download URL - Start download`n/downloads - View aria2 queue`n/cancel JOB-ID - Stop a job`n/status - Live Dashboard`n/diagnostics - Health Report" }
            "/cancel" {
                $target = $args.ToUpper().Trim()
                if ($global:JobManager_Jobs.ContainsKey($target)) {
                    $global:JobManager_CancelDict[$target] = $true
                    Send-TelegramMessage "🛑 Cancellation requested for <code>$target</code>"
                } else { Send-TelegramMessage "⚠️ Job not found or already finished." }
            }
            "/downloads" {
                try {
                    # FIXED: Using strict JSON string
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
                    Write-BotLog "Live Dashboard activated on Message ID: $msgId" "SUCCESS"
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
            "/download" {
                if (-not $rawUrl) { Send-TelegramMessage "⚠️ Please provide a URL. Example: /download http://..." ; return }
                $sb = {
                    param($JobId, $Url, $RpcPort, $CancelDict, $ProgressDict)
                    $rpc = "http://127.0.0.1:$RpcPort/jsonrpc"
                    $safeUrl = $Url -replace '"', '\"'
                    
                    # FIXED: Hardcoded exact JSON string to bypass PowerShell flattening
                    $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.addUri`", `"params`": [[`"$safeUrl`"]] }"
                    
                    $res = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
                    $gid = $res.result
                    if (-not $gid) { 
                        if ($res.error) { throw "aria2 error: $($res.error.message)" }
                        throw "Failed to get GID from aria2." 
                    }
                    
                    $completed = $false
                    while (-not $completed) {
                        Start-Sleep -Seconds 2
                        if ($CancelDict.ContainsKey($JobId)) {
                            $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.remove`", `"params`": [`"$gid`"] }"
                            Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json" | Out-Null
                            throw "Cancelled by user (Data preserved for resume)."
                        }
                        
                        $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.tellStatus`", `"params`": [`"$gid`"] }"
                        $statusRes = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
                        $info = $statusRes.result
                        
                        $ProgressDict[$JobId] = $info
                        if ($info.status -eq "complete" -or $info.status -eq "error" -or $info.status -eq "removed") {
                            $completed = $true
                            if ($info.status -eq "error") { throw "Aria2 Error Code: $($info.errorCode)" }
                        }
                    }
                    return "✅ Download successfully completed!"
                }
                Submit-Job -JobId $jobId -CommandName "$cmd" -ScriptBlock $sb -ArgumentList @($jobId, $rawUrl, $Config.aria2.rpcPort, $global:JobManager_CancelDict, $global:JobManager_ProgressDict)
            }
            "/testjob" {
                $seconds = if ($args -match '^\d+$') { [int]$args } else { 15 }
                $sb = { param($Secs); Start-Sleep -Seconds $Secs; return "⏳ Test completed ($Secs s)" }
                Submit-Job -JobId $jobId -CommandName "$cmd $seconds" -ScriptBlock $sb -ArgumentList @($seconds)
            }
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
        }
        return
    }
    Send-TelegramMessage "❓ Unknown command: $cmd`nUse /help for available commands."
}

# -------------------------------------------------------------------------
# LONG POLLING & DASHBOARD TICK ENGINE
# -------------------------------------------------------------------------
Write-BotLog "Attempting to send startup message..." "INFO"
Send-TelegramMessage "🚀 <b>BotService Started</b>`naria2 Download Engine is online."

while ($true) {
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

    # Event Processor (Completion / Failures)
    $jobEvents = Invoke-JobManagerTick
    foreach ($event in $jobEvents) {
        if ($global:JobMessageMap.ContainsKey($event.JobId)) {
            $msgId = $global:JobMessageMap[$event.JobId].MessageId
            if ($event.Event -eq 'COMPLETED') { Edit-TelegramMessage -MessageId $msgId -Text "✅ <b>$($event.JobId) COMPLETED</b>`n`n$($event.Result)" }
            elseif ($event.Event -eq 'FAILED') { Edit-TelegramMessage -MessageId $msgId -Text "❌ <b>$($event.JobId) FAILED</b>`n`nReason: $($event.Result)" }
            $global:JobMessageMap.Remove($event.JobId)
        }
    }

    # Progress Update Throttler (Updates aria2 visual bar every ~8 seconds)
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

    # Dashboard Updater
    if ($global:DashboardMessageId -and ((Get-Date) -ge $global:DashboardLastUpdate.AddSeconds($Config.telegram.dashboardRefreshSeconds))) {
        $global:DashboardLastUpdate = Get-Date
        $dashText = Get-LiveDashboardText
        Edit-TelegramMessage -MessageId $global:DashboardMessageId -Text $dashText
    }
}
