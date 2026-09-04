<#
.SYNOPSIS
    RDP Manager - BotService (Phase 3)
.DESCRIPTION
    Control Plane for Telegram. Polls updates, routes commands, delegates heavy 
    work to JobManager, and consumes async completion events.
#>

$ErrorActionPreference = 'Continue'

$WorkspacePath = $env:WORKSPACE_ROOT
$LogFile = if ($WorkspacePath) { Join-Path $WorkspacePath "State\bot.log" } else { "C:\Users\Public\Desktop\bot_emergency.log" }

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    if ($env:TELEGRAM_BOT_TOKEN) { $Message = $Message.Replace($env:TELEGRAM_BOT_TOKEN, "[REDACTED_TOKEN]") }
    $logEntry = "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry
    Write-Host $logEntry
}

Write-BotLog "=== BOT SERVICE (PHASE 3) STARTED ===" "INFO"

# -------------------------------------------------------------------------
# 1. INITIALIZATION & SECURITY
# -------------------------------------------------------------------------
$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) { 
    Write-BotLog "CRITICAL ERROR: Missing Telegram credentials in environment!" "ERROR"
    exit 1 
}

$ApiUrl = "https://api.telegram.org/bot$BotToken"
$Offset = 0
$JobCounter = 1

Write-BotLog "Secrets verified. Allowed Chat: $AllowedChatId | Admin: $AdminUserId" "SUCCESS"

# -------------------------------------------------------------------------
# 2. INITIALIZE ASYNC JOB MANAGER
# -------------------------------------------------------------------------
# We dot-source the JobManager module so BotService can access its functions
. (Join-Path $PSScriptRoot "JobManager.ps1")
Initialize-JobManager

# -------------------------------------------------------------------------
# 3. HELPER FUNCTIONS
# -------------------------------------------------------------------------
function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML")
    try {
        $payload = @{ chat_id = $AllowedChatId; text = $Text; parse_mode = $ParseMode }
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $payload | Out-Null
    } catch {
        Write-BotLog "TELEGRAM API ERROR: $($_.Exception.Message)" "ERROR"
    }
}

# -------------------------------------------------------------------------
# 4. COMMAND ROUTER (Delegates to JobManager)
# -------------------------------------------------------------------------
function Route-Command {
    param ([string]$CommandText)
    
    # Extract root command and arguments (e.g. "/testjob 15")
    $parts = ($CommandText.ToLower().Trim() -replace '@.*', '') -split '\s+', 2
    $cmd = $parts[0]
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    Write-BotLog "Routing command: $cmd" "INFO"
    
    # --- LIGHTWEIGHT COMMANDS (Immediate, Synchronous) ---
    if ($Config.telegram.commands.lightweight -contains $cmd) {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/jobs" { Send-TelegramMessage (Get-ActiveJobsFormatted) }
            "/help" { Send-TelegramMessage "🤖 <b>Available Commands:</b>`n/ping - Connectivity`n/jobs - View running background jobs`n/status - System report`n/testjob [seconds] - Run a fake background workload" }
        }
        return
    }

    # --- JOB COMMANDS (Delegated to Runspace Pool) ---
    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        
        Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd"
        
        switch ($cmd) {
            "/status" { 
                # Defined as an isolated scriptblock for the Runspace
                $sb = {
                    param($WsPath)
                    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
                    $os = Get-CimInstance Win32_OperatingSystem
                    $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
                    $drvLet = if ($WsPath) { $WsPath.Substring(0,1) } else { "C" }
                    $drv = Get-PSDrive -Name $drvLet
                    $disk = [math]::Round((($drv.Used) / ($drv.Used + $drv.Free)) * 100, 1)
                    return "🖥️ <b>SYSTEM STATUS</b>`nCPU: $cpu%`nRAM: $ram%`nWorkspace Disk (${drvLet}:): $disk%"
                }
                Submit-Job -JobId $jobId -CommandName $cmd -ScriptBlock $sb -Arguments @{ WsPath = $WorkspacePath }
            }
            "/testjob" {
                $seconds = if ($args -match '^\d+$') { [int]$args } else { 15 }
                $sb = {
                    param($Secs)
                    Start-Sleep -Seconds $Secs
                    return "⏳ Test job successfully ran in the background for $Secs seconds!"
                }
                Submit-Job -JobId $jobId -CommandName "$cmd $seconds" -ScriptBlock $sb -Arguments @{ Secs = $seconds }
            }
        }
        return
    }

    Send-TelegramMessage "❓ Unknown command: $cmd`nUse /help for available commands."
}

# -------------------------------------------------------------------------
# 5. LONG POLLING ENGINE & EVENT PROCESSOR
# -------------------------------------------------------------------------
Write-BotLog "Attempting to send startup message..." "INFO"
Send-TelegramMessage "🚀 <b>BotService (Phase 3) Started</b>`nAsync Job Queue is online."

while ($true) {
    try {
        # 1. Poll Telegram
        $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$Offset&timeout=$($Config.telegram.longPollingTimeoutSeconds)" -Method Get -TimeoutSec ($Config.telegram.longPollingTimeoutSeconds + 5)
        
        if ($updates.ok -and $updates.result.Count -gt 0) {
            foreach ($update in $updates.result) {
                $Offset = $update.update_id + 1
                $msg = $update.message
                if (-not $msg.text) { continue }

                if ([string]$msg.chat.id -ne $AllowedChatId -or [string]$msg.from.id -ne $AdminUserId) {
                    Write-BotLog "ACCESS DENIED. Expected Chat: $AllowedChatId | Expected User: $AdminUserId" "WARN"
                    continue 
                }

                Route-Command -Command $msg.text
            }
        }
    } catch {
        # Ignore timeout hiccups silently to keep logs clean
    }

    # 2. Process Async Job Events (The Magic!)
    $jobEvents = Invoke-JobManagerTick
    foreach ($event in $jobEvents) {
        if ($event.Event -eq 'COMPLETED') {
            Write-BotLog "Job $($event.JobId) Completed successfully." "SUCCESS"
            Send-TelegramMessage "✅ Job <code>$($event.JobId)</code> completed.`n`n$($event.Result)"
        } elseif ($event.Event -eq 'FAILED') {
            Write-BotLog "Job $($event.JobId) FAILED: $($event.Result)" "ERROR"
            Send-TelegramMessage "❌ Job <code>$($event.JobId)</code> FAILED.`nCommand: $($event.Command)`nReason: $($event.Result)"
        }
    }
}
