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
    private const int CTRL_BREAK_EVENT = 1;
    private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    private const uint WAIT_TIMEOUT = 0x00000102;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(
        string applicationName,
        string commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr processHandle, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    public static int Run(string exePath, string workingDirectory, string arguments, string pidPath, string stopRequestPath, string logPath) {
        Directory.CreateDirectory(workingDirectory);
        AppendLog(logPath, "Supervisor allocating console.");
        AllocConsole();

        var startupInfo = new STARTUPINFO();
        startupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        var commandLine = "\"" + exePath + "\" " + arguments;
        PROCESS_INFORMATION processInformation;
        bool created = CreateProcess(
            exePath,
            commandLine,
            IntPtr.Zero,
            IntPtr.Zero,
            true,
            CREATE_NEW_PROCESS_GROUP,
            IntPtr.Zero,
            workingDirectory,
            ref startupInfo,
            out processInformation
        );

        if (!created) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Failed to start server process.");
        }

        try {
            SetConsoleCtrlHandler(IntPtr.Zero, true);
            File.WriteAllText(pidPath, processInformation.dwProcessId.ToString());
            if (File.Exists(stopRequestPath)) {
                File.Delete(stopRequestPath);
            }
            AppendLog(logPath, "Started server PID " + processInformation.dwProcessId + " in its own process group.");

            bool stopSent = false;
            while (WaitForSingleObject(processInformation.hProcess, 1000) == WAIT_TIMEOUT) {
                if (!stopSent && File.Exists(stopRequestPath)) {
                    stopSent = true;
                    AppendLog(logPath, "Stop request detected. Sending Ctrl+Break to process group " + processInformation.dwProcessId + ".");
                    try { File.Delete(stopRequestPath); } catch {}
                    bool breakSent = GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, processInformation.dwProcessId);
                    AppendLog(logPath, "GenerateConsoleCtrlEvent Ctrl+Break result: " + breakSent + ".");
                    Thread.Sleep(10000);
                    if (WaitForSingleObject(processInformation.hProcess, 0) == WAIT_TIMEOUT) {
                        AppendLog(logPath, "Server still running after targeted Ctrl+Break. Sending Ctrl+C to console.");
                        bool ctrlCSent = GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
                        AppendLog(logPath, "GenerateConsoleCtrlEvent Ctrl+C result: " + ctrlCSent + ".");
                    }
                }
            }

            uint exitCode;
            if (!GetExitCodeProcess(processInformation.hProcess, out exitCode)) {
                exitCode = 1;
            }
            AppendLog(logPath, "Server PID " + processInformation.dwProcessId + " exited with code " + exitCode + ".");
            try { File.Delete(pidPath); } catch {}
            FreeConsole();
            return unchecked((int)exitCode);
        } finally {
            CloseHandle(processInformation.hThread);
            CloseHandle(processInformation.hProcess);
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
