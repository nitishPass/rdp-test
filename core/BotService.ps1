<#
.SYNOPSIS
    RDP Manager - BotService (Phase 8.3 - Concurrency & JSON UI Fix)
#>

$ErrorActionPreference = 'Continue'
$StartTime = Get-Date
$WorkspacePath = $env:WORKSPACE_ROOT
$LogFile = if ($WorkspacePath) { Join-Path $WorkspacePath "State\bot.log" } else { "C:\Users\Public\Desktop\bot_emergency.log" }

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    if ($env:TELEGRAM_BOT_TOKEN) { $Message = $Message.Replace($env:TELEGRAM_BOT_TOKEN, "[REDACTED_TOKEN]") }
    if ($env:TAILSCALE_AUTH_KEY) { $Message = $Message.Replace($env:TAILSCALE_AUTH_KEY, "[REDACTED_TS_KEY]") }
    $logEntry = "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry; Write-Host $logEntry
}

Write-BotLog "=== BOT SERVICE (PHASE 8.3) STARTED ===" "INFO"
$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) { Write-BotLog "Missing credentials!"; exit 1 }
$ApiUrl = "https://api.telegram.org/bot$BotToken"
$global:Offset = 0; $JobCounter = 1
$global:JobMessageMap = @{}
$global:ShutdownRequested = $false
$global:LastConsolePrint = Get-Date

. (Join-Path $PSScriptRoot "JobManager.ps1")
. (Join-Path $PSScriptRoot "RelayManager.ps1")
Initialize-JobManager

$HistoryFile = Join-Path $WorkspacePath "State\msg_history.json"
$global:MsgHistory = if (Test-Path $HistoryFile) { Get-Content $HistoryFile -Raw | ConvertFrom-Json } else { @() }

if ($global:MsgHistory.Count -gt 0) {
    Write-BotLog "Executing Vanish Protocol: Deleting $($global:MsgHistory.Count) previous messages..." "INFO"
    foreach ($mId in $global:MsgHistory) {
        Invoke-RestMethod -Uri "$ApiUrl/deleteMessage" -Method Post -Body @{chat_id=$AllowedChatId; message_id=$mId} -ErrorAction SilentlyContinue | Out-Null
    }
}
$global:MsgHistory = @()
$global:MsgHistory | ConvertTo-Json -Compress | Out-File $HistoryFile -Encoding utf8

try {
    $flush = Invoke-RestMethod -Uri "$ApiUrl/getUpdates" -Method Get -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($flush.ok -and $flush.result.Count -gt 0) {
        $global:Offset = $flush.result[-1].update_id + 1
        Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$global:Offset" -Method Get -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

# [FIX 2] Explicitly convert payloads to JSON string and set ContentType!
function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML", $ReplyMarkup = $null)
    try {
        $payload = @{ chat_id = $AllowedChatId; text = $Text; parse_mode = $ParseMode }
        if ($ReplyMarkup) { $payload["reply_markup"] = $ReplyMarkup }
        
        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
        $resp = Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $jsonBody -ContentType "application/json"
        
        $mId = $resp.result.message_id
        $global:MsgHistory += $mId
        $global:MsgHistory | ConvertTo-Json -Compress | Out-File $HistoryFile -Encoding utf8
        return $mId
    } catch { Write-BotLog "Telegram Send Error: $($_.Exception.Message)" "ERROR" }
}

function Edit-TelegramMessage {
    param ([string]$MessageId, [string]$Text, [string]$ParseMode = "HTML", $ReplyMarkup = $null)
    try {
        $payload = @{ chat_id = $AllowedChatId; message_id = $MessageId; text = $Text; parse_mode = $ParseMode }
        if ($ReplyMarkup) { $payload["reply_markup"] = $ReplyMarkup }
        
        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
        Invoke-RestMethod -Uri "$ApiUrl/editMessageText" -Method Post -Body $jsonBody -ContentType "application/json" | Out-Null
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

function Generate-JobUI {
    param([string]$jId, $info)
    $total = [double]$info.totalLength; $done = [double]$info.completedLength; $speed = [double]$info.downloadSpeed
    $pct = if ($total -gt 0) { [math]::Round(($done / $total) * 100, 1) } else { 0 }
    $progBar = Get-ProgressBar -Percent $pct
    $doneStr = Format-Bytes -Bytes $done; $totalStr = Format-Bytes -Bytes $total
    $spdStr = Format-Bytes -Bytes $speed
    $etaStr = Format-ETA -Speed $speed -Remaining ($total - $done)
    return "📥 <b>$jId</b>`n━━━━━━━━━━━━━━━━━━━━`n$progBar $pct%`n$doneStr / $totalStr`nSpeed: $spdStr/s`nETA: $etaStr`nStatus: $($info.status.ToUpper())"
}

function Route-Command {
    param ([string]$CommandText)
    $cleanCommand = $CommandText.Trim() -replace '@\S+', ''
    $parts = $cleanCommand -split '\s+', 2
    $cmd = $parts[0].ToLower()
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    if ($Config.telegram.commands.lightweight -contains $cmd -or $cmd -eq "/stop" -or $cmd -eq "/rdp") {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/help" { Send-TelegramMessage "🤖 <b>Commands:</b>`n/download URL - Start download`n/downloads - View queue`n/workspace - Cloud State`n/backup - Force Cloud Sync`n/relay - Hand off to next runner`n/stop - Terminate workflow`n/rdp - Connection Info" }
            "/stop" {
                Send-TelegramMessage "🛑 <b>WORKFLOW TERMINATED</b>`nThe GitHub Actions runner is shutting down immediately."
                Write-BotLog "User requested immediate shutdown via /stop." "WARN"
                try { Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$global:Offset" -Method Get -ErrorAction SilentlyContinue | Out-Null } catch {}
                exit 0
            }
            "/rdp" {
                $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
                $tsIp = if (Test-Path $tsPath) { (& $tsPath ip -4 2>$null).Trim() } else { $null }
                
                if ($tsIp) {
                    $msg = "🖥️ <b>RDP CONNECTION INFO (Self-Destruct in 60s)</b>`n━━━━━━━━━━━━━━━━━━━━`n"
                    $msg += "🟢 <b>Status:</b> SECURE VPN ONLINE`n"
                    $msg += "🌐 <b>IP Address:</b> <code>$tsIp</code>`n"
                    $msg += "👤 <b>User:</b> <code>$env:RDP_USERNAME</code>`n"
                    $msg += "🔑 <b>Pass:</b> <code>$env:RDP_PASSWORD</code>`n`n"
                    $msg += "<i>Double-click 'Mount_CloudVault.bat' on the desktop to access Z:!</i>"
                    
                    $mId = Send-TelegramMessage $msg
                    
                    if ($mId) {
                        $sb = {
                            param($mId, $cId, $botToken)
                            Start-Sleep -Seconds 60
                            Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/deleteMessage" -Method Post -Body @{chat_id=$cId; message_id=$mId} -ErrorAction SilentlyContinue
                        }
                        Start-ThreadJob -ScriptBlock $sb -ArgumentList @($mId, $AllowedChatId, $BotToken) | Out-Null
                    }
                } else {
                    Send-TelegramMessage "⚠️ <b>Error:</b> Tailscale VPN is not running or IP could not be retrieved."
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
                    
                    foreach ($d in $res.result) {
                        $info = $d; $info | Add-Member -MemberType NoteProperty -Name "jobType" -Value "download" -Force
                        $jId = "GID-$($d.gid)"
                        $global:JobManager_ProgressDict[$jId] = $info
                        
                        $markup = @{ inline_keyboard = @( @( 
                            @{ text="🔄 Refresh"; callback_data="refresh_$jId" },
                            @{ text="🛑 Cancel"; callback_data="cancel_$jId" }
                        ) ) }
                        
                        Send-TelegramMessage (Generate-JobUI -jId $jId -info $info) -ReplyMarkup $markup | Out-Null
                    }
                } catch { Send-TelegramMessage "⚠️ Cannot reach aria2 engine." }
            }
            "/status" {
                $markup = @{ inline_keyboard = @( @( @{ text="🔄 Refresh Dashboard"; callback_data="refresh_dash" } ) ) }
                Send-TelegramMessage (Get-LiveDashboardText) -ReplyMarkup $markup | Out-Null
            }
        }
        return
    }

    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        
        $markup = @{ inline_keyboard = @( @( 
            @{ text="🔄 Refresh"; callback_data="refresh_$jobId" },
            @{ text="🛑 Cancel"; callback_data="cancel_$jobId" }
        ) ) }
        
        $msgId = Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd" -ReplyMarkup $markup
        if ($msgId) { $global:JobMessageMap[$jobId] = @{ MessageId = $msgId; LastUpdate = Get-Date; LastConsoleMsg = "" } }
        
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
                    
                    $unpauseBody = "{ `"jsonrpc`": `"2.0`", `"id`": `"2`", `"method`": `"aria2.unpauseAll`" }"
                    Invoke-RestMethod -Uri $rpc -Method Post -Body $unpauseBody -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
                    
                    $completed = $false
                    while (-not $completed) {
                        Start-Sleep -Seconds 1
                        if ($CancelDict.ContainsKey($JobId)) {
                            $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.remove`", `"params`": [`"$gid`"] }"
                            Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json" | Out-Null
                            throw "Cancelled by user."
                        }
                        $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.tellStatus`", `"params`": [`"$gid`"] }"
                        $statusRes = Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json"
                        $info = $statusRes.result
                        $info | Add-Member -MemberType NoteProperty -Name "jobType" -Value "download" -Force
                        $ProgressDict[$JobId] = $info
                        
                        if ($info.status -eq "complete" -or $info.status -eq "error" -or $info.status -eq "removed" -or $info.status -eq "paused") {
                            $completed = $true
                            if ($info.status -eq "error") { throw "Aria2 Error: $($info.errorCode)" }
                            if ($info.status -eq "paused") { return "⏸️ Download paused safely for Workspace Relay." }
                        }
                    }
                    return "✅ Download successfully completed!"
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($jobId, $args, $Config.aria2.rpcPort, $global:JobManager_CancelDict, $global:JobManager_ProgressDict)
            }
            "/backup" {
                $sb = {
                    param($JobId, $WsPath, $CloudName, $RootName, $CorePath, $RpcPort, $ProgDict)
                    . (Join-Path $CorePath "RelayManager.ps1")
                    return Sync-CloudWorkspace -WsPath $WsPath -CloudName $CloudName -RootName $RootName -RpcPort $RpcPort -JobId $JobId -ProgDict $ProgDict
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($jobId, $WorkspacePath, $Config.relay.cloudDriveName, $Config.storage.workspaceRootName, $PSScriptRoot, $Config.aria2.rpcPort, $global:JobManager_ProgressDict)
            }
            "/relay" {
                $sb = {
                    param($JobId, $WsPath, $CloudName, $RootName, $Repo, $Token, $CorePath, $RpcPort, $ProgDict)
                    . (Join-Path $CorePath "RelayManager.ps1")
                    $syncRes = Sync-CloudWorkspace -WsPath $WsPath -CloudName $CloudName -RootName $RootName -RpcPort $RpcPort -JobId $JobId -ProgDict $ProgDict
                    $relayRes = Invoke-RunnerRelay -Repo $Repo -Token $Token -JobId $JobId -ProgDict $ProgDict
                    return "$syncRes`n$relayRes`n`n⚠️ Shutting down current runner in 10 seconds to allow handoff."
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($jobId, $WorkspacePath, $Config.relay.cloudDriveName, $Config.storage.workspaceRootName, $env:GITHUB_REPO, $env:GH_TOKEN, $PSScriptRoot, $Config.aria2.rpcPort, $global:JobManager_ProgressDict)
            }
        }
    }
}

Send-TelegramMessage "🚀 <b>BotService Started</b>`nReady for commands." | Out-Null

while (-not $global:ShutdownRequested) {
    try {
        $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$global:Offset&timeout=1" -Method Get -TimeoutSec 3
        if ($updates.ok -and $updates.result.Count -gt 0) {
            foreach ($update in $updates.result) {
                $global:Offset = $update.update_id + 1
                
                if ($update.callback_query) {
                    $cb = $update.callback_query
                    $cbData = $cb.data
                    $mId = $cb.message.message_id
                    
                    Invoke-RestMethod -Uri "$ApiUrl/answerCallbackQuery" -Method Post -Body @{callback_query_id=$cb.id} -ErrorAction SilentlyContinue | Out-Null
                    
                    if ($cbData -eq "refresh_dash") {
                        $markup = @{ inline_keyboard = @( @( @{ text="🔄 Refresh Dashboard"; callback_data="refresh_dash" } ) ) }
                        Edit-TelegramMessage -MessageId $mId -Text (Get-LiveDashboardText) -ReplyMarkup $markup
                    }
                    elseif ($cbData -match "^refresh_(.+)") {
                        $jId = $matches[1]
                        if ($global:JobManager_ProgressDict.ContainsKey($jId)) {
                            $info = $global:JobManager_ProgressDict[$jId]
                            $markup = @{ inline_keyboard = @( @( 
                                @{ text="🔄 Refresh"; callback_data="refresh_$jId" },
                                @{ text="🛑 Cancel"; callback_data="cancel_$jId" }
                            ) ) }
                            
                            if ($info.type -eq "sys") {
                                $pct = $info.pct
                                $progBar = Get-ProgressBar -Percent $pct
                                $text = "⚙️ <b>$jId</b>`n━━━━━━━━━━━━━━━━━━━━`n$progBar $pct%`nStatus: $($info.msg)"
                                Edit-TelegramMessage -MessageId $mId -Text $text -ReplyMarkup $markup
                            } else {
                                Edit-TelegramMessage -MessageId $mId -Text (Generate-JobUI -jId $jId -info $info) -ReplyMarkup $markup
                            }
                        }
                    }
                    elseif ($cbData -match "^cancel_(.+)") {
                        $jId = $matches[1]
                        $global:JobManager_CancelDict[$jId] = $true
                        
                        if ($jId -match "^GID-(.+)") {
                            $gid = $matches[1]
                            $rpc = "http://127.0.0.1:$($Config.aria2.rpcPort)/jsonrpc"
                            $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.remove`", `"params`": [`"$gid`"] }"
                            Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json" | Out-Null
                        }
                        
                        Edit-TelegramMessage -MessageId $mId -Text "🛑 Cancellation requested for <code>$jId</code>..."
                    }
                    continue
                }

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

    # [FIX 1] Snapshot the keys into an array `@()` before looping to prevent background thread concurrency crashes!
    if ((Get-Date) -ge $global:LastConsolePrint.AddSeconds(10)) {
        foreach ($jId in @($global:JobManager_ProgressDict.Keys)) {
            $info = $global:JobManager_ProgressDict[$jId]
            if ($info.type -eq "sys") {
                Write-BotLog "[$jId] SYS Progress: $($info.pct)% - $($info.msg)" "INFO"
            } elseif ($info.jobType -eq "download") {
                $total = [double]$info.totalLength; $done = [double]$info.completedLength; $speed = [double]$info.downloadSpeed
                $pct = if ($total -gt 0) { [math]::Round(($done / $total) * 100, 1) } else { 0 }
                $spdStr = Format-Bytes -Bytes $speed
                Write-BotLog "[$jId] DL Progress: $pct% | Speed: $spdStr/s" "INFO"
            }
        }
        $global:LastConsolePrint = Get-Date
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
