param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [string]$RuntimeExeName = "StarRuptureServerEOS-Win64-Shipping.exe",
    [int]$TimeoutSeconds = 120,
    [int]$TaskkillGraceSeconds = 0,
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
    return @(Get-Process -Name $runtimeProcessName, $processName -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { if ($_.ProcessName -eq $runtimeProcessName) { 0 } else { 1 } } }, Id)
}

try {
    if ($TaskkillGraceSeconds -le 0) {
        $TaskkillGraceSeconds = $TimeoutSeconds
    }

    Write-StopLog "Stop script started. ServerRoot=$ServerRoot PidPath=$pidPath StopRequestPath=$stopRequestPath TimeoutSeconds=$TimeoutSeconds TaskkillGraceSeconds=$TaskkillGraceSeconds NoForce=$NoForce."

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

    $remaining = Get-ServerProcesses
    if ($remaining.Count -gt 0) {
        $remainingSummary = ($remaining | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        Write-StopLog "Trying taskkill without /F for $($remaining.Count) process(es): $remainingSummary."

        foreach ($item in $remaining) {
            $output = & cmd.exe /d /c "taskkill.exe /PID $($item.Id) 2>&1"
            $exitCode = $LASTEXITCODE
            $joinedOutput = ($output | Out-String).Trim()
            if ($joinedOutput) {
                Write-StopLog "taskkill /PID $($item.Id) ($($item.ProcessName)) exitCode=$exitCode output=$joinedOutput"
            } else {
                Write-StopLog "taskkill /PID $($item.Id) ($($item.ProcessName)) exitCode=$exitCode."
            }
        }

        $taskkillDeadline = (Get-Date).AddSeconds($TaskkillGraceSeconds)
        while ((Get-Date) -lt $taskkillDeadline) {
            Start-Sleep -Seconds 2
            $remaining = Get-ServerProcesses
            if ($remaining.Count -eq 0) {
                Write-StopLog "All StarRupture server processes exited after taskkill without /F."
                Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
                exit 0
            }
        }
    }

    if ($NoForce) {
        throw "Server did not exit within $TaskkillGraceSeconds seconds after taskkill without /F."
    }

    $remaining = Get-ServerProcesses
    $remainingSummary = ($remaining | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
    if ($remaining.Count -gt 0) {
        Write-StopLog "Server did not exit within $TaskkillGraceSeconds seconds after taskkill without /F. Forcing process stop for $($remaining.Count) process(es): $remainingSummary."
        $remaining | Stop-Process -Force
    } else {
        Write-StopLog "No StarRupture process remained before force stop."
    }
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stopRequestPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-StopLog "Error: $($_.Exception.Message)"
    throw
}
