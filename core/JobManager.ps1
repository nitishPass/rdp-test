<#
.SYNOPSIS
    RDP Manager - Job Manager (Phase 3 & 4)
.DESCRIPTION
    Asynchronous Runspace Pool engine with exposed statistics.
#>

$global:JobManager_Config = $Config
$global:JobManager_StateFile = Join-Path $WorkspacePath "State\$($global:JobManager_Config.jobManager.stateFileName)"

$global:JobManager_Pool = [runspacefactory]::CreateRunspacePool(1, $global:JobManager_Config.jobManager.maxWorkers)
$global:JobManager_Pool.Open()
$global:JobManager_Jobs = @{}
$global:JobManager_TotalCompleted = 0
$global:JobManager_TotalFailed = 0

function Initialize-JobManager {
    Write-BotLog "Initializing Async JobManager (Max Workers: $($global:JobManager_Config.jobManager.maxWorkers))..." "INFO"
    @{ jobs = @() } | ConvertTo-Json | Set-Content $global:JobManager_StateFile -ErrorAction SilentlyContinue
}

function Sync-JobState {
    $state = @{ jobs = @() }
    foreach ($job in $global:JobManager_Jobs.Values) {
        $state.jobs += @{ id = $job.Id; command = $job.Command; status = $job.Status; started = $job.Started }
    }
    $state | ConvertTo-Json -Depth 3 | Set-Content $global:JobManager_StateFile -ErrorAction SilentlyContinue
}

function Submit-Job {
    param([string]$JobId, [string]$CommandName, [scriptblock]$ScriptBlock, [hashtable]$Arguments = @{})
    
    $ps = [powershell]::Create().AddScript($ScriptBlock)
    foreach ($key in $Arguments.Keys) { $null = $ps.AddArgument($Arguments[$key]) }
    $ps.RunspacePool = $global:JobManager_Pool
    
    $async = $ps.BeginInvoke()
    
    $global:JobManager_Jobs[$JobId] = @{
        Id = $JobId; Command = $CommandName; PSInstance = $ps
        AsyncResult = $async; Status = 'RUNNING'; Started = (Get-Date).ToString('o')
    }
    Sync-JobState
}

function Invoke-JobManagerTick {
    $events = @()
    $completedKeys = @()
    
    foreach ($key in $global:JobManager_Jobs.Keys) {
        $job = $global:JobManager_Jobs[$key]
        if ($job.AsyncResult.IsCompleted) {
            try {
                $result = $job.PSInstance.EndInvoke($job.AsyncResult)
                if ($job.PSInstance.Streams.Error.Count -gt 0) { throw $job.PSInstance.Streams.Error[0].Exception.Message }
                $events += @{ JobId = $job.Id; Event = 'COMPLETED'; Result = $result; Command = $job.Command }
                $global:JobManager_TotalCompleted++
            } catch {
                $events += @{ JobId = $job.Id; Event = 'FAILED'; Result = $_.Exception.Message; Command = $job.Command }
                $global:JobManager_TotalFailed++
            } finally {
                $job.PSInstance.Dispose()
                $completedKeys += $key
            }
        }
    }
    
    foreach ($k in $completedKeys) { $global:JobManager_Jobs.Remove($k) }
    if ($completedKeys.Count -gt 0) { Sync-JobState }
    
    return $events
}

function Get-ActiveJobsFormatted {
    if ($global:JobManager_Jobs.Count -eq 0) { return "📋 <b>ACTIVE JOBS</b>`nNo jobs running." }
    $out = "📋 <b>ACTIVE JOBS</b>"
    foreach ($job in $global:JobManager_Jobs.Values) { $out += "`n🔹 <code>$($job.Id)</code> : $($job.Command) [$($job.Status)]" }
    return $out
}

function Get-JobManagerStats {
    return @{
        Running = $global:JobManager_Jobs.Count
        Completed = $global:JobManager_TotalCompleted
        Failed = $global:JobManager_TotalFailed
        Workers = $global:JobManager_Config.jobManager.maxWorkers
    }
}
