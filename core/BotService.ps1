<#
.SYNOPSIS
    RDP Manager - BotService (Phase 4)
.DESCRIPTION
    Control Plane for Telegram. Features Live Dashboard and Async Diagnostics.
#>

$ErrorActionPreference = 'Continue'
$StartTime = Get-Date

$WorkspacePath = $env:WORKSPACE_ROOT
$LogFile = if ($WorkspacePath) { Join-Path $WorkspacePath "State\bot.log" } else { "C:\Users\Public\Desktop\bot_emergency.log" }

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    if ($env:TELEGRAM_BOT_TOKEN) { $Message = $Message.Replace($env:TELEGRAM_BOT_TOKEN, "[REDACTED_TOKEN]") }
    $logEntry = "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry
    Write-Host $logEntry
}

Write-BotLog "=== BOT SERVICE (PHASE 4) STARTED ===" "INFO"

$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) { 
    Write-BotLog "CRITICAL ERROR: Missing Telegram credentials!" "ERROR"; exit 1 
}

$ApiUrl = "https://api.telegram.org/bot$BotToken"
$Offset = 0
$JobCounter = 1

# Dashboard State Variables
$global:DashboardMessageId = $null
$global:DashboardLastUpdate = [DateTime]::MinValue

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
    } catch {
        # Ignore 400 errors (usually means "message is not modified")
    }
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

    $out = "┌─────────────────────────────┐`n"
    $out += "│ 🖥️ <b>RDP MANAGER DASHBOARD</b>`n"
    $out += "│ ───────────────────────────`n"
    $out += "│ 🟢 SYSTEM ONLINE`n│`n"
    $out += "│ CPU  $cpu%`n"
    $out += "│ RAM  $ram%`n"
    $out += "│ DISK $disk% (${drvLet}:)`n│`n"
    $out += "│ Jobs: $($jStats.Running) RUNNING`n"
    $out += "│ Uptime: $upStr`n"
    $out += "│ Updated: $((Get-Date).ToString('HH:mm:ss'))`n"
    $out += "└─────────────────────────────┘"
    return $out
}

# -------------------------------------------------------------------------
# COMMAND ROUTER
# -------------------------------------------------------------------------
function Route-Command {
    param ([string]$CommandText)
    
    $parts = ($CommandText.ToLower().Trim() -replace '@.*', '') -split '\s+', 2
    $cmd = $parts[0]
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    Write-BotLog "Routing command: $cmd" "INFO"
    
    # --- LIGHTWEIGHT COMMANDS ---
    if ($Config.telegram.commands.lightweight -contains $cmd) {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/jobs" { Send-TelegramMessage (Get-ActiveJobsFormatted) }
            "/help" { Send-TelegramMessage "🤖 <b>Commands:</b>`n/status - Live Dashboard`n/diagnostics - Full Health Report`n/jobs - Active Jobs`n/ping - Connection test" }
            "/status" {
                $text = Get-LiveDashboardText
                $msgId = Send-TelegramMessage $text
                if ($msgId) {
                    $global:DashboardMessageId = $msgId
                    $global:DashboardLastUpdate = Get-Date
                    Write-BotLog "Live Dashboard activated on Message ID: $msgId" "SUCCESS"
                }
            }
        }
        return
    }

    # --- JOB COMMANDS ---
    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        
        Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd"
        
        switch ($cmd) {
            "/testjob" {
                $seconds = if ($args -match '^\d+$') { [int]$args } else { 15 }
                $sb = { param($Secs); Start-Sleep -Seconds $Secs; return "⏳ Test completed ($Secs s)" }
                # FIXED: Passed as strict ordered Array
                Submit-Job -JobId $jobId -CommandName "$cmd $seconds" -ScriptBlock $sb -ArgumentList @($seconds)
            }
            "/diagnostics" {
                $sb = {
                    param($WsPath, $JobStats)
                    
                    # 1. SYSTEM
                    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
                    $os = Get-CimInstance Win32_OperatingSystem
                    $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
                    
                    # 2. STORAGE
                    $drvLet = if ($WsPath) { $WsPath.Substring(0,1) } else { "C" }
                    $drv = Get-PSDrive -Name $drvLet
                    $freeGb = [math]::Round($drv.Free / 1GB, 1)
                    $statusStorage = if ($freeGb -gt 5) { "🟢" } else { "🔴" }
                    
                    # 3. NETWORK / INTERNET / DNS
                    $netStatus = "🟢"
                    $latency = "N/A"
                    try {
                        $ping = Test-NetConnection -ComputerName "api.telegram.org" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
                        if (-not $ping) { $netStatus = "🔴" } else { $latency = "OK" }
                    } catch { $netStatus = "🔴" }

                    # 4. RDP
                    $rdpSvc = (Get-Service TermService -ErrorAction SilentlyContinue).Status
                    $rdpStatus = if ($rdpSvc -eq 'Running') { "🟢" } else { "🔴" }
                    
                    # 5. TAILSCALE
                    $tsSvc = (Get-Service Tailscale -ErrorAction SilentlyContinue).Status
                    $tsStatus = if ($tsSvc -eq 'Running') { "🟢 CONNECTED" } else { "🔴 OFFLINE" }

                    # FORMATTING THE REPORT
                    $report = "🚀 <b>RDP MANAGER DIAGNOSTICS</b>`n━━━━━━━━━━━━━━━━━━━━`n"
                    $report += "🖥️ <b>SYSTEM</b>`nCPU: $cpu% | RAM: $ram%`n"
                    $report += "`n💾 <b>WORKSPACE (${drvLet}:)</b>`nFree Space: $freeGb GB $statusStorage`nPath: <code>$WsPath</code>`n"
                    $report += "`n🌐 <b>NETWORK & API</b>`nInternet/DNS: $netStatus`n"
                    $report += "`n🔗 <b>TAILSCALE</b>`nStatus: $tsStatus`n"
                    $report += "`n🖥️ <b>RDP SERVICE</b>`nTermService: $rdpStatus`n"
                    $report += "`n⚙️ <b>JOB ENGINE</b>`nWorkers: $($JobStats.Workers)`nRunning: $($JobStats.Running)`nCompleted: $($JobStats.Completed)`nFailed: $($JobStats.Failed)`n"
                    $report += "━━━━━━━━━━━━━━━━━━━━`n"
                    
                    if ($statusStorage -eq "🔴" -or $netStatus -eq "🔴" -or $rdpStatus -eq "🔴") {
                        $report += "⚠️ <b>WARNING: SOME CHECKS FAILED</b>"
                    } else {
                        $report += "🟢 <b>ALL SYSTEMS HEALTHY</b>"
                    }
                    
                    return $report
                }
                
                $stats = Get-JobManagerStats
                # FIXED: Passed explicitly ordered variables to avoid Hashtable positional shuffle
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -ArgumentList @($WorkspacePath, $stats)
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
Send-TelegramMessage "🚀 <b>BotService Started</b>`nLive Dashboard & Diagnostics online."

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

    $jobEvents = Invoke-JobManagerTick
    foreach ($event in $jobEvents) {
        if ($event.Event -eq 'COMPLETED') {
            Write-BotLog "Job $($event.JobId) Completed." "SUCCESS"
            Send-TelegramMessage "✅ Job <code>$($event.JobId)</code> completed.`n`n$($event.Result)"
        } elseif ($event.Event -eq 'FAILED') {
            Write-BotLog "Job $($event.JobId) FAILED: $($event.Result)" "ERROR"
            Send-TelegramMessage "❌ Job <code>$($event.JobId)</code> FAILED.`nCommand: $($event.Command)`nReason: $($event.Result)"
        }
    }

    if ($global:DashboardMessageId -and ((Get-Date) -ge $global:DashboardLastUpdate.AddSeconds($Config.telegram.dashboardRefreshSeconds))) {
        $global:DashboardLastUpdate = Get-Date
        $dashText = Get-LiveDashboardText
        Edit-TelegramMessage -MessageId $global:DashboardMessageId -Text $dashText
    }
}
