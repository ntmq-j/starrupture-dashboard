param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$ExeName = "StarRuptureServerEOS.exe",
    [string]$RuntimeExeName = "StarRuptureServerEOS-Win64-Shipping.exe",
    [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

$pidPath = Join-Path $ServerRoot "starrupture_server.pid"
$stopRequestPath = Join-Path $ServerRoot "starrupture_server.stop"
$activityLogPath = Join-Path $ServerRoot "start_server.log"
$exePath = Join-Path $ServerRoot $ExeName
$runtimeExePath = Get-ChildItem -Path $ServerRoot -Recurse -Filter $RuntimeExeName -File -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

function Write-StartLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class StarRuptureSupervisor {
    private const int CTRL_C_EVENT = 0;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

    public static int Run(string exePath, string workingDirectory, string arguments, string pidPath, string stopRequestPath, string logPath) {
        Directory.CreateDirectory(workingDirectory);
        AppendLog(logPath, "Supervisor allocating console.");
        AllocConsole();
        SetConsoleCtrlHandler(IntPtr.Zero, true);

        var startInfo = new ProcessStartInfo {
            FileName = exePath,
            Arguments = arguments,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false
        };

        using (var process = Process.Start(startInfo)) {
            if (process == null) {
                throw new InvalidOperationException("Failed to start server process.");
            }

            File.WriteAllText(pidPath, process.Id.ToString());
            if (File.Exists(stopRequestPath)) {
                File.Delete(stopRequestPath);
            }
            AppendLog(logPath, "Started server PID " + process.Id + ".");

            bool stopSent = false;
            while (!process.HasExited) {
                if (!stopSent && File.Exists(stopRequestPath)) {
                    stopSent = true;
                    AppendLog(logPath, "Stop request detected. Sending Ctrl+C to console.");
                    try { File.Delete(stopRequestPath); } catch {}
                    bool sent = GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
                    AppendLog(logPath, "GenerateConsoleCtrlEvent result: " + sent + ".");
                }

                Thread.Sleep(1000);
                process.Refresh();
            }

            int exitCode = process.ExitCode;
            AppendLog(logPath, "Server PID " + process.Id + " exited with code " + exitCode + ".");
            try { File.Delete(pidPath); } catch {}
            FreeConsole();
            return exitCode;
        }
    }

    private static void AppendLog(string path, string message) {
        File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine);
    }
}
"@

try {
    if ($runtimeExePath) {
        $exePath = $runtimeExePath
        $ExeName = $RuntimeExeName
        Write-StartLog "Found runtime server executable: $exePath"
    }

    if (-not (Test-Path $exePath)) {
        throw "Server executable not found: $exePath"
    }

    $existing = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($ExeName)), ([System.IO.Path]::GetFileNameWithoutExtension($RuntimeExeName)) -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($existing) {
        Set-Content -Path $pidPath -Value $existing.Id -Encoding ASCII
        Write-StartLog "Server already running with PID $($existing.Id)."
        exit 0
    }

    Set-Location $ServerRoot
    Write-StartLog "Starting $ExeName on port $Port."

    $exitCode = [StarRuptureSupervisor]::Run(
        $exePath,
        $ServerRoot,
        "-Log -port=$Port",
        $pidPath,
        $stopRequestPath,
        $activityLogPath
    )

    exit $exitCode
} catch {
    Write-StartLog "Error: $($_.Exception.Message)"
    throw
}
