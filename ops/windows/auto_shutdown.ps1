param(
    [string]$InstanceId = $env:EC2_INSTANCE_ID,
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-southeast-2" }),
    [string]$ServerRoot = "C:\starruptureserver",
    [int]$IdleMinutes = 10,
    [int]$SaveFreshnessMinutes = 20,
    [string]$StopServerScriptPath = "C:\starruptureserver\stop_server.ps1",
    [int]$StopServerTimeoutSeconds = 120,
    [string]$BackupScriptPath = "C:\starruptureserver\backup_save.ps1",
    [switch]$SkipServerStop,
    [switch]$SkipBackup,
    [switch]$SkipRecentSaveCheck
)

$ErrorActionPreference = "Stop"

$logDirectory = Join-Path $ServerRoot "StarRupture\Saved\Logs"
$statePath = Join-Path $ServerRoot "auto_shutdown_state.json"
$activityLogPath = Join-Path $ServerRoot "auto_shutdown.log"

function Write-AutoShutdownLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

function New-State {
    return [PSCustomObject]@{
        logPath = ""
        offset = 0
        playerCount = 0
        idleSinceUtc = $null
        idleCandidateSinceUtc = $null
        lastPlayerJoinUtc = $null
        lastPlayerLeaveUtc = $null
        lastSaveUtc = $null
        lastSaveLine = ""
        stopped = $false
    }
}

function Read-State {
    if (Test-Path $statePath) {
        try {
            return Get-Content -Path $statePath -Raw | ConvertFrom-Json
        } catch {
            Write-AutoShutdownLog "State file was invalid; starting fresh. $($_.Exception.Message)"
        }
    }

    return New-State
}

function Ensure-StateProperty {
    param(
        [object]$State,
        [string]$Name,
        [object]$Value
    )

    if (-not ($State.PSObject.Properties.Name -contains $Name)) {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Normalize-State {
    param([object]$State)

    Ensure-StateProperty -State $State -Name "logPath" -Value ""
    Ensure-StateProperty -State $State -Name "offset" -Value 0
    Ensure-StateProperty -State $State -Name "playerCount" -Value 0
    Ensure-StateProperty -State $State -Name "idleSinceUtc" -Value $null
    Ensure-StateProperty -State $State -Name "idleCandidateSinceUtc" -Value $null
    Ensure-StateProperty -State $State -Name "lastPlayerJoinUtc" -Value $null
    Ensure-StateProperty -State $State -Name "lastPlayerLeaveUtc" -Value $null
    Ensure-StateProperty -State $State -Name "lastSaveUtc" -Value $null
    Ensure-StateProperty -State $State -Name "lastSaveLine" -Value ""
    Ensure-StateProperty -State $State -Name "stopped" -Value $false

    return $State
}

function Save-State {
    param([object]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8
}

function Test-SaveMarker {
    param([string]$Line)
    return $Line -match "UCrMassSaveSubsystem,\s+Saved\s+\d+\s+loaded items" -or
        $Line -match "bSuccess:\s*true"
}

function Get-RecentSaveStatus {
    param(
        [object]$State,
        [int]$FreshnessMinutes
    )

    if (-not $State.lastSaveUtc) {
        return [PSCustomObject]@{
            IsFresh = $false
            Message = "No save marker has been observed yet."
        }
    }

    $lastSave = [DateTime]::Parse($State.lastSaveUtc).ToUniversalTime()
    $age = (Get-Date).ToUniversalTime() - $lastSave
    return [PSCustomObject]@{
        IsFresh = $age.TotalMinutes -le $FreshnessMinutes
        Message = "Last save marker was $([Math]::Round($age.TotalMinutes, 1)) minutes ago: $($State.lastSaveLine)"
    }
}

try {
    if (-not $InstanceId) {
        throw "InstanceId is required. Pass -InstanceId or set EC2_INSTANCE_ID."
    }

    Write-AutoShutdownLog "Auto-shutdown check started. InstanceId=$InstanceId Region=$Region IdleMinutes=$IdleMinutes SaveFreshnessMinutes=$SaveFreshnessMinutes."

    if (-not (Test-Path $logDirectory)) {
        Write-AutoShutdownLog "Log directory not found: $logDirectory"
        exit 0
    }

    $latestLog = Get-ChildItem -Path $logDirectory -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latestLog) {
        Write-AutoShutdownLog "No StarRupture log files found."
        exit 0
    }

    $state = Normalize-State -State (Read-State)
    if ($state.logPath -ne $latestLog.FullName) {
        $state.logPath = $latestLog.FullName
        $state.offset = 0
        $state.playerCount = 0
        $state.idleSinceUtc = $null
        $state.idleCandidateSinceUtc = $null
        $state.stopped = $false
        $state.lastSaveUtc = $null
        $state.lastSaveLine = ""
        Write-AutoShutdownLog "Tracking latest log: $($latestLog.FullName)"
    }

    $stream = [System.IO.File]::Open($latestLog.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ([int64]$state.offset -gt $stream.Length) {
            $state.offset = 0
        }

        $stream.Seek([int64]$state.offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($stream)
        $newText = $reader.ReadToEnd()
        $state.offset = $stream.Position
    } finally {
        $stream.Close()
    }

    if ($newText) {
        foreach ($line in ($newText -split "`r?`n")) {
            if (Test-SaveMarker -Line $line) {
                $state.lastSaveUtc = (Get-Date).ToUniversalTime().ToString("o")
                $state.lastSaveLine = $line.Trim()
                Write-AutoShutdownLog "Save marker observed: $($state.lastSaveLine)"
            }

            if ($line -match "Join succeeded") {
                $state.playerCount = [int]$state.playerCount + 1
                $state.idleSinceUtc = $null
                $state.idleCandidateSinceUtc = $null
                $state.lastPlayerJoinUtc = (Get-Date).ToUniversalTime().ToString("o")
                $state.stopped = $false
                Write-AutoShutdownLog "Player joined. Count: $($state.playerCount)"
            } elseif ($line -match "UnregisterPlayers|ConnectionTimeout") {
                $state.playerCount = [Math]::Max(0, [int]$state.playerCount - 1)
                $state.lastPlayerLeaveUtc = (Get-Date).ToUniversalTime().ToString("o")
                if (-not $state.idleCandidateSinceUtc) {
                    $state.idleCandidateSinceUtc = $state.lastPlayerLeaveUtc
                }
                Write-AutoShutdownLog "Player left, timed out, or closed connection. Count estimate: $($state.playerCount)"
            } elseif ($line -match "ControlChannelClose|Removed address") {
                Write-AutoShutdownLog "Connection close activity observed without changing count estimate."
            }
        }
    } else {
        Write-AutoShutdownLog "No new log entries. Current count estimate: $($state.playerCount). IdleSinceUtc=$($state.idleSinceUtc). LastSaveUtc=$($state.lastSaveUtc)."
    }

    if ([int]$state.playerCount -eq 0) {
        if (-not $state.idleSinceUtc) {
            $state.idleSinceUtc = $(if ($state.idleCandidateSinceUtc) { $state.idleCandidateSinceUtc } else { (Get-Date).ToUniversalTime().ToString("o") })
            Write-AutoShutdownLog "Server became idle."
        }

        $idleSince = [DateTime]::Parse($state.idleSinceUtc).ToUniversalTime()
        $idleFor = (Get-Date).ToUniversalTime() - $idleSince

        if ($idleFor.TotalMinutes -ge $IdleMinutes -and -not $state.stopped) {
            if (-not $SkipRecentSaveCheck) {
                $saveStatus = Get-RecentSaveStatus -State $state -FreshnessMinutes $SaveFreshnessMinutes
                if (-not $saveStatus.IsFresh) {
                    Write-AutoShutdownLog "Idle threshold reached, but shutdown is waiting for a recent save marker. $($saveStatus.Message)"
                    Save-State -State $state
                    exit 0
                }

                Write-AutoShutdownLog "Recent save marker confirmed before shutdown. $($saveStatus.Message)"
            }

            Write-AutoShutdownLog "Idle for $([Math]::Round($idleFor.TotalMinutes, 1)) minutes. Stopping EC2 instance $InstanceId in $Region."
            if (-not $SkipServerStop) {
                if (Test-Path $StopServerScriptPath) {
                    Write-AutoShutdownLog "Requesting game server stop."
                    powershell.exe -ExecutionPolicy Bypass -File $StopServerScriptPath -ServerRoot $ServerRoot -TimeoutSeconds $StopServerTimeoutSeconds
                    Write-AutoShutdownLog "Game server stop request completed."
                } else {
                    Write-AutoShutdownLog "Stop server script not found at $StopServerScriptPath; skipping game server stop."
                }
            }
            if (-not $SkipBackup) {
                if (Test-Path $BackupScriptPath) {
                    Write-AutoShutdownLog "Running save backup before shutdown."
                    powershell.exe -ExecutionPolicy Bypass -File $BackupScriptPath -ServerRoot $ServerRoot -Region $Region
                    Write-AutoShutdownLog "Save backup completed."
                } else {
                    Write-AutoShutdownLog "Backup script not found at $BackupScriptPath; skipping backup."
                }
            }
            aws ec2 stop-instances --instance-ids $InstanceId --region $Region | Out-Null
            $state.stopped = $true
        }
    } else {
        $state.idleSinceUtc = $null
        $state.stopped = $false
    }

    Save-State -State $state
} catch {
    Write-AutoShutdownLog "Error: $($_.Exception.Message)"
    throw
}
