param(
    [string]$InstanceId = $env:EC2_INSTANCE_ID,
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-southeast-2" }),
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$StopServerScriptPath = "C:\starruptureserver\stop_server.ps1",
    [int]$StopServerTimeoutSeconds = 120,
    [string]$BackupScriptPath = "C:\starruptureserver\backup_save.ps1",
    [int]$PreInstanceStopDelaySeconds = 30,
    [switch]$SkipServerStop,
    [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"

$activityLogPath = Join-Path $ServerRoot "shutdown_now.log"

function Write-ShutdownLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

try {
    if (-not $InstanceId) {
        throw "InstanceId is required. Pass -InstanceId or set EC2_INSTANCE_ID."
    }

    Write-ShutdownLog "Manual graceful shutdown requested for instance $InstanceId in $Region. PreInstanceStopDelaySeconds=$PreInstanceStopDelaySeconds."

    if (-not $SkipServerStop) {
        if (Test-Path $StopServerScriptPath) {
            Write-ShutdownLog "Requesting game server stop."
            powershell.exe -ExecutionPolicy Bypass -File $StopServerScriptPath -ServerRoot $ServerRoot -TimeoutSeconds $StopServerTimeoutSeconds
            Write-ShutdownLog "Game server stop request completed."
        } else {
            Write-ShutdownLog "Stop server script not found at $StopServerScriptPath; skipping game server stop."
        }
    }

    if (-not $SkipBackup) {
        if (Test-Path $BackupScriptPath) {
            Write-ShutdownLog "Running save backup before shutdown."
            powershell.exe -ExecutionPolicy Bypass -File $BackupScriptPath -ServerRoot $ServerRoot -Region $Region
            Write-ShutdownLog "Save backup completed."
        } else {
            Write-ShutdownLog "Backup script not found at $BackupScriptPath; skipping backup."
        }
    }

    if ($PreInstanceStopDelaySeconds -gt 0) {
        Write-ShutdownLog "Waiting $PreInstanceStopDelaySeconds seconds before stopping EC2 instance."
        Start-Sleep -Seconds $PreInstanceStopDelaySeconds
    }

    Write-ShutdownLog "Stopping EC2 instance."
    aws ec2 stop-instances --instance-ids $InstanceId --region $Region | Out-Null
    Write-ShutdownLog "EC2 stop request sent."
} catch {
    Write-ShutdownLog "Error: $($_.Exception.Message)"
    throw
}
