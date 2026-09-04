<#
.SYNOPSIS
    RDP Manager - BotService (Phase 2)
.DESCRIPTION
    Dedicated long-polling Telegram controller. Handles Authentication, 
    Authorization, and Command Routing without exposing secrets.
#>

$ErrorActionPreference = 'SilentlyContinue' # Prevent crashes from stopping the loop

# -------------------------------------------------------------------------
# 1. INITIALIZATION & SECURITY
# -------------------------------------------------------------------------
$ConfigPath = "$PSScriptRoot\..\config\settings.json"
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$BotToken = $env:TELEGRAM_BOT_TOKEN
$AllowedChatId = $env:TELEGRAM_CHAT_ID
$AdminUserId = $env:TELEGRAM_ADMIN_ID

function Write-BotLog {
    param ([string]$Message, [string]$Level = 'INFO')
    # Mask secrets in logs just in case
    if ($BotToken) { $Message = $Message.Replace($BotToken, "[REDACTED_TOKEN]") }
    $color = switch ($Level) { 'INFO'{'Cyan'} 'WARN'{'Yellow'} 'ERROR'{'Red'} 'SUCCESS'{'Green'} }
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] [BOT-$Level] $Message" -ForegroundColor $color
}

if (-not $BotToken -or -not $AllowedChatId -or -not $AdminUserId) {
    Write-BotLog "Missing required Telegram environment variables. Service halting." "ERROR"
    exit 1
}

$ApiUrl = "https://api.telegram.org/bot$BotToken"
$Offset = 0
$JobCounter = 1

Write-BotLog "BotService initialized. Single-controller lock assumed." "SUCCESS"
Write-BotLog "Telegram Token: CONFIGURED" "INFO"

# -------------------------------------------------------------------------
# 2. HELPER FUNCTIONS
# -------------------------------------------------------------------------
function Send-TelegramMessage {
    param ([string]$Text, [string]$ParseMode = "HTML")
    $payload = @{ chat_id = $AllowedChatId; text = $Text; parse_mode = $ParseMode }
    Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -Body $payload | Out-Null
}

function Get-SystemStatus {
    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
    $drive = Get-PSDrive -Name ($env:WORKSPACE_ROOT.Substring(0,1))
    $disk = [math]::Round((($drive.Used) / ($drive.Used + $drive.Free)) * 100, 1)
    return "🖥️ <b>SYSTEM STATUS</b>%0ACPU: $cpu`%%0ARAM: $ram`%%0AWorkspace Disk: $disk`%"
}

# -------------------------------------------------------------------------
# 3. COMMAND ROUTER & JOB INTERFACE
# -------------------------------------------------------------------------
function Route-Command {
    param ([string]$Command)
    
    $cmd = $Command.ToLower().Trim()
    
    # Lightweight Commands (Immediate Response)
    if ($Config.telegram.commands.lightweight -contains $cmd) {
        switch ($cmd) {
            "/ping" { Send-TelegramMessage "✅ System is ONLINE and listening." }
            "/help" { Send-TelegramMessage "🤖 <b>Available Commands:</b>%0A/ping - Check connectivity%0A/status - Generate system report" }
        }
        return
    }

    # Job Commands (Queued Interface)
    if ($Config.telegram.commands.jobs -contains $cmd) {
        $jobId = "JOB-$($JobCounter.ToString('000'))"
        $script:JobCounter++
        
        # 1. Acknowledge Receipt
        Send-TelegramMessage "📥 Job <code>$jobId</code> queued.`nCommand: $cmd"
        
        # 2. Process Job (Synchronous for Phase 2, Async in Phase 3)
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
Send-TelegramMessage "🚀 <b>BotService Started</b>`nReady for commands."
Write-BotLog "Entering long-polling loop..." "INFO"

while ($true) {
    try {
        $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$Offset&timeout=$($Config.telegram.longPollingTimeoutSeconds)" -Method Get -TimeoutSec ($Config.telegram.longPollingTimeoutSeconds + 5)
        
        if ($updates.ok -and $updates.result.Count -gt 0) {
            foreach ($update in $updates.result) {
                $Offset = $update.update_id + 1
                
                $msg = $update.message
                if (-not $msg.text) { continue }

                # AUTHORIZATION CHECK
                if ([string]$msg.chat.id -ne $AllowedChatId -or [string]$msg.from.id -ne $AdminUserId) {
                    Write-BotLog "Unauthorized access attempt from User: $($msg.from.id) in Chat: $($msg.chat.id)" "WARN"
                    continue 
                }

                Write-BotLog "Command received: $($msg.text)" "INFO"
                Route-Command -Command $msg.text
            }
        }
    } catch {
        Write-BotLog "Polling error: $($_.Exception.Message)" "WARN"
        Start-Sleep -Seconds $Config.telegram.retryBackoffSeconds
    }
}
