param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [string]$RuntimeExeName = "StarRuptureServerEOS-Win64-Shipping.exe",
    [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

$activityLogPath = Join-Path $ServerRoot "start_server.log"
$autoShutdownStatePath = Join-Path $ServerRoot "auto_shutdown_state.json"
$exePath = Join-Path $ServerRoot $ExeName
$processName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
$runtimeProcessName = [System.IO.Path]::GetFileNameWithoutExtension($RuntimeExeName)

function Write-StartLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

try {
    if (-not (Test-Path $exePath)) {
        throw "Server launcher not found: $exePath"
    }

    $existing = Get-Process -Name $runtimeProcessName, $processName -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($existing) {
        Write-StartLog "Server already running with process $($existing.ProcessName):$($existing.Id)."
        exit 0
    }

    Set-Location $ServerRoot
    Remove-Item -Path $autoShutdownStatePath -Force -ErrorAction SilentlyContinue
    Write-StartLog "Reset auto-shutdown state."
    Write-StartLog "Starting $ExeName with -Log -port=$Port."
    $process = Start-Process -FilePath $exePath -ArgumentList @("-Log", "-port=$Port") -WorkingDirectory $ServerRoot -PassThru
    Write-StartLog "Launcher process started with PID $($process.Id). Runtime process may be spawned separately."
} catch {
    Write-StartLog "Error: $($_.Exception.Message)"
    throw
}
