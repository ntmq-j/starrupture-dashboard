param(
    [string]$ServerRoot = "C:\starruptureserver",
    [string]$SavePath = $(if ($env:STARRUPTURE_SAVE_PATH) { $env:STARRUPTURE_SAVE_PATH } else { "C:\starruptureserver\StarRupture\Saved" }),
    [string]$BackupBucket = $env:BACKUP_S3_BUCKET,
    [string]$BackupPrefix = $(if ($env:BACKUP_S3_PREFIX) { $env:BACKUP_S3_PREFIX } else { "starrupture-saves" }),
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-southeast-2" })
)

$ErrorActionPreference = "Stop"

$activityLogPath = Join-Path $ServerRoot "backup_save.log"
$backupWorkDir = Join-Path $ServerRoot "backups"

function Write-BackupLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $activityLogPath -Value $line
}

try {
    if (-not $BackupBucket) {
        throw "BACKUP_S3_BUCKET is required. Set the environment variable or pass -BackupBucket."
    }

    if (-not (Test-Path $SavePath)) {
        throw "Save path not found: $SavePath"
    }

    New-Item -ItemType Directory -Force -Path $backupWorkDir | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipPath = Join-Path $backupWorkDir "starrupture-save-$timestamp.zip"
    $s3Key = "$BackupPrefix/starrupture-save-$timestamp.zip"

    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $SavePath "*") -DestinationPath $zipPath -Force
    Write-BackupLog "Created backup archive: $zipPath"

    aws s3 cp $zipPath "s3://$BackupBucket/$s3Key" --region $Region | Out-Null
    Write-BackupLog "Uploaded backup to s3://$BackupBucket/$s3Key"

    Get-ChildItem -Path $backupWorkDir -Filter "starrupture-save-*.zip" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 5 |
        Remove-Item -Force

    exit 0
} catch {
    Write-BackupLog "Error: $($_.Exception.Message)"
    throw
}
