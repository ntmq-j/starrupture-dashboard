param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [int]$TimeoutSeconds = 120,
    [switch]$NoForce
)

$ErrorActionPreference = "Stop"

$pidPath = Join-Path $ServerRoot "starrupture_server.pid"
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

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ConsoleControl {
    public const int CTRL_C_EVENT = 0;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AttachConsole(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);
}
"@

try {
    $process = Get-ServerProcess
    if (-not $process) {
        Write-StopLog "Server process is not running."
        Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
        exit 0
    }

    Write-StopLog "Sending Ctrl+C to server PID $($process.Id)."

    [ConsoleControl]::FreeConsole() | Out-Null
    [ConsoleControl]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null

    $attached = [ConsoleControl]::AttachConsole([uint32]$process.Id)
    if (-not $attached) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-StopLog "AttachConsole failed for PID $($process.Id). Win32 error: $errorCode. Falling back to taskkill without /F."
        & taskkill.exe /PID $process.Id /T | Out-Null
    } else {
        try {
            $sent = [ConsoleControl]::GenerateConsoleCtrlEvent([ConsoleControl]::CTRL_C_EVENT, 0)
            if (-not $sent) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-StopLog "GenerateConsoleCtrlEvent failed. Win32 error: $errorCode. Falling back to taskkill without /F."
                & taskkill.exe /PID $process.Id /T | Out-Null
            }
        } finally {
            Start-Sleep -Milliseconds 500
            [ConsoleControl]::FreeConsole() | Out-Null
            [ConsoleControl]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
        }
    }

    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    if ($exited) {
        Write-StopLog "Server exited gracefully after Ctrl+C."
        Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
        exit 0
    }

    if ($NoForce) {
        throw "Server did not exit within $TimeoutSeconds seconds after Ctrl+C."
    }

    Write-StopLog "Server did not exit within $TimeoutSeconds seconds. Forcing process stop."
    Stop-Process -Id $process.Id -Force
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-StopLog "Error: $($_.Exception.Message)"
    throw
}
