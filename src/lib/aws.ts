import {
  DescribeInstancesCommand,
  EC2Client,
  RebootInstancesCommand,
  StartInstancesCommand,
  StopInstancesCommand,
} from "@aws-sdk/client-ec2";
import {
  CloudWatchClient,
  GetMetricDataCommand,
  ListMetricsCommand,
  type Dimension,
  type MetricDataQuery,
  type StandardUnit,
} from "@aws-sdk/client-cloudwatch";
import { CloudWatchLogsClient, GetLogEventsCommand } from "@aws-sdk/client-cloudwatch-logs";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";
import { Socket } from "net";

function region() {
  const value = process.env.AWS_REGION;
  if (!value) {
    throw new Error("AWS_REGION is not configured.");
  }

  return value;
}

function instanceId() {
  const value = process.env.EC2_INSTANCE_ID;
  if (!value) {
    throw new Error("EC2_INSTANCE_ID is not configured.");
  }

  return value;
}

export function ec2Client() {
  return new EC2Client({ region: region() });
}

export function cloudWatchLogsClient() {
  return new CloudWatchLogsClient({ region: region() });
}

export function cloudWatchClient() {
  return new CloudWatchClient({ region: region() });
}

export function ssmClient() {
  return new SSMClient({ region: region() });
}

export async function getInstanceStatus() {
  const response = await ec2Client().send(
    new DescribeInstancesCommand({
      InstanceIds: [instanceId()],
    }),
  );

  const instance = response.Reservations?.flatMap((reservation) => reservation.Instances ?? [])[0];
  if (!instance) {
    throw new Error(`Instance ${instanceId()} was not found.`);
  }

  return {
    instanceId: instance.InstanceId ?? instanceId(),
    state: instance.State?.Name ?? "unknown",
    instanceType: instance.InstanceType ?? "unknown",
    publicIp: instance.PublicIpAddress ?? "",
    publicDnsName: instance.PublicDnsName ?? "",
  };
}

export async function startInstance() {
  await ec2Client().send(new StartInstancesCommand({ InstanceIds: [instanceId()] }));
}

export async function stopInstance() {
  await ec2Client().send(new StopInstancesCommand({ InstanceIds: [instanceId()] }));
}

export async function restartInstance() {
  await ec2Client().send(new RebootInstancesCommand({ InstanceIds: [instanceId()] }));
}

export async function getServerPassword() {
  const parameterName = process.env.SSM_SERVER_PASSWORD_PARAM;
  if (parameterName) {
    const response = await ssmClient().send(
      new GetParameterCommand({
        Name: parameterName,
        WithDecryption: true,
      }),
    );

    return response.Parameter?.Value ?? "";
  }

  return process.env.SERVER_PASSWORD ?? "";
}

export async function getServerInfo() {
  const password = await getServerPassword();
  const fallbackStatus = process.env.SERVER_HOST ? null : await getInstanceStatus();
  const host = process.env.SERVER_HOST || fallbackStatus?.publicIp || "";
  const port = process.env.SERVER_PORT || "7777";

  return {
    serverName: process.env.SERVER_NAME || "StarRupture Dedicated Server",
    host,
    port,
    joinAddress: host ? `${host}:${port}` : "",
    password,
  };
}

export async function getGameServerStatus() {
  const status = await getInstanceStatus();

  if (status.state !== "running") {
    return {
      status: "offline",
      reachable: false,
      checkedHost: "",
      checkedPort: process.env.SERVER_PORT || "7777",
      warning: "EC2 instance is not running.",
    };
  }

  const info = await getServerInfo();
  if (!info.host) {
    return {
      status: "unknown",
      reachable: false,
      checkedHost: "",
      checkedPort: info.port,
      warning: "No SERVER_HOST or EC2 public IP is available yet.",
    };
  }

  const reachable = await canConnect(info.host, Number(info.port), 2500);

  return {
    status: reachable ? "online" : "offline",
    reachable,
    checkedHost: info.host,
    checkedPort: info.port,
    warning: reachable
      ? null
      : "TCP port check failed. If StarRupture only exposes UDP, use logs as the source of truth.",
  };
}

export async function getInstanceMetrics() {
  const endTime = new Date();
  const startTime = new Date(endTime.getTime() - 60 * 60 * 1000);
  const customNamespace = process.env.CLOUDWATCH_AGENT_NAMESPACE || "CWAgent";
  const [memoryDimensions, diskDimensions] = await Promise.all([
    findMetricDimensions(customNamespace, "mem_used_percent"),
    findMetricDimensions(customNamespace, "LogicalDisk % Free Space", (dimensions) =>
      dimensions.some((dimension) => dimension.Name === "instance" && dimension.Value === "C:"),
    ),
  ]);
  const memoryQueryDimensions = memoryDimensions ?? [{ Name: "InstanceId", Value: instanceId() }];
  const diskQueryDimensions =
    diskDimensions ?? [
      { Name: "objectname", Value: "LogicalDisk" },
      { Name: "InstanceId", Value: instanceId() },
      { Name: "instance", Value: "C:" },
    ];

  const metricDataQueries: MetricDataQuery[] = [
    metricQuery("cpu", "AWS/EC2", "CPUUtilization", "Percent", "Average"),
    metricQuery("networkIn", "AWS/EC2", "NetworkIn", "Bytes", "Sum"),
    metricQuery("networkOut", "AWS/EC2", "NetworkOut", "Bytes", "Sum"),
    metricQuery("diskReadBytes", "AWS/EC2", "DiskReadBytes", "Bytes", "Sum"),
    metricQuery("diskWriteBytes", "AWS/EC2", "DiskWriteBytes", "Bytes", "Sum"),
  ];

  metricDataQueries.push(
    metricQuery("memory", customNamespace, "mem_used_percent", "Percent", "Average", memoryQueryDimensions),
    metricQuery("disk", customNamespace, "LogicalDisk % Free Space", "Percent", "Average", diskQueryDimensions),
  );

  const response = await cloudWatchClient().send(
    new GetMetricDataCommand({
      StartTime: startTime,
      EndTime: endTime,
      MetricDataQueries: metricDataQueries,
    }),
  );

  const values = Object.fromEntries(
    (response.MetricDataResults ?? []).map((result) => [
      result.Id ?? "",
      {
        latest: latestValue(result.Values),
        label: result.Label ?? result.Id ?? "",
      },
    ]),
  );

  return {
    periodMinutes: 60,
    cpuPercent: values.cpu?.latest ?? null,
    memoryPercent: values.memory?.latest ?? null,
    diskFreePercent: values.disk?.latest ?? null,
    networkInBytes: values.networkIn?.latest ?? null,
    networkOutBytes: values.networkOut?.latest ?? null,
    diskReadBytes: values.diskReadBytes?.latest ?? null,
    diskWriteBytes: values.diskWriteBytes?.latest ?? null,
    warning: buildMetricsWarning({
      memoryMetricFound: Boolean(memoryDimensions),
      diskMetricFound: Boolean(diskDimensions),
      memoryValue: values.memory?.latest ?? null,
      diskValue: values.disk?.latest ?? null,
    }),
  };
}

export async function getLogEvents() {
  const logGroupName = process.env.CLOUDWATCH_LOG_GROUP;
  const logStreamName = process.env.CLOUDWATCH_LOG_STREAM;

  if (!logGroupName || !logStreamName) {
    return {
      events: [],
      warning: "CloudWatch logs are not configured. Set CLOUDWATCH_LOG_GROUP and CLOUDWATCH_LOG_STREAM.",
    };
  }

  const response = await cloudWatchLogsClient().send(
    new GetLogEventsCommand({
      logGroupName,
      logStreamName,
      limit: 100,
      startFromHead: false,
    }),
  );

  return {
    events:
      response.events?.map((event) => ({
        timestamp: event.timestamp ?? null,
        message: event.message ?? "",
      })) ?? [],
    warning: null,
  };
}

export async function getDashboardSummary() {
  const [instance, serverInfo, gameServer, metrics, logs] = await Promise.all([
    getInstanceStatus(),
    getServerInfo(),
    getGameServerStatus(),
    getInstanceMetrics(),
    getLogEvents(),
  ]);

  return {
    instance,
    serverInfo,
    gameServer,
    metrics,
    logs,
    refreshedAt: new Date().toISOString(),
  };
}

function metricQuery(
  id: string,
  namespace: string,
  metricName: string,
  unit: StandardUnit,
  stat: string,
  dimensions = [{ Name: "InstanceId", Value: instanceId() }],
): MetricDataQuery {
  return {
    Id: id,
    MetricStat: {
      Metric: {
        Namespace: namespace,
        MetricName: metricName,
        Dimensions: dimensions,
      },
      Period: 300,
      Stat: stat,
      Unit: unit,
    },
    ReturnData: true,
  };
}

async function findMetricDimensions(
  namespace: string,
  metricName: string,
  predicate: (dimensions: Dimension[]) => boolean = () => true,
) {
  try {
    const response = await cloudWatchClient().send(
      new ListMetricsCommand({
        Namespace: namespace,
        MetricName: metricName,
        Dimensions: [{ Name: "InstanceId", Value: instanceId() }],
      }),
    );

    const metric = response.Metrics?.find((candidate) => {
      const dimensions = candidate.Dimensions ?? [];
      return dimensions.some((dimension) => dimension.Name === "InstanceId" && dimension.Value === instanceId())
        && predicate(dimensions);
    });

    return normalizeDimensions(metric?.Dimensions);
  } catch {
    return null;
  }
}

function normalizeDimensions(dimensions?: Dimension[]) {
  const normalized =
    dimensions
      ?.filter((dimension): dimension is { Name: string; Value: string } =>
        Boolean(dimension.Name && dimension.Value),
      )
      .map((dimension) => ({ Name: dimension.Name, Value: dimension.Value })) ?? [];

  return normalized.length ? normalized : null;
}

function buildMetricsWarning({
  memoryMetricFound,
  diskMetricFound,
  memoryValue,
  diskValue,
}: {
  memoryMetricFound: boolean;
  diskMetricFound: boolean;
  memoryValue: number | null;
  diskValue: number | null;
}) {
  const missing = [];

  if (!memoryMetricFound) {
    missing.push("memory metric");
  } else if (memoryValue === null) {
    missing.push("recent memory datapoint");
  }

  if (!diskMetricFound) {
    missing.push("disk free metric");
  } else if (diskValue === null) {
    missing.push("recent disk free datapoint");
  }

  if (!missing.length) {
    return null;
  }

  return `CloudWatch Agent is running, but the dashboard could not find ${missing.join(" and ")} yet.`;
}

function latestValue(values?: number[]) {
  if (!values?.length) {
    return null;
  }

  return values[values.length - 1] ?? null;
}

function canConnect(host: string, port: number, timeoutMs: number) {
  return new Promise<boolean>((resolve) => {
    const socket = new Socket();
    let settled = false;

    function finish(value: boolean) {
      if (settled) {
        return;
      }

      settled = true;
      socket.destroy();
      resolve(value);
    }

    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
    socket.connect(port, host);
  });
}
