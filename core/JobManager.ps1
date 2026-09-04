<#
.SYNOPSIS
    RDP Manager - Job Manager (Phase 3)
.DESCRIPTION
    Asynchronous Runspace Pool engine. Handles isolated background execution,
    persists state to jobs.json, and returns event objects to BotService.
#>

$global:JobManager_Config = $Config # Inherited from BotService
$global:JobManager_StateFile = Join-Path $WorkspacePath "State\$($global:JobManager_Config.jobManager.stateFileName)"

# Create a constrained Runspace Pool (Max 2 concurrent jobs to protect the 2-Core CPU)
$global:JobManager_Pool = [runspacefactory]::CreateRunspacePool(1, $global:JobManager_Config.jobManager.maxWorkers)
$global:JobManager_Pool.Open()
$global:JobManager_Jobs = @{}

function Initialize-JobManager {
    Write-BotLog "Initializing Async JobManager (Max Workers: $($global:JobManager_Config.jobManager.maxWorkers))..." "INFO"
    @{ jobs = @() } | ConvertTo-Json | Set-Content $global:JobManager_StateFile -ErrorAction SilentlyContinue
}

function Sync-JobState {
    $state = @{ jobs = @() }
    foreach ($job in $global:JobManager_Jobs.Values) {
        $state.jobs += @{
            id = $job.Id
            command = $job.Command
            status = $job.Status
            started = $job.Started
        }
    }
    $state | ConvertTo-Json -Depth 3 | Set-Content $global:JobManager_StateFile -ErrorAction SilentlyContinue
}

function Submit-Job {
    param(
        [string]$JobId, 
        [string]$CommandName, 
        [scriptblock]$ScriptBlock, 
        [hashtable]$Arguments = @{}
    )
    
    # Create an isolated PowerShell instance inside our Runspace Pool
    $ps = [powershell]::Create().AddScript($ScriptBlock)
    foreach ($key in $Arguments.Keys) {
        $null = $ps.AddArgument($Arguments[$key])
    }
    $ps.RunspacePool = $global:JobManager_Pool
    
    # Start asynchronously
    $async = $ps.BeginInvoke()
    
    $global:JobManager_Jobs[$JobId] = @{
        Id = $JobId
        Command = $CommandName
        PSInstance = $ps
        AsyncResult = $async
        Status = 'RUNNING'
        Started = (Get-Date).ToString('o')
    }
    
    Sync-JobState
}

function Invoke-JobManagerTick {
    <#
    .DESCRIPTION
    Called by BotService every polling loop. Checks for finished Runspaces,
    cleans up memory, and returns an array of Events for BotService to broadcast.
    #>
    $events = @()
    $completedKeys = @()
    
    foreach ($key in $global:JobManager_Jobs.Keys) {
        $job = $global:JobManager_Jobs[$key]
        
        if ($job.AsyncResult.IsCompleted) {
            try {
                # EndInvoke retrieves whatever the background worker 'returned'
                $result = $job.PSInstance.EndInvoke($job.AsyncResult)
                
                # Check for terminating errors inside the runspace
                if ($job.PSInstance.Streams.Error.Count -gt 0) {
                    throw $job.PSInstance.Streams.Error[0].Exception.Message
                }
                
                $events += @{ JobId = $job.Id; Event = 'COMPLETED'; Result = $result; Command = $job.Command }
            } catch {
                $events += @{ JobId = $job.Id; Event = 'FAILED'; Result = $_.Exception.Message; Command = $job.Command }
            } finally {
                $job.PSInstance.Dispose()
                $completedKeys += $key
            }
        }
    }
    
    foreach ($k in $completedKeys) {
        $global:JobManager_Jobs.Remove($k)
    }
    
    if ($completedKeys.Count -gt 0) {
        Sync-JobState
    }
    
    return $events
}

function Get-ActiveJobsFormatted {
    if ($global:JobManager_Jobs.Count -eq 0) { return "📋 <b>ACTIVE JOBS</b>`nNo jobs currently running in the background." }
    
    $out = "📋 <b>ACTIVE JOBS</b>"
    foreach ($job in $global:JobManager_Jobs.Values) {
        $out += "`n🔹 <code>$($job.Id)</code> : $($job.Command)`nStatus: $($job.Status)"
    }
    return $out
}
