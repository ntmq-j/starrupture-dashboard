param(
    [string]$InstanceId = $env:EC2_INSTANCE_ID,
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-southeast-2" }),
    [string]$ServerRoot = "C:\starruptureserver",
    [int]$IdleMinutes = 10,
    [string]$StopServerScriptPath = "C:\starruptureserver\stop_server.ps1",
    [int]$StopServerTimeoutSeconds = 120,
    [string]$BackupScriptPath = "C:\starruptureserver\backup_save.ps1",
    [switch]$SkipServerStop,
    [switch]$SkipBackup
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

function Save-State {
    param([object]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8
}

try {
    if (-not $InstanceId) {
        throw "InstanceId is required. Pass -InstanceId or set EC2_INSTANCE_ID."
    }

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

    $state = Read-State
    if ($state.logPath -ne $latestLog.FullName) {
        $state.logPath = $latestLog.FullName
        $state.offset = 0
        $state.playerCount = 0
        $state.idleSinceUtc = $null
        $state.idleCandidateSinceUtc = $null
        $state.stopped = $false
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
    }

    if ([int]$state.playerCount -eq 0) {
        if (-not $state.idleSinceUtc) {
            $state.idleSinceUtc = $(if ($state.idleCandidateSinceUtc) { $state.idleCandidateSinceUtc } else { (Get-Date).ToUniversalTime().ToString("o") })
            Write-AutoShutdownLog "Server became idle."
        }

        $idleSince = [DateTime]::Parse($state.idleSinceUtc).ToUniversalTime()
        $idleFor = (Get-Date).ToUniversalTime() - $idleSince

        if ($idleFor.TotalMinutes -ge $IdleMinutes -and -not $state.stopped) {
            Write-AutoShutdownLog "Idle for $([Math]::Round($idleFor.TotalMinutes, 1)) minutes. Stopping EC2 instance $InstanceId in $Region."
            if (-not $SkipServerStop) {
                if (Test-Path $StopServerScriptPath) {
                    Write-AutoShutdownLog "Requesting graceful game server exit with Ctrl+C."
                    powershell.exe -ExecutionPolicy Bypass -File $StopServerScriptPath -ServerRoot $ServerRoot -TimeoutSeconds $StopServerTimeoutSeconds
                    Write-AutoShutdownLog "Game server exit request completed."
                } else {
                    Write-AutoShutdownLog "Stop server script not found at $StopServerScriptPath; skipping graceful game server exit."
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
