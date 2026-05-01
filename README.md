# StarRupture Dashboard

A secure Next.js TypeScript App Router dashboard for a StarRupture Dedicated Server running on an AWS EC2 Windows instance.

The dashboard is intended to run on Vercel. The EC2 Windows instance runs the game server. Pressing **Start Instance** starts EC2; Windows Task Scheduler then starts `StarRuptureServerEOS.exe` automatically.

## Features

- Password login using `DASHBOARD_PASSWORD` and an httpOnly session cookie.
- EC2 instance controls: start, stop, restart/reboot.
- Stop uses AWS Systems Manager Run Command to gracefully stop the game server, backup saves, then stop EC2.
- Instance status: state, instance type, public IP, instance ID.
- Game server status: online/offline health check after EC2 is running.
- Server info: name, host, port, join address, password with show/hide, copy join address.
- Realtime-style server logs by polling CloudWatch Logs every 5 seconds.
- Instance usage monitor from CloudWatch metrics: CPU, network, disk IO, plus memory/disk free when CloudWatch Agent is installed.
- Windows ops scripts for auto-start, save backup, and idle auto-shutdown.
- No terminate-instance action.

## Architecture

```text
Browser -> Vercel Next.js Dashboard -> AWS SDK server-side -> EC2 Windows
                                                   |
                                                   +-> CloudWatch Logs/Metrics
                                                   +-> SSM SecureString server password

EC2 Windows boot -> Task Scheduler -> start_server.bat -> StarRuptureServerEOS.exe
EC2 Windows timer -> auto_shutdown.ps1 -> backup_save.ps1 -> S3 -> stop EC2 after 10 idle minutes
```

## Local Development

```bash
npm install
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3000` and sign in with `DASHBOARD_PASSWORD`.

## Environment Variables

Set these in `.env.local` for local development and in Vercel project settings for deployment:

```bash
AWS_REGION=ap-southeast-2
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
EC2_INSTANCE_ID=

SERVER_NAME=StarRupture Dedicated Server
SERVER_HOST=
SERVER_PORT=7777
SERVER_PASSWORD=
SSM_SERVER_PASSWORD_PARAM=

DASHBOARD_PASSWORD=

CLOUDWATCH_LOG_GROUP=
CLOUDWATCH_LOG_STREAM=
CLOUDWATCH_AGENT_NAMESPACE=CWAgent

BACKUP_S3_BUCKET=
BACKUP_S3_PREFIX=starrupture-saves
WINDOWS_SHUTDOWN_SCRIPT_PATH=C:\starruptureserver\shutdown_now.ps1
```

Notes:

- `SERVER_HOST` can be empty. The dashboard falls back to the EC2 public IP.
- `SERVER_PASSWORD` can be empty if `SSM_SERVER_PASSWORD_PARAM` points to an SSM SecureString.
- Memory and disk-free usage require the CloudWatch Agent on Windows. EC2 CPU/network/disk IO metrics work through standard CloudWatch.
- `BACKUP_S3_BUCKET` and `BACKUP_S3_PREFIX` are primarily used by the Windows backup script, not by Vercel.

## API Routes

- `POST /api/auth/login`
- `POST /api/auth/logout`
- `GET /api/status`
- `GET /api/game-status`
- `GET /api/metrics`
- `GET /api/summary`
- `POST /api/start`
- `POST /api/stop`
- `POST /api/restart`
- `GET /api/server-info`
- `GET /api/logs`

## AWS IAM

Create an IAM user or role for Vercel with the smallest useful scope. Restrict resources to the target instance, SSM parameter, and log stream where possible.

Example dashboard policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:SendCommand"],
      "Resource": [
        "arn:aws:ec2:ap-southeast-2:ACCOUNT_ID:instance/YOUR_INSTANCE_ID",
        "arn:aws:ssm:ap-southeast-2::document/AWS-RunPowerShellScript"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["cloudwatch:GetMetricData"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:ap-southeast-2:ACCOUNT_ID:parameter/YOUR_PARAMETER_NAME"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:GetLogEvents"],
      "Resource": "arn:aws:logs:ap-southeast-2:ACCOUNT_ID:log-group:YOUR_LOG_GROUP:log-stream:YOUR_LOG_STREAM"
    }
  ]
}
```

Do not grant `ec2:TerminateInstances`; the dashboard does not implement termination.

The EC2 Windows instance also needs an instance profile or AWS CLI credentials for:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:StopInstances"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::YOUR_BACKUP_BUCKET/starrupture-saves/*"
    }
  ]
}
```

For SSM Run Command, the EC2 instance role also needs the AWS managed policy:

```text
AmazonSSMManagedInstanceCore
```

Windows Server EC2 AMIs usually include the SSM Agent. Check Systems Manager -> Fleet Manager or Managed Nodes to confirm the instance appears online.

## Vercel Deploy

1. Import this project in Vercel.
2. Add all dashboard environment variables in Project Settings.
3. Keep AWS keys server-side only. Do not expose them as `NEXT_PUBLIC_*`.
4. Use a strong `DASHBOARD_PASSWORD`.
5. Redeploy after changing environment variables.

## EC2 Windows Setup

Copy these files to the Windows instance:

```text
ops/windows/start_server.bat      -> C:\starruptureserver\start_server.bat
ops/windows/start_server.ps1      -> C:\starruptureserver\start_server.ps1
ops/windows/stop_server.ps1       -> C:\starruptureserver\stop_server.ps1
ops/windows/auto_shutdown.ps1     -> C:\starruptureserver\auto_shutdown.ps1
ops/windows/shutdown_now.ps1      -> C:\starruptureserver\shutdown_now.ps1
ops/windows/backup_save.ps1       -> C:\starruptureserver\backup_save.ps1
```

### Firewall

Allow StarRupture traffic on port `7777`:

```powershell
New-NetFirewallRule -DisplayName "StarRupture UDP 7777" -Direction Inbound -Protocol UDP -LocalPort 7777 -Action Allow
New-NetFirewallRule -DisplayName "StarRupture TCP 7777" -Direction Inbound -Protocol TCP -LocalPort 7777 -Action Allow
```

Also allow inbound UDP/TCP `7777` in the EC2 security group.

### Auto-start Game Server

Create a Task Scheduler task:

- Trigger: At startup.
- Action: Start a program.
- Program: `C:\starruptureserver\start_server.bat`.
- Run whether user is logged on or not.
- Run with highest privileges.

`start_server.bat` runs:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\starruptureserver\start_server.ps1 -ServerRoot C:\starruptureserver -Port 7777
```

`start_server.ps1` starts a lightweight supervisor that allocates a console, launches `StarRuptureServerEOS.exe -Log -port=7777`, writes the game server PID to `C:\starruptureserver\starrupture_server.pid`, watches for `C:\starruptureserver\starrupture_server.stop`, and sends Ctrl+C to the game server from the same console when a stop request appears.

### Auto-shutdown After Idle

Create a Task Scheduler task:

- Trigger: Repeat every 1 minute indefinitely.
- Action program: `powershell.exe`.
- Arguments:

```powershell
-ExecutionPolicy Bypass -File C:\starruptureserver\auto_shutdown.ps1 -InstanceId i-xxxxxxxxxxxxxxxxx -Region ap-southeast-2
```

The script:

- Reads the newest log file from `C:\starruptureserver\StarRupture\Saved\Logs`.
- Tracks offset and player count in `C:\starruptureserver\auto_shutdown_state.json`.
- Increments player count estimate on `Join succeeded`.
- Decrements the player count estimate on `UnregisterPlayers` or `ConnectionTimeout`.
- Treats `ControlChannelClose` and `Removed address` as connection activity only, because StarRupture can log those alongside `UnregisterPlayers` for the same player.
- Starts the idle timer only when the count estimate is 0.
- After 10 idle minutes, sends Ctrl+C to the game server with `stop_server.ps1`.
- `stop_server.ps1` creates `C:\starruptureserver\starrupture_server.stop`; the supervisor started by `start_server.ps1` sees that file and sends Ctrl+C from the same console, then `stop_server.ps1` waits up to 120 seconds for StarRupture to save and exit.
- Then `auto_shutdown.ps1` runs `backup_save.ps1`, then:

```powershell
aws ec2 stop-instances --instance-ids $InstanceId --region ap-southeast-2
```

- Writes activity to `C:\starruptureserver\auto_shutdown.log`.

### Manual Dashboard Stop

The dashboard **Stop Instance** button sends an SSM Run Command to run:

```text
C:\starruptureserver\shutdown_now.ps1
```

That script:

- Sends Ctrl+C to StarRupture through the `start_server.ps1` supervisor by creating a stop-request file with `stop_server.ps1`.
- Waits up to 120 seconds for the server to save and exit.
- Runs `backup_save.ps1`.
- Stops the EC2 instance with `aws ec2 stop-instances`.
- Writes `C:\starruptureserver\shutdown_now.log`.

If the instance is already stopped, the API falls back to direct EC2 stop.

You can manually test graceful server exit without stopping the instance:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\starruptureserver\stop_server.ps1 -ServerRoot C:\starruptureserver -TimeoutSeconds 120
```

In StarRupture logs, a successful Ctrl+C shutdown should include lines like:

```text
Engine exit requested (reason: ConsoleCtrl RequestExit)
Log file closed
```

### Save Backups

Set these Windows environment variables or pass equivalent parameters:

```powershell
setx BACKUP_S3_BUCKET "your-backup-bucket"
setx BACKUP_S3_PREFIX "starrupture-saves"
setx STARRUPTURE_SAVE_PATH "C:\starruptureserver\StarRupture\Saved"
setx AWS_REGION "ap-southeast-2"
```

`backup_save.ps1` compresses the save directory, uploads it to S3, writes `C:\starruptureserver\backup_save.log`, and keeps the 5 latest local zip files.

By default, `backup_save.ps1` excludes the `Logs` directory because the active StarRupture log file is often locked while the server is running. To exclude more directories:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\starruptureserver\backup_save.ps1 -ExcludeDirectories Logs,Crashes
```

## CloudWatch Logs

Install and configure the Amazon CloudWatch Agent on Windows to ship:

```text
C:\starruptureserver\StarRupture\Saved\Logs\*.log
```

Set `CLOUDWATCH_LOG_GROUP` and `CLOUDWATCH_LOG_STREAM` in Vercel. If either value is missing, `GET /api/logs` returns an empty event list with a warning instead of failing the dashboard.

## CloudWatch Agent Metrics

Standard EC2 metrics provide CPU, network, and disk IO. For RAM and disk-free percentage, install CloudWatch Agent and publish:

- `mem_used_percent`
- `LogicalDisk % Free Space`

Use `CLOUDWATCH_AGENT_NAMESPACE=CWAgent` unless you changed the namespace.
