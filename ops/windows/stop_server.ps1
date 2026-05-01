param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [string]$RuntimeExeName = "StarRuptureServerEOS-Win64-Shipping.exe",
    [int]$TimeoutSeconds = 120,
    [switch]$NoForce
)

$ErrorActionPreference = "Stop"

$pidPath = Join-Path $ServerRoot "starrupture_server.pid"
$stopRequestPath = Join-Path $ServerRoot "starrupture_server.stop"
$activityLogPath = Join-Path $ServerRoot "stop_server.log"
$processName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
$runtimeProcessName = [System.IO.Path]::GetFileNameWithoutExtension($RuntimeExeName)

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
            if ($byPid -and ($byPid.ProcessName -eq $processName -or $byPid.ProcessName -eq $runtimeProcessName)) {
                return $byPid
            }
        }
    }

    return Get-Process -Name $runtimeProcessName, $processName -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-ServerProcesses {
    return @(Get-Process -Name $runtimeProcessName, $processName -ErrorAction SilentlyContinue)
}

try {
    Write-StopLog "Stop script started. ServerRoot=$ServerRoot PidPath=$pidPath StopRequestPath=$stopRequestPath TimeoutSeconds=$TimeoutSeconds NoForce=$NoForce."

    $allServerProcesses = Get-ServerProcesses
    if ($allServerProcesses.Count -gt 0) {
        $processSummary = ($allServerProcesses | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        Write-StopLog "Detected StarRupture process(es): $processSummary."
    } else {
        Write-StopLog "No StarRupture process found before stop request."
    }

    $process = Get-ServerProcess
    if (-not $process) {
        Write-StopLog "Server process is not running."
        Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
        exit 0
    }

    Write-StopLog "Creating stop request for server PID $($process.Id)."
    Set-Content -Path $stopRequestPath -Value (Get-Date).ToUniversalTime().ToString("o") -Encoding ASCII
    if (Test-Path $stopRequestPath) {
        Write-StopLog "Stop request file created successfully."
    } else {
        Write-StopLog "Warning: stop request file was not found immediately after creation."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $requestStillPresentLogged = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (-not $requestStillPresentLogged -and (Test-Path $stopRequestPath) -and (Get-Date) -gt $deadline.AddSeconds(-1 * ($TimeoutSeconds - 10))) {
            $requestStillPresentLogged = $true
            Write-StopLog "Stop request still exists after 10 seconds. Supervisor may not be watching this path or may not be running."
        }

        $remaining = Get-ServerProcesses
        if ($remaining.Count -eq 0) {
            Write-StopLog "All StarRupture server processes exited after supervisor stop request."
            Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
            exit 0
        }
    }

    if ($NoForce) {
        throw "Server did not exit within $TimeoutSeconds seconds after supervisor stop request."
    }

    $remaining = Get-ServerProcesses
    $remainingSummary = ($remaining | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
    Write-StopLog "Server did not exit within $TimeoutSeconds seconds. Forcing process stop for $($remaining.Count) process(es): $remainingSummary."
    $remaining | Stop-Process -Force
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-StopLog "Error: $($_.Exception.Message)"
    throw
}
