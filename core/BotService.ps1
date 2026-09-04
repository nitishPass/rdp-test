<#
.SYNOPSIS
    RDP Manager - BotService (Phase 2 - Debugging Enabled)
.DESCRIPTION
    Dedicated long-polling Telegram controller with physical file logging.
#>

[CmdletBinding()]
param (
    [string]$WorkspacePath
)

# STOP hiding errors so we can catch API rejections!
$ErrorActionPreference = 'Continue' 

# Setup physical logging
$LogFile = if ($WorkspacePath) { Join-Path $WorkspacePath "State\bot.log" } else { "C:\Users\Public\Desktop\bot_emergency.log" }

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    if ($env:TELEGRAM_BOT_TOKEN) { $Message = $Message.Replace($env:TELEGRAM_BOT_TOKEN, "[REDACTED_TOKEN]") }
    $logEntry = "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry
}

Write-BotLog "=== BOT SERVICE PROCESS STARTED ===" "INFO"

# -------------------------------------------------------------------------
# 1. INITIALIZATION & SECURITY
# -------------------------------------------------------------------------
$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

# Check for missing secrets
if (-not $BotToken) { Write-BotLog "CRITICAL ERROR: TELEGRAM_BOT_TOKEN is empty!" "ERROR"; exit 1 }
if (-not $AllowedChatId) { Write-BotLog "CRITICAL ERROR: TELEGRAM_CHAT_ID is empty!" "ERROR"; exit 1 }
if (-not $AdminUserId) { Write-BotLog "CRITICAL ERROR: TELEGRAM_ADMIN_ID is empty!" "ERROR"; exit 1 }

$ApiUrl = "https://api.telegram.org/bot$BotToken"
$Offset = 0
$JobCounter = 1

Write-BotLog "Secrets verified. Allowed Chat: $AllowedChatId | Admin: $AdminUserId" "SUCCESS"

# -------------------------------------------------------------------------
# 2. HELPER FUNCTIONS
# -------------------------------------------------------------------------
function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML")
    try {
        $payload = @{ chat_id = $AllowedChatId; text = $Text; parse_mode = $ParseMode }
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $payload | Out-Null
        Write-BotLog "Successfully sent message to Telegram." "SUCCESS"
    } catch {
        Write-BotLog "TELEGRAM API ERROR: $($_.Exception.Message)" "ERROR"
    }
}

function Get-SystemStatus {
    try {
        $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
        $os = Get-CimInstance Win32_OperatingSystem
        $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
        
        $driveLetter = if ($WorkspacePath) { $WorkspacePath.Substring(0,1) } else { "C" }
        $drive = Get-PSDrive -Name $driveLetter
        $disk = [math]::Round((($drive.Used) / ($drive.Used + $drive.Free)) * 100, 1)
        
        return "🖥️ <b>SYSTEM STATUS</b>%0ACPU: $cpu`%%0ARAM: $ram`%%0AWorkspace Disk ($driveLetter:): $disk`%"
    } catch {
        Write-BotLog "Status Generation Error: $($_.Exception.Message)" "ERROR"
        return "⚠️ Error generating system status."
    }
}

# -------------------------------------------------------------------------
# 3. COMMAND ROUTER
# -------------------------------------------------------------------------
function Route-Command {
    param ([string]$Command)
    
    $cmd = $Command.ToLower().Trim()
    Write-BotLog "Routing command: $cmd" "INFO"
    
    if ($Config.telegram.commands.lightweight -contains $cmd) {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/help" { Send-TelegramMessage "🤖 <b>Available Commands:</b>%0A/ping - Check connectivity%0A/status - Generate system report" }
        }
        return
    }

    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        
        Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd"
        Write-BotLog "Processing $jobId ($cmd)..." "INFO"
        
        switch ($cmd) {
            "/status" { 
                $result = Get-SystemStatus 
                Send-TelegramMessage "✅ Job <code>$jobId</code> completed.`n%0A$result"
            }
        }
        return
    }

    Send-TelegramMessage "❓ Unknown command: $cmd`nUse /help for available commands."
}

# -------------------------------------------------------------------------
# 4. LONG POLLING ENGINE
# -------------------------------------------------------------------------
Write-BotLog "Attempting to send startup message..." "INFO"
Send-TelegramMessage "🚀 <b>BotService Started</b>`nReady for commands."

while ($true) {
    try {
        $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$Offset&timeout=$($Config.telegram.longPollingTimeoutSeconds)" -Method Get -TimeoutSec ($Config.telegram.longPollingTimeoutSeconds + 5)
        
        if ($updates.ok -and $updates.result.Count -gt 0) {
            foreach ($update in $updates.result) {
                $Offset = $update.update_id + 1
                $msg = $update.message
                if (-not $msg.text) { continue }

                # Log incoming attempts for debugging
                Write-BotLog "Message '$($msg.text)' received from User ID: $($msg.from.id) in Chat ID: $($msg.chat.id)" "INFO"

                # AUTHORIZATION CHECK
                if ([string]$msg.chat.id -ne $AllowedChatId -or [string]$msg.from.id -ne $AdminUserId) {
                    Write-BotLog "ACCESS DENIED. Expected Chat: $AllowedChatId | Expected User: $AdminUserId" "WARN"
                    continue 
                }

                Route-Command -Command $msg.text
            }
        }
    } catch {
        Write-BotLog "Polling error: $($_.Exception.Message)" "WARN"
        Start-Sleep -Seconds $Config.telegram.retryBackoffSeconds
    }
}
