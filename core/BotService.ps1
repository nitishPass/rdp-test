<#
.SYNOPSIS
    RDP Manager - BotService (Phase 10.8 - Clean UI Watchdog)
#>

$ErrorActionPreference = 'Continue'
$StartTime = Get-Date
$WorkspacePath = $env:WORKSPACE_ROOT
$LogFile = if ($WorkspacePath) { Join-Path $WorkspacePath "State\bot.log" } else { "C:\Users\Public\Desktop\bot_emergency.log" }

$BotToken = if ($env:TELEGRAM_BOT_TOKEN) { $env:TELEGRAM_BOT_TOKEN.Trim() } else { "" }
$AllowedChatId = if ($env:TELEGRAM_CHAT_ID) { $env:TELEGRAM_CHAT_ID.Trim() } else { "" }
$AdminUserId = if ($env:TELEGRAM_ADMIN_ID) { $env:TELEGRAM_ADMIN_ID.Trim() } else { "" }

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    if ($BotToken) { $Message = $Message.Replace($BotToken, "[REDACTED_TOKEN]") }
    if ($env:TAILSCALE_AUTH_KEY) { $Message = $Message.Replace($env:TAILSCALE_AUTH_KEY.Trim(), "[REDACTED_TS_KEY]") }
    $logEntry = "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry; Write-Host $logEntry
}

$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) { Write-BotLog "Missing credentials! Did secrets.json load properly?"; exit 1 }
$ApiUrl = "https://api.telegram.org/bot$BotToken"
$global:Offset = 0; $JobCounter = 1
$global:JobMessageMap = @{}
$global:ShutdownRequested = $false
$global:LastConsolePrint = Get-Date
$global:DeleteQueue = @{} 
$global:VFS_State = "UNMOUNTED"
$global:LastVFSCheck = Get-Date

. (Join-Path $PSScriptRoot "JobManager.ps1")
. (Join-Path $PSScriptRoot "RelayManager.ps1")
Initialize-JobManager

function New-SingleRowKeyboard {
    param([array]$Buttons)
    $r = New-Object System.Collections.ArrayList
    foreach ($b in $Buttons) { $r.Add($b) | Out-Null }
    $kb = New-Object System.Collections.ArrayList
    $kb.Add($r) | Out-Null
    return @{ inline_keyboard = $kb }
}

$HistoryFile = Join-Path $WorkspacePath "State\msg_history.json"
try {
    $global:MsgHistory = if (Test-Path $HistoryFile) { Get-Content $HistoryFile -Raw | ConvertFrom-Json } else { @() }
    if ($null -eq $global:MsgHistory) { $global:MsgHistory = @() }
} catch { $global:MsgHistory = @() }

if ($global:MsgHistory.Count -gt 0) {
    Write-BotLog "Executing Vanish Protocol: Deleting $($global:MsgHistory.Count) previous messages..." "INFO"
    foreach ($mId in $global:MsgHistory) {
        try {
            Invoke-RestMethod -Uri "$ApiUrl/deleteMessage" -Method Post -Body @{chat_id=$AllowedChatId; message_id=$mId} -ErrorAction Stop | Out-Null
        } catch { }
    }
}
$global:MsgHistory = @()
ConvertTo-Json -InputObject $global:MsgHistory -Compress | Out-File $HistoryFile -Encoding utf8

try {
    $flush = Invoke-RestMethod -Uri "$ApiUrl/getUpdates" -Method Get -TimeoutSec 15 -ErrorAction SilentlyContinue
    if ($flush.ok -and $flush.result.Count -gt 0) {
        $global:Offset = $flush.result[-1].update_id + 1
        Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$global:Offset" -Method Get -TimeoutSec 15 -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML", $ReplyMarkup = $null)
    try {
        $payload = @{ chat_id = $AllowedChatId; text = $Text }
        if ($ParseMode) { $payload["parse_mode"] = $ParseMode }
        if ($ReplyMarkup) { $payload["reply_markup"] = $ReplyMarkup }
        
        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
        $resp = Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $jsonBody -ContentType "application/json"
        
        $mId = $resp.result.message_id
        $global:MsgHistory += $mId
        ConvertTo-Json -InputObject $global:MsgHistory -Compress | Out-File $HistoryFile -Encoding utf8
        return $mId
    } catch { 
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails) { $errMsg += " | Telegram API: " + $_.ErrorDetails.Message }
        Write-BotLog "Telegram Send Error: $errMsg" "ERROR" 
    }
}

function Edit-TelegramMessage {
    param ([string]$MessageId, [string]$Text, [string]$ParseMode = "HTML", $ReplyMarkup = $null)
    try {
        $payload = @{ chat_id = $AllowedChatId; message_id = $MessageId; text = $Text }
        if ($ParseMode) { $payload["parse_mode"] = $ParseMode }
        if ($ReplyMarkup) { $payload["reply_markup"] = $ReplyMarkup }
        
        $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress
        Invoke-RestMethod -Uri "$ApiUrl/editMessageText" -Method Post -Body $jsonBody -ContentType "application/json" | Out-Null
    } catch { 
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails) { $errMsg += " | Telegram API: " + $_.ErrorDetails.Message }
        Write-BotLog "Telegram Edit Error: $errMsg" "ERROR" 
    }
}

function Get-LiveDashboardText {
    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
    $drvLet = if ($WorkspacePath) { $WorkspacePath.Substring(0,1) } else { "C" }
    $drv = Get-PSDrive -Name $drvLet
    $disk = [math]::Round($drv.Free / 1GB, 1)
    
    $uptime = (Get-Date) - $StartTime
    $upStr = "{0:00}h {1:00}m" -f $uptime.Hours, $uptime.Minutes
    $jStats = Get-JobManagerStats

    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    $tsStatus = if (Test-Path $tsPath) { "ONLINE" } else { "OFFLINE" }

    $out = "━━━━━━━━━━━━━━━━━━━━`n"
    $out += "      RDP STATUS`n"
    $out += "━━━━━━━━━━━━━━━━━━━━`n`n"
    $out += "🖥 CPU       $cpu%`n"
    $out += "🧠 RAM       $ram%`n"
    $out += "💾 DISK      $disk GB FREE`n"
    $out += "⏱ UPTIME    $upStr`n`n"
    $out += "🌐 TAILSCALE  $tsStatus`n"
    $out += "🖥 RDP        READY`n"
    $out += "📡 INTERNET   ONLINE`n`n"
    $out += "━━━━━━━━━━━━━━━━━━━━`n"
    $out += "        JOBS`n"
    $out += "━━━━━━━━━━━━━━━━━━━━`n`n"
    $out += "⚙️ Running    $($jStats.Running)`n"
    $out += "✅ Completed  $($jStats.Completed)`n"
    $out += "❌ Failed     $($jStats.Failed)"

    return $out
}

function Invoke-VFSWatchdog {
    $rcloneProc = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match "mount" -and $_.CommandLine -match "Z:" }

    if ($rcloneProc) {
        if ($global:VFS_State -ne "HEALTHY") {
            Write-BotLog "VFS Watchdog: Z:\ mount detected. State -> HEALTHY." "SUCCESS"
            $global:VFS_State = "HEALTHY"
        }
    } else {
        if ($global:VFS_State -eq "HEALTHY" -or $global:VFS_State -eq "DEGRADED") {
            $global:VFS_State = "DEGRADED"
            Write-BotLog "VFS Watchdog: Mount process lost! Attempting controlled recovery..." "WARN"

            Stop-Process -Name "rclone" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2

            # [FIX] VFS Watchdog natively executes the standard mount.vbs
            $mountVbs = "C:\Users\Public\Desktop\mount.vbs"
            if (Test-Path $mountVbs) {
                Start-Process "wscript.exe" -ArgumentList "`"$mountVbs`"" -WindowStyle Hidden
                Start-Sleep -Seconds 5

                $checkProc = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match "mount" -and $_.CommandLine -match "Z:" }
                if ($checkProc) {
                    $global:VFS_State = "HEALTHY"
                    Write-BotLog "VFS Watchdog: Recovery successful. State -> HEALTHY." "SUCCESS"
                } else {
                    $global:VFS_State = "FAILED"
                    Write-BotLog "VFS Watchdog: Recovery failed." "ERROR"
                    Send-TelegramMessage "⚠️ <b>VFS ALERT:</b> Z:\ CloudVault mount failed and could not be auto-recovered. Please check RDP." -ParseMode "HTML" | Out-Null
                }
            } else {
                $global:VFS_State = "FAILED"
            }
        }
    }
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
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." | Out-Null }
            "/help" { Send-TelegramMessage "🤖 <b>Commands:</b>`n/download URL - Start download`n/downloads - View queue`n/workspace - Cloud State`n/backup - Force Cloud Sync`n/relay - Hand off to next runner`n/cancel JOB-ID - Stop task`n/status - View Dashboard`n/stop - Terminate workflow`n/rdp - Connection Info" -ParseMode "HTML" | Out-Null }
            "/cancel" {
                $target = $args.ToUpper().Trim()
                if (-not $target) {
                    Send-TelegramMessage "⚠️ Provide a Job ID (e.g., `/cancel JOB-001` or `/cancel GID-xxxx`)." | Out-Null
                    break
                }
                $global:JobManager_CancelDict[$target] = $true
                
                if ($target -match "^GID-(.+)") {
                    $gid = $matches[1]
                    $rpc = "http://127.0.0.1:$($Config.aria2.rpcPort)/jsonrpc"
                    $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.remove`", `"params`": [`"$gid`"] }"
                    Invoke-RestMethod -Uri $rpc -Method Post -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
                }
                Send-TelegramMessage "🛑 Cancellation requested for <code>$target</code>" -ParseMode "HTML" | Out-Null
            }
            "/stop" {
                Send-TelegramMessage "🛑 <b>WORKFLOW TERMINATED</b>`nThe GitHub Actions runner is shutting down immediately." -ParseMode "HTML" | Out-Null
                Write-BotLog "User requested immediate shutdown via /stop." "WARN"
                try { Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$global:Offset" -Method Get -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null } catch {}
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
                    $msg += "<i>Z: Drive & Workspace scripts will auto-launch when you log in!</i>"
                    
                    $mId = Send-TelegramMessage $msg -ParseMode "HTML"
                    if ($mId) { $global:DeleteQueue[$mId] = (Get-Date).AddSeconds(60) }
                } else {
                    Send-TelegramMessage "⚠️ <b>Error:</b> Tailscale VPN is not running or IP could not be retrieved." -ParseMode "HTML" | Out-Null
                }
            }
            "/workspace" {
                $drvLet = $WorkspacePath.Substring(0,1)
                $size = Format-Bytes ((Get-ChildItem $WorkspacePath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
                $rcloneStat = if (Test-Path "$WorkspacePath\rclone.exe") { "🟢 CONFIGURED" } else { "🔴 MISSING" }
                Send-TelegramMessage "☁️ <b>WORKSPACE STATE</b>`n━━━━━━━━━━━━━━━━━━━━`nPath: <code>$WorkspacePath</code>`nLocal Size: $size`nRclone: $rcloneStat`n`n<i>Use /backup to sync to CloudVault.</i>" -ParseMode "HTML" | Out-Null
            }
            "/downloads" {
                try {
                    $body = "{ `"jsonrpc`": `"2.0`", `"id`": `"1`", `"method`": `"aria2.tellActive`" }"
                    $res = Invoke-RestMethod -Uri "http://127.0.0.1:$($Config.aria2.rpcPort)/jsonrpc" -Method Post -Body $body -ContentType "application/json"
                    if ($res.result.Count -eq 0) { Send-TelegramMessage "📥 <b>DOWNLOADS</b>`nNo active downloads." -ParseMode "HTML" | Out-Null; return }
                    
                    foreach ($d in $res.result) {
                        $info = $d; $info | Add-Member -MemberType NoteProperty -Name "jobType" -Value "download" -Force
                        $jId = "GID-$($d.gid)"
                        $global:JobManager_ProgressDict[$jId] = $info
                        
                        $markup = New-SingleRowKeyboard -Buttons @(
                            @{ text="🔄 Refresh"; callback_data="refresh_$jId" },
                            @{ text="🛑 Cancel"; callback_data="cancel_$jId" }
                        )
                        Send-TelegramMessage (Generate-JobUI -jId $jId -info $info) -ParseMode "HTML" -ReplyMarkup $markup | Out-Null
                    }
                } catch { Send-TelegramMessage "⚠️ Cannot reach aria2 engine." | Out-Null }
            }
            "/status" {
                $markup = New-SingleRowKeyboard -Buttons @( @{ text="🔄 Refresh Dashboard"; callback_data="refresh_dash" } )
                Send-TelegramMessage (Get-LiveDashboardText) -ParseMode "" -ReplyMarkup $markup | Out-Null
            }
        }
        return
    }

    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        
        $markup = New-SingleRowKeyboard -Buttons @(
            @{ text="🔄 Refresh"; callback_data="refresh_$jobId" },
            @{ text="🛑 Cancel"; callback_data="cancel_$jobId" }
        )
        
        $msgId = Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd" -ParseMode "HTML" -ReplyMarkup $markup
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

$tsPath = "C:\Program Files\Tailscale\tailscale.exe"
$tsIp = if (Test-Path $tsPath) { (& $tsPath ip -4 2>$null).Trim() } else { "OFFLINE" }

$bootMsg = "🚀 <b>SYSTEM ONLINE & READY</b>`n━━━━━━━━━━━━━━━━━━━━`n"
$bootMsg += "🌐 <b>IP:</b> <code>$tsIp</code>`n"
$bootMsg += "👤 <b>User:</b> <code>$env:RDP_USERNAME</code>`n"
$bootMsg += "☁️ <b>CloudVault:</b> <code>Auto-Mounting (Z:)</code>`n`n"
$bootMsg += "<i>System has successfully initialized. Type /help to view commands.</i>"
Send-TelegramMessage $bootMsg -ParseMode "HTML" | Out-Null
Write-BotLog "=== BOT SERVICE (PHASE 10.8) INITIALIZED ===" "INFO"

while (-not $global:ShutdownRequested) {
    try {
        $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$global:Offset&timeout=5" -Method Get -TimeoutSec 15
        if ($updates.ok -and $updates.result.Count -gt 0) {
            foreach ($update in $updates.result) {
                $global:Offset = $update.update_id + 1
                
                if ($update.callback_query) {
                    $cb = $update.callback_query
                    $cbData = $cb.data
                    $mId = $cb.message.message_id
                    
                    Invoke-RestMethod -Uri "$ApiUrl/answerCallbackQuery" -Method Post -Body @{callback_query_id=$cb.id} -ErrorAction SilentlyContinue | Out-Null
                    
                    if ($cbData -eq "refresh_dash") {
                        $markup = New-SingleRowKeyboard -Buttons @( @{ text="🔄 Refresh Dashboard"; callback_data="refresh_dash" } )
                        Edit-TelegramMessage -MessageId $mId -Text (Get-LiveDashboardText) -ParseMode "" -ReplyMarkup $markup
                    }
                    elseif ($cbData -match "^refresh_(.+)") {
                        $jId = $matches[1]
                        if ($global:JobManager_ProgressDict.ContainsKey($jId)) {
                            $info = $global:JobManager_ProgressDict[$jId]
                            $markup = New-SingleRowKeyboard -Buttons @(
                                @{ text="🔄 Refresh"; callback_data="refresh_$jId" },
                                @{ text="🛑 Cancel"; callback_data="cancel_$jId" }
                            )
                            
                            if ($info.type -eq "sys") {
                                $pct = $info.pct
                                $progBar = Get-ProgressBar -Percent $pct
                                $text = "⚙️ <b>$jId</b>`n━━━━━━━━━━━━━━━━━━━━`n$progBar $pct%`nStatus: $($info.msg)"
                                Edit-TelegramMessage -MessageId $mId -Text $text -ParseMode "HTML" -ReplyMarkup $markup
                            } else {
                                Edit-TelegramMessage -MessageId $mId -Text (Generate-JobUI -jId $jId -info $info) -ParseMode "HTML" -ReplyMarkup $markup
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
                        
                        Edit-TelegramMessage -MessageId $mId -Text "🛑 Cancellation requested for <code>$jId</code>..." -ParseMode "HTML"
                    }
                    continue
                }

                $msg = $update.message
                if (-not $msg.text) { continue }
                if ([string]$msg.chat.id -ne $AllowedChatId -or [string]$msg.from.id -ne $AdminUserId) { continue }
                
                $global:MsgHistory += $msg.message_id
                ConvertTo-Json -InputObject $global:MsgHistory -Compress | Out-File $HistoryFile -Encoding utf8
                
                Route-Command -Command $msg.text
            }
        }
    } catch { 
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails) { $errMsg += " | " + $_.ErrorDetails.Message }
        Write-BotLog "API Polling Error: $errMsg" "WARN"
        Start-Sleep -Seconds 2
    }

    $jobEvents = Invoke-JobManagerTick
    foreach ($event in $jobEvents) {
        if ($global:JobMessageMap.ContainsKey($event.JobId)) {
            $msgId = $global:JobMessageMap[$event.JobId].MessageId
            if ($event.Event -eq 'COMPLETED') { 
                Edit-TelegramMessage -MessageId $msgId -Text "✅ <b>$($event.JobId) COMPLETED</b>`n`n$($event.Result)" -ParseMode "HTML"
                if ($event.Command -eq '/relay') { 
                    Start-Sleep -Seconds 10
                    $global:ShutdownRequested = $true 
                }
            }
            elseif ($event.Event -eq 'FAILED') { Edit-TelegramMessage -MessageId $msgId -Text "❌ <b>$($event.JobId) FAILED</b>`n`nReason: $($event.Result)" -ParseMode "HTML"}
            $global:JobMessageMap.Remove($event.JobId)
        }
    }

    if ((Get-Date) -ge $global:LastVFSCheck.AddSeconds(15)) {
        Invoke-VFSWatchdog
        $global:LastVFSCheck = Get-Date
    }

    $now = Get-Date
    foreach ($dId in @($global:DeleteQueue.Keys)) {
        if ($now -ge $global:DeleteQueue[$dId]) {
            try { Invoke-RestMethod -Uri "$ApiUrl/deleteMessage" -Method Post -Body @{chat_id=$AllowedChatId; message_id=$dId} -ErrorAction Stop | Out-Null } catch {}
            $global:DeleteQueue.Remove($dId)
        }
    }

    foreach ($jId in @($global:JobManager_ProgressDict.Keys)) {
        if ($global:JobMessageMap.ContainsKey($jId)) {
            $msgData = $global:JobMessageMap[$jId]
            if ((Get-Date) -ge $msgData.LastUpdate.AddSeconds(5)) {
                $info = $global:JobManager_ProgressDict[$jId]
                if ($info) {
                    $markup = New-SingleRowKeyboard -Buttons @(
                        @{ text="🔄 Refresh"; callback_data="refresh_$jId" },
                        @{ text="🛑 Cancel"; callback_data="cancel_$jId" }
                    )
                    
                    if ($info.type -eq "sys") {
                        $pct = $info.pct
                        $progBar = Get-ProgressBar -Percent $pct
                        $text = "⚙️ <b>$jId</b>`n━━━━━━━━━━━━━━━━━━━━`n$progBar $pct%`nStatus: $($info.msg)"
                        Edit-TelegramMessage -MessageId $msgData.MessageId -Text $text -ParseMode "HTML" -ReplyMarkup $markup
                    } else {
                        Edit-TelegramMessage -MessageId $msgData.MessageId -Text (Generate-JobUI -jId $jId -info $info) -ParseMode "HTML" -ReplyMarkup $markup
                    }
                    $msgData.LastUpdate = Get-Date
                }
            }
        }
    }

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
        Send-TelegramMessage "⚠️ <b>RUNNER TIME LIMIT APPROACHING (340 MINS)</b>`nTriggering automatic workspace relay..." -ParseMode "HTML"
        Route-Command -Command "/relay"
        $StartTime = (Get-Date).AddDays(1) 
    }
}

Write-BotLog "Shutdown requested. Exiting BotService safely." "SUCCESS"
exit 0
