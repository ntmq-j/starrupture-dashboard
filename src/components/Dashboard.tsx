"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Activity,
  Clipboard,
  Cpu,
  Eye,
  EyeOff,
  HardDrive,
  LogOut,
  MemoryStick,
  Play,
  RefreshCcw,
  RotateCw,
  Server,
  Square,
  Wifi,
} from "lucide-react";

type InstanceStatus = {
  instanceId: string;
  state: string;
  instanceType: string;
  publicIp: string;
  publicDnsName: string;
};

type ServerInfo = {
  serverName: string;
  host: string;
  port: string;
  joinAddress: string;
  password: string;
};

type GameServerStatus = {
  status: "online" | "offline" | "unknown";
  reachable: boolean;
  checkedHost: string;
  checkedPort: string;
  warning: string | null;
};

type Metrics = {
  periodMinutes: number;
  cpuPercent: number | null;
  memoryPercent: number | null;
  diskFreePercent: number | null;
  networkInBytes: number | null;
  networkOutBytes: number | null;
  diskReadBytes: number | null;
  diskWriteBytes: number | null;
  warning: string | null;
};

type LogPayload = {
  events: Array<{ timestamp: number | null; message: string }>;
  warning: string | null;
};

type Summary = {
  instance: InstanceStatus;
  serverInfo: ServerInfo;
  gameServer: GameServerStatus;
  metrics: Metrics;
  logs: LogPayload;
  refreshedAt: string;
};

export default function Dashboard() {
  const [summary, setSummary] = useState<Summary | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [action, setAction] = useState<string | null>(null);
  const [showPassword, setShowPassword] = useState(false);

  const loadData = useCallback(async (quiet = false) => {
    if (!quiet) {
      setIsLoading(true);
    }
    setError("");

    try {
      const response = await fetch("/api/summary", { cache: "no-store" });
      if (!response.ok) {
        const body = (await response.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error ?? "Unable to load dashboard data.");
      }

      setSummary((await response.json()) as Summary);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Unable to load dashboard data.");
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadData();
    const interval = window.setInterval(() => void loadData(true), 5000);
    return () => window.clearInterval(interval);
  }, [loadData]);

  const instanceTone = useMemo(() => toneForState(summary?.instance.state), [summary?.instance.state]);
  const gameTone = useMemo(() => toneForState(summary?.gameServer.status), [summary?.gameServer.status]);

  async function runAction(endpoint: "start" | "stop" | "restart") {
    setAction(endpoint);
    setError("");
    setNotice("");

    try {
      const response = await fetch(`/api/${endpoint}`, { method: "POST" });
      if (!response.ok) {
        const body = (await response.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error ?? `Unable to ${endpoint} instance.`);
      }

      setNotice(`${labelForAction(endpoint)} instance command sent.`);
      await loadData();
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : `Unable to ${endpoint} instance.`);
    } finally {
      setAction(null);
    }
  }

  async function logout() {
    await fetch("/api/auth/logout", { method: "POST" });
    window.location.href = "/login";
  }

  async function copyJoinAddress() {
    if (!summary?.serverInfo.joinAddress) {
      return;
    }

    await navigator.clipboard.writeText(summary.serverInfo.joinAddress);
    setNotice("Join address copied.");
  }

  return (
    <main className="min-h-screen px-5 py-6 sm:px-8 lg:px-10">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <header className="flex flex-col gap-4 border-b border-line pb-5 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.22em] text-cyan">StarRupture</p>
            <h1 className="mt-2 text-3xl font-semibold text-white sm:text-4xl">EC2 game server dashboard</h1>
            <p className="mt-2 text-sm text-slate-400">
              Start the EC2 instance; Windows Task Scheduler starts the game server automatically.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <button className="icon-button" onClick={() => void loadData()} title="Refresh" type="button">
              <RefreshCcw size={18} />
            </button>
            <button className="icon-button" onClick={() => void logout()} title="Log out" type="button">
              <LogOut size={18} />
            </button>
          </div>
        </header>

        {error ? <Alert tone="error" message={error} /> : null}
        {notice ? <Alert tone="notice" message={notice} /> : null}

        <section className="grid gap-5 lg:grid-cols-[1.1fr_0.9fr]">
          <div className="rounded-lg border border-line bg-panel/90 p-5 shadow-glow">
            <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
              <div className="flex items-center gap-3">
                <Server className="text-cyan" size={20} />
                <h2 className="text-lg font-semibold text-white">Instance</h2>
              </div>
              <StatusBadge className={instanceTone} value={isLoading ? "loading" : summary?.instance.state} />
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              <Metric label="EC2 current state" value={summary?.instance.state} />
              <Metric label="Game server status" value={summary?.gameServer.status} valueClass={gameToneText(summary?.gameServer.status)} />
              <Metric label="Instance type" value={summary?.instance.instanceType} />
              <Metric label="Public IP" value={summary?.instance.publicIp || "Not assigned"} />
              <Metric label="Instance ID" value={summary?.instance.instanceId} />
              <Metric label="Last refreshed" value={formatDate(summary?.refreshedAt)} />
            </div>

            {summary?.gameServer.warning ? (
              <p className="mt-4 rounded-md border border-amber-400/30 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">
                {summary.gameServer.warning}
              </p>
            ) : null}

            <div className="mt-6 grid gap-3 sm:grid-cols-3">
              <ActionButton
                label="Start Instance"
                icon={<Play size={18} />}
                busy={action === "start"}
                disabled={Boolean(action)}
                onClick={() => void runAction("start")}
              />
              <ActionButton
                label="Stop Instance"
                icon={<Square size={18} />}
                busy={action === "stop"}
                disabled={Boolean(action)}
                onClick={() => void runAction("stop")}
              />
              <ActionButton
                label="Restart Instance"
                icon={<RotateCw size={18} />}
                busy={action === "restart"}
                disabled={Boolean(action)}
                onClick={() => void runAction("restart")}
              />
            </div>
          </div>

          <div className="rounded-lg border border-line bg-panel/90 p-5 shadow-glow">
            <div className="mb-5 flex items-center gap-3">
              <Wifi className="text-ember" size={20} />
              <h2 className="text-lg font-semibold text-white">Server info</h2>
            </div>

            <div className="space-y-3">
              <Metric label="Server name" value={summary?.serverInfo.serverName} />
              <Metric label="Port" value={summary?.serverInfo.port} />
              <Metric label="Join address" value={summary?.serverInfo.joinAddress || "Unavailable"} />
              <div className="rounded-md border border-line bg-slate-950/70 p-4">
                <p className="text-xs font-medium uppercase tracking-[0.16em] text-slate-500">Password</p>
                <div className="mt-2 flex items-center justify-between gap-3">
                  <p className="min-w-0 break-all text-base font-medium text-white">
                    {showPassword
                      ? summary?.serverInfo.password || "Not configured"
                      : maskPassword(summary?.serverInfo.password)}
                  </p>
                  <button
                    className="icon-button shrink-0"
                    onClick={() => setShowPassword((value) => !value)}
                    title={showPassword ? "Hide password" : "Show password"}
                    type="button"
                  >
                    {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                  </button>
                </div>
              </div>
            </div>

            <button
              className="mt-5 flex w-full items-center justify-center gap-2 rounded-md bg-cyan px-4 py-3 font-semibold text-slate-950 transition hover:bg-cyan/90 disabled:cursor-not-allowed disabled:opacity-50"
              disabled={!summary?.serverInfo.joinAddress}
              onClick={() => void copyJoinAddress()}
              type="button"
            >
              <Clipboard size={18} />
              Copy join address
            </button>
          </div>
        </section>

        <section className="rounded-lg border border-line bg-panel/90 p-5 shadow-glow">
          <div className="mb-5 flex items-center gap-3">
            <Activity className="text-cyan" size={20} />
            <h2 className="text-lg font-semibold text-white">Instance usage</h2>
          </div>

          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <UsageCard icon={<Cpu size={18} />} label="CPU" value={formatPercent(summary?.metrics.cpuPercent)} />
            <UsageCard
              icon={<MemoryStick size={18} />}
              label="Memory"
              value={formatPercent(summary?.metrics.memoryPercent)}
            />
            <UsageCard
              icon={<HardDrive size={18} />}
              label="Disk free"
              value={formatPercent(summary?.metrics.diskFreePercent)}
            />
            <UsageCard
              icon={<Wifi size={18} />}
              label="Network in/out"
              value={`${formatBytes(summary?.metrics.networkInBytes)} / ${formatBytes(summary?.metrics.networkOutBytes)}`}
            />
          </div>

          {summary?.metrics.warning ? (
            <p className="mt-4 rounded-md border border-amber-400/30 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">
              {summary.metrics.warning}
            </p>
          ) : null}
        </section>

        <section className="rounded-lg border border-line bg-panel/90 p-5 shadow-glow">
          <div className="mb-5 flex items-center justify-between gap-4">
            <h2 className="text-lg font-semibold text-white">Realtime server logs</h2>
            <span className="text-sm text-slate-500">{summary?.logs.events.length ?? 0} events</span>
          </div>

          {summary?.logs.warning ? (
            <p className="mb-4 rounded-md border border-amber-400/30 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">
              {summary.logs.warning}
            </p>
          ) : null}

          <div className="max-h-96 overflow-auto rounded-md border border-line bg-slate-950 p-4 font-mono text-sm leading-6 text-slate-300">
            {summary?.logs.events.length ? (
              summary.logs.events.map((event, index) => (
                <p className="border-b border-line/60 py-2 last:border-b-0" key={`${event.timestamp}-${index}`}>
                  <span className="mr-3 text-slate-500">
                    {event.timestamp ? new Date(event.timestamp).toLocaleString() : "no timestamp"}
                  </span>
                  {event.message}
                </p>
              ))
            ) : (
              <p className="text-slate-500">No log events to show.</p>
            )}
          </div>
        </section>
      </div>
    </main>
  );
}

function Metric({
  label,
  value,
  valueClass = "text-white",
}: {
  label: string;
  value?: string | null;
  valueClass?: string;
}) {
  return (
    <div className="rounded-md border border-line bg-slate-950/70 p-4">
      <p className="text-xs font-medium uppercase tracking-[0.16em] text-slate-500">{label}</p>
      <p className={`mt-2 min-h-6 break-words text-base font-medium ${valueClass}`}>{value || "Loading..."}</p>
    </div>
  );
}

function UsageCard({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
  return (
    <div className="rounded-md border border-line bg-slate-950/70 p-4">
      <div className="flex items-center gap-2 text-slate-400">
        {icon}
        <p className="text-xs font-medium uppercase tracking-[0.16em]">{label}</p>
      </div>
      <p className="mt-3 text-2xl font-semibold text-white">{value}</p>
    </div>
  );
}

function ActionButton({
  label,
  icon,
  busy,
  disabled,
  onClick,
}: {
  label: string;
  icon: React.ReactNode;
  busy: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button
      className="flex min-h-12 items-center justify-center gap-2 rounded-md border border-line bg-slate-950 px-4 py-3 text-sm font-semibold text-white transition hover:border-cyan hover:text-cyan disabled:cursor-not-allowed disabled:opacity-50"
      disabled={disabled}
      onClick={onClick}
      type="button"
    >
      {busy ? <RefreshCcw className="animate-spin" size={18} /> : icon}
      {busy ? "Working..." : label}
    </button>
  );
}

function StatusBadge({ className, value }: { className: string; value?: string | null }) {
  return (
    <span className={`rounded-full border px-3 py-1 text-sm font-medium ${className}`}>
      {value ?? "unknown"}
    </span>
  );
}

function Alert({ message, tone }: { message: string; tone: "error" | "notice" }) {
  const classes =
    tone === "error"
      ? "border-red-500/30 bg-red-500/10 text-red-100"
      : "border-cyan/30 bg-cyan/10 text-cyan";

  return <p className={`rounded-md border px-4 py-3 text-sm ${classes}`}>{message}</p>;
}

function maskPassword(value?: string | null) {
  if (!value) {
    return "Not configured";
  }

  return "*".repeat(Math.min(Math.max(value.length, 8), 18));
}

function labelForAction(action: "start" | "stop" | "restart") {
  return action[0].toUpperCase() + action.slice(1);
}

function toneForState(value?: string) {
  switch (value) {
    case "running":
    case "online":
      return "border-emerald-400/30 bg-emerald-400/10 text-emerald-200";
    case "stopped":
    case "offline":
      return "border-red-400/30 bg-red-400/10 text-red-200";
    case "pending":
    case "stopping":
      return "border-amber-400/30 bg-amber-400/10 text-amber-200";
    default:
      return "border-slate-400/30 bg-slate-400/10 text-slate-200";
  }
}

function gameToneText(value?: string) {
  switch (value) {
    case "online":
      return "text-emerald-200";
    case "offline":
      return "text-red-200";
    default:
      return "text-slate-200";
  }
}

function formatDate(value?: string) {
  if (!value) {
    return null;
  }

  return new Date(value).toLocaleString();
}

function formatPercent(value?: number | null) {
  if (value === null || value === undefined) {
    return "N/A";
  }

  return `${value.toFixed(1)}%`;
}

function formatBytes(value?: number | null) {
  if (value === null || value === undefined) {
    return "N/A";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = value;
  let unitIndex = 0;

  while (amount >= 1024 && unitIndex < units.length - 1) {
    amount /= 1024;
    unitIndex += 1;
  }

  return `${amount.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}
