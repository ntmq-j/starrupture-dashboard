param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [int]$TimeoutSeconds = 120,
    [switch]$NoForce
)

$ErrorActionPreference = "Stop"

$pidPath = Join-Path $ServerRoot "starrupture_server.pid"
$stopRequestPath = Join-Path $ServerRoot "starrupture_server.stop"
$activityLogPath = Join-Path $ServerRoot "stop_server.log"
$processName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)

function Write-StopLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

function Get-ServerProcess {
    if (Test-Path $pidPath) {
        $rawPid = (Get-Content -Path $pidPath -Raw).Trim()
        if ($rawPid -match "^\d+$") {
            $byPid = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
            if ($byPid -and $byPid.ProcessName -eq $processName) {
                return $byPid
            }
        }
    }

    return Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
}

try {
    $process = Get-ServerProcess
    if (-not $process) {
        Write-StopLog "Server process is not running."
        Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
        exit 0
    }

    Write-StopLog "Creating stop request for server PID $($process.Id)."
    Set-Content -Path $stopRequestPath -Value (Get-Date).ToUniversalTime().ToString("o") -Encoding ASCII

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $process.Refresh()
        if ($process.HasExited) {
            Write-StopLog "Server exited after supervisor stop request."
            Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
            exit 0
        }
    }

    if ($NoForce) {
        throw "Server did not exit within $TimeoutSeconds seconds after supervisor stop request."
    }

    Write-StopLog "Server did not exit within $TimeoutSeconds seconds. Forcing process stop."
    Stop-Process -Id $process.Id -Force
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-StopLog "Error: $($_.Exception.Message)"
    throw
}
