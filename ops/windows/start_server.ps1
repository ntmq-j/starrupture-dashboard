param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

$pidPath = Join-Path $ServerRoot "starrupture_server.pid"
$activityLogPath = Join-Path $ServerRoot "start_server.log"
$exePath = Join-Path $ServerRoot $ExeName

function Write-StartLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

try {
    if (-not (Test-Path $exePath)) {
        throw "Server executable not found: $exePath"
    }

    $existing = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($ExeName)) -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($existing) {
        Set-Content -Path $pidPath -Value $existing.Id -Encoding ASCII
        Write-StartLog "Server already running with PID $($existing.Id)."
        exit 0
    }

    Set-Location $ServerRoot
    Write-StartLog "Starting $ExeName on port $Port."

    $process = Start-Process `
        -FilePath $exePath `
        -ArgumentList @("-Log", "-port=$Port") `
        -WorkingDirectory $ServerRoot `
        -PassThru

    Set-Content -Path $pidPath -Value $process.Id -Encoding ASCII
    Write-StartLog "Started server PID $($process.Id)."

    $process.WaitForExit()
    Write-StartLog "Server PID $($process.Id) exited with code $($process.ExitCode)."
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-StartLog "Error: $($_.Exception.Message)"
    throw
}
