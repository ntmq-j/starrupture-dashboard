param(
    [ValidateSet("List", "Restore")]
    [string]$Mode = "List",
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$SavePath = "C:\starruptureserver\StarRupture\Saved\SaveGames",
    [string]$BackupDirectory = "C:\starruptureserver\backups",
    [string]$FileName = "",
    [string]$StopServerScriptPath = "C:\starruptureserver\stop_server.ps1",
    [string]$StartServerScriptPath = "C:\starruptureserver\start_server.bat",
    [string]$BackupScriptPath = "C:\starruptureserver\backup_save.ps1",
    [int]$StopServerTimeoutSeconds = 120,
    [switch]$SkipCurrentBackup
)

$ErrorActionPreference = "Stop"

$activityLogPath = Join-Path $ServerRoot "restore_save.log"

function Write-RestoreLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

function Get-SaveSessions {
    if (-not (Test-Path $BackupDirectory)) {
        return @()
    }

    return @(Get-ChildItem -Path $BackupDirectory -Filter "starrupture-save-*.zip" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 5 |
        ForEach-Object {
            [PSCustomObject]@{
                fileName = $_.Name
                createdAtUtc = $_.LastWriteTimeUtc.ToString("o")
                sizeBytes = $_.Length
            }
        })
}

function Resolve-BackupPath {
    param([string]$Name)

    if (-not $Name) {
        throw "FileName is required for restore."
    }

    if ($Name -ne [System.IO.Path]::GetFileName($Name)) {
        throw "FileName must not include a path."
    }

    if ($Name -notmatch "^starrupture-save-\d{8}-\d{6}\.zip$") {
        throw "Invalid save session file name: $Name"
    }

    $path = Join-Path $BackupDirectory $Name
    if (-not (Test-Path $path)) {
        throw "Save session was not found: $Name"
    }

    return $path
}

try {
    if ($Mode -eq "List") {
        $sessions = Get-SaveSessions
        [PSCustomObject]@{ sessions = $sessions } | ConvertTo-Json -Depth 4 -Compress
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $selectedBackupPath = Resolve-BackupPath -Name $FileName
    $restoreTempRoot = Join-Path $BackupDirectory "restore-temp"
    $selectedTempZip = Join-Path $BackupDirectory ("restore-selected-" + [Guid]::NewGuid().ToString("N") + ".zip")

    if (Test-Path $restoreTempRoot) {
        Remove-Item -Path $restoreTempRoot -Recurse -Force
    }

    Copy-Item -Path $selectedBackupPath -Destination $selectedTempZip -Force
    Write-RestoreLog "Restore requested from $selectedBackupPath. Copied selected backup to $selectedTempZip."

    if (Test-Path $StopServerScriptPath) {
        Write-RestoreLog "Stopping game server before restore."
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopServerScriptPath -ServerRoot $ServerRoot -TimeoutSeconds $StopServerTimeoutSeconds
        Write-RestoreLog "Game server stop completed."
    } else {
        Write-RestoreLog "Stop server script not found at $StopServerScriptPath; continuing restore."
    }

    if (-not $SkipCurrentBackup -and (Test-Path $BackupScriptPath)) {
        Write-RestoreLog "Backing up current save before restore."
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BackupScriptPath -ServerRoot $ServerRoot -SavePath $SavePath
        Write-RestoreLog "Current save backup completed."
    }

    New-Item -ItemType Directory -Force -Path $restoreTempRoot | Out-Null
    Expand-Archive -Path $selectedTempZip -DestinationPath $restoreTempRoot -Force
    Write-RestoreLog "Expanded selected backup to $restoreTempRoot."

    if (Test-Path $SavePath) {
        Get-ChildItem -Path $SavePath -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Force -Path $SavePath | Out-Null
    }

    Copy-Item -Path (Join-Path $restoreTempRoot "*") -Destination $SavePath -Recurse -Force
    Write-RestoreLog "Restored save files to $SavePath."

    Remove-Item -Path $restoreTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $selectedTempZip -Force -ErrorAction SilentlyContinue

    if (Test-Path $StartServerScriptPath) {
        Write-RestoreLog "Starting game server after restore."
        Start-Process -FilePath $StartServerScriptPath -WorkingDirectory $ServerRoot
        Write-RestoreLog "Game server start requested."
    } else {
        Write-RestoreLog "Start server script not found at $StartServerScriptPath; restore completed without restart."
    }

    [PSCustomObject]@{
        ok = $true
        restoredFileName = $FileName
        restoredAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress
} catch {
    Write-RestoreLog "Error: $($_.Exception.Message)"
    throw
}
