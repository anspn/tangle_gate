import { useMemo, useState, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import { healthApi, credentialApi, sessionApi, dashboardApi } from '@/lib/api';
import { PageHeader } from '@/components/shared/UIElements';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { DIDDisplay } from '@/components/shared/DataDisplay';
import { SessionsChart } from '@/components/dashboard/SessionsChart';
import { CredentialsChart } from '@/components/dashboard/CredentialsChart';
import { format, eachDayOfInterval, subDays } from 'date-fns';
import {
  Activity, Server, Users, ShieldCheck, FileKey, BarChart3,
  TrendingUp, UserCheck, ShieldOff, Clock,
} from 'lucide-react';

/** Fill missing dates with zero values so the chart shows every day in the range. */
function fillSessionDates(
  data: Array<{ date: string; total: number; notarized: number; failed: number; active: number }>,
): typeof data {
  const today = new Date();
  const start = subDays(today, 29);
  const allDays = eachDayOfInterval({ start, end: today }).map((d) => format(d, 'yyyy-MM-dd'));
  const map = new Map(data.map((d) => [d.date, d]));
  return allDays.map((date) => map.get(date) ?? { date, total: 0, notarized: 0, failed: 0, active: 0 });
}

function fillCredentialDates(
  data: Array<{ date: string; count: number }>,
): typeof data {
  const today = new Date();
  const start = subDays(today, 29);
  const allDays = eachDayOfInterval({ start, end: today }).map((d) => format(d, 'yyyy-MM-dd'));
  const map = new Map(data.map((d) => [d.date, d]));
  return allDays.map((date) => map.get(date) ?? { date, count: 0 });
}

export default function DashboardPage() {
  return (
    <div className="space-y-6">
      <PageHeader title="Dashboard" subtitle="System overview and analytics" />
      <StatusBar />
      <div className="grid gap-4 md:grid-cols-2">
        <UsersCard />
        <CredentialsCard />
      </div>
      <UnifiedSessionsCard />
      <ChartsSection />
    </div>
  );
}

// =============================================================================
// Status Bar — compact health + server DID
// =============================================================================

function StatusBar() {
  const health = useQuery({
    queryKey: ['health'],
    queryFn: () => healthApi.check(),
    refetchInterval: 30000,
  });

  const serverDid = useQuery({
    queryKey: ['serverDid'],
    queryFn: () => credentialApi.getServerDid(),
  });

  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-2 rounded-lg border border-border bg-card px-5 py-3 shadow-tg-sm">
      {/* Health status */}
      <div className="flex items-center gap-2">
        <Activity className="h-4 w-4 text-tg-text-muted" />
        {health.isLoading ? (
          <span className="text-sm text-tg-text-muted">Checking...</span>
        ) : health.data?.ok ? (
          <>
            <span className={`inline-block h-2.5 w-2.5 rounded-full ${
              health.data.data.status === 'ok' ? 'bg-tg-success' : 'bg-tg-warning'
            }`} />
            <span className="text-sm font-medium text-tg-text-secondary">
              {health.data.data.status === 'ok' ? 'System Healthy' : 'Degraded'}
            </span>
          </>
        ) : (
          <>
            <span className="inline-block h-2.5 w-2.5 rounded-full bg-tg-danger" />
            <span className="text-sm font-medium text-tg-danger">Unreachable</span>
          </>
        )}
      </div>

      {/* Divider */}
      <div className="hidden sm:block h-5 w-px bg-border" />

      {/* Server DID */}
      <div className="flex items-center gap-2">
        <Server className="h-4 w-4 text-tg-text-muted" />
        {serverDid.isLoading ? (
          <span className="text-sm text-tg-text-muted">Loading DID...</span>
        ) : serverDid.data?.ok ? (
          <>
            <DIDDisplay did={serverDid.data.data.did} />
            <span className="rounded bg-tg-surface px-1.5 py-0.5 text-xs font-medium text-tg-text-muted">
              {serverDid.data.data.network}
            </span>
          </>
        ) : (
          <span className="text-sm text-tg-warning">Server DID not provisioned</span>
        )}
      </div>

      {/* Divider */}
      <div className="hidden sm:block h-5 w-px bg-border" />

      {/* Current Date/Time */}
      <CurrentDateTime />
    </div>
  );
}

// =============================================================================
// Current Date/Time — live-updating clock
// =============================================================================

function CurrentDateTime() {
  const [now, setNow] = useState(new Date());

  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(id);
  }, []);

  return (
    <div className="flex items-center gap-2">
      <Clock className="h-4 w-4 text-tg-text-muted" />
      <span className="text-sm font-medium text-tg-text-secondary">
        {format(now, 'PP p')}
      </span>
    </div>
  );
}

// =============================================================================
// Users Overview Card
// =============================================================================

function UsersCard() {
  const { data, isLoading } = useQuery({
    queryKey: ['dashboardStats'],
    queryFn: () => dashboardApi.stats(),
    refetchInterval: 30000,
  });

  const users = data?.ok ? data.data.users : null;

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <div className="flex items-center gap-2.5 mb-4">
        <Users className="h-5 w-5 text-tg-text-muted" />
        <h3 className="text-base font-medium text-tg-text-muted">Users</h3>
      </div>
      {isLoading ? (
        <div className="h-16 animate-pulse rounded bg-tg-surface" />
      ) : users ? (
        <div className="grid grid-cols-2 gap-3">
          <MiniStat icon={Users} label="Total" value={users.total} />
          <MiniStat icon={UserCheck} label="Authorized" value={users.authorized} color="text-tg-success" />
          <MiniStat icon={ShieldOff} label="Unauthorized" value={users.unauthorized} color="text-tg-warning" />
          <MiniStat icon={ShieldOff} label="Revoked"
            value={(users.by_status?.did_revoked ?? 0) + (users.by_status?.deleted ?? 0)}
            color="text-tg-danger"
          />
        </div>
      ) : (
        <p className="text-sm text-tg-text-muted italic">No data available</p>
      )}
    </div>
  );
}

// =============================================================================
// Credentials Overview Card
// =============================================================================

function CredentialsCard() {
  const { data, isLoading } = useQuery({
    queryKey: ['dashboardStats'],
    queryFn: () => dashboardApi.stats(),
    refetchInterval: 30000,
  });

  const creds = data?.ok ? data.data.credentials : null;

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <div className="flex items-center gap-2.5 mb-4">
        <FileKey className="h-5 w-5 text-tg-text-muted" />
        <h3 className="text-base font-medium text-tg-text-muted">Credentials</h3>
      </div>
      {isLoading ? (
        <div className="h-16 animate-pulse rounded bg-tg-surface" />
      ) : creds ? (
        <div className="grid grid-cols-3 gap-3">
          <MiniStat icon={FileKey} label="Total" value={creds.total} />
          <MiniStat icon={ShieldCheck} label="Active" value={creds.active} color="text-tg-success" />
          <MiniStat icon={ShieldOff} label="Revoked" value={creds.revoked} color="text-tg-danger" />
        </div>
      ) : (
        <p className="text-sm text-tg-text-muted italic">No data available</p>
      )}
    </div>
  );
}

// =============================================================================
// Unified Sessions Card (stats + recent sessions table with DID column)
// =============================================================================

function UnifiedSessionsCard() {
  const stats = useQuery({
    queryKey: ['sessionStats'],
    queryFn: () => sessionApi.stats(),
    refetchInterval: 30000,
  });

  const recent = useQuery({
    queryKey: ['recentSessions'],
    queryFn: () => sessionApi.list({ limit: '5' }),
  });

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      {/* Stats row */}
      <div className="border-b border-border px-5 py-4">
        <div className="flex items-center gap-2.5 mb-3">
          <TrendingUp className="h-5 w-5 text-tg-text-muted" />
          <h3 className="text-base font-medium text-tg-text-muted">Sessions</h3>
        </div>
        {stats.isLoading ? (
          <div className="h-10 animate-pulse rounded bg-tg-surface" />
        ) : stats.data?.ok ? (
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <InlineStat label="Total" value={stats.data.data.total} />
            <InlineStat label="Active" value={stats.data.data.active} color="text-tg-info" />
            <InlineStat label="Notarized" value={stats.data.data.notarized} color="text-tg-success" />
            <InlineStat label="Failed" value={stats.data.data.failed} color="text-tg-danger" />
          </div>
        ) : null}
      </div>

      {/* Recent sessions table */}
      <div className="px-5 py-3">
        <p className="text-xs font-medium uppercase tracking-wider text-tg-text-muted mb-2">Recent Sessions</p>
      </div>
      {/* Table header */}
      <div className="hidden sm:grid grid-cols-[1fr_1fr_auto_auto] gap-4 px-5 pb-2 text-xs font-medium uppercase tracking-wider text-tg-text-muted border-b border-border">
        <span>Session ID</span>
        <span>DID</span>
        <span>Status</span>
        <span className="text-right">Started</span>
      </div>
      <div className="divide-y divide-border">
        {recent.isLoading ? (
          <div className="p-5"><div className="h-24 animate-pulse rounded bg-tg-surface" /></div>
        ) : !recent.data?.ok || recent.data.data.sessions.length === 0 ? (
          <p className="p-5 text-sm italic text-tg-text-muted">No sessions recorded yet.</p>
        ) : (
          recent.data.data.sessions.map((s) => (
            <div key={s.session_id} className="grid grid-cols-1 sm:grid-cols-[1fr_1fr_auto_auto] gap-2 sm:gap-4 items-center px-5 py-3">
              <code className="text-sm font-mono text-tg-text-secondary truncate">
                {s.session_id.slice(0, 16)}...
              </code>
              <div className="truncate">
                {s.did ? (
                  <DIDDisplay did={s.did} />
                ) : (
                  <span className="text-sm text-tg-text-muted italic">—</span>
                )}
              </div>
              <StatusBadge status={s.status} />
              <span className="text-sm text-tg-text-muted text-right whitespace-nowrap">
                {format(new Date(s.started_at), 'PP p')}
              </span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

// =============================================================================
// Activity Charts Section
// =============================================================================

function ChartsSection() {
  const { data, isLoading } = useQuery({
    queryKey: ['dashboardStats'],
    queryFn: () => dashboardApi.stats(),
    refetchInterval: 30000,
  });

  const sessionChartData = useMemo(
    () => fillSessionDates(data?.ok ? data.data.sessions_by_date : []),
    [data],
  );
  const credentialChartData = useMemo(
    () => fillCredentialDates(data?.ok ? data.data.credentials.by_date : []),
    [data],
  );

  return (
    <div className="grid gap-4 md:grid-cols-2">
      {/* Sessions Activity chart */}
      <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
        <div className="flex items-center gap-2.5 mb-4">
          <TrendingUp className="h-5 w-5 text-tg-text-muted" />
          <h3 className="text-base font-medium text-tg-text-muted">Sessions Activity</h3>
          <span className="text-xs text-tg-text-muted ml-auto">Last 30 days</span>
        </div>
        {isLoading ? (
          <div className="h-[280px] animate-pulse rounded bg-tg-surface" />
        ) : (
          <SessionsChart data={sessionChartData} />
        )}
      </div>

      {/* Credentials Issued chart */}
      <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
        <div className="flex items-center gap-2.5 mb-4">
          <BarChart3 className="h-5 w-5 text-tg-text-muted" />
          <h3 className="text-base font-medium text-tg-text-muted">Credentials Issued</h3>
          <span className="text-xs text-tg-text-muted ml-auto">Last 30 days</span>
        </div>
        {isLoading ? (
          <div className="h-[280px] animate-pulse rounded bg-tg-surface" />
        ) : (
          <CredentialsChart data={credentialChartData} />
        )}
      </div>
    </div>
  );
}

// =============================================================================
// Shared mini components
// =============================================================================

function MiniStat({ icon: Icon, label, value, color }: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  value: number;
  color?: string;
}) {
  return (
    <div className="flex items-center gap-2.5 rounded-md bg-tg-surface px-3 py-2">
      <Icon className="h-4 w-4 text-tg-text-muted shrink-0" />
      <div className="min-w-0">
        <p className="text-xs text-tg-text-muted">{label}</p>
        <p className={`text-lg font-bold tracking-tight ${color || 'text-foreground'}`}>{value}</p>
      </div>
    </div>
  );
}

function InlineStat({ label, value, color }: { label: string; value: number; color?: string }) {
  return (
    <div className="rounded-md bg-tg-surface px-3 py-2 text-center">
      <p className="text-xs text-tg-text-muted">{label}</p>
      <p className={`text-2xl font-bold tracking-tight ${color || 'text-foreground'}`}>{value}</p>
    </div>
  );
}
