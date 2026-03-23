import { useQuery } from '@tanstack/react-query';
import { healthApi, credentialApi, sessionApi, identityApi } from '@/lib/api';
import { PageHeader, StatCard } from '@/components/shared/UIElements';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { DIDDisplay } from '@/components/shared/DataDisplay';
import { JsonViewer } from '@/components/shared/JsonViewer';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { useState } from 'react';
import { format } from 'date-fns';
import { Activity, Server, Fingerprint } from 'lucide-react';

export default function DashboardPage() {
  return (
    <div className="space-y-6">
      <PageHeader title="Dashboard" subtitle="System overview and quick actions" />
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <HealthCard />
        <ServerDIDCard />
        <QuickDIDTest />
      </div>
      <SessionStatsSection />
      <RecentSessionsList />
    </div>
  );
}

function HealthCard() {
  const { data, isLoading } = useQuery({
    queryKey: ['health'],
    queryFn: () => healthApi.check(),
    refetchInterval: 30000,
  });

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <div className="flex items-center gap-2.5 mb-3">
        <Activity className="h-5 w-5 text-tg-text-muted" />
        <h3 className="text-base font-medium text-tg-text-muted">System Health</h3>
      </div>
      {isLoading ? (
        <div className="h-12 animate-pulse rounded bg-tg-surface" />
      ) : data?.ok ? (
        <div className="space-y-2">
          <StatusBadge status={data.data.status} />
          <p className="text-sm text-tg-text-muted">{format(new Date(data.data.timestamp), 'PPpp')}</p>
        </div>
      ) : (
        <p className="text-sm text-tg-danger">Failed to load</p>
      )}
    </div>
  );
}

function ServerDIDCard() {
  const { data, isLoading } = useQuery({
    queryKey: ['serverDid'],
    queryFn: () => credentialApi.getServerDid(),
  });

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <div className="flex items-center gap-2.5 mb-3">
        <Server className="h-5 w-5 text-tg-text-muted" />
        <h3 className="text-base font-medium text-tg-text-muted">Server DID</h3>
      </div>
      {isLoading ? (
        <div className="h-12 animate-pulse rounded bg-tg-surface" />
      ) : data?.ok ? (
        <div className="space-y-2">
          <DIDDisplay did={data.data.did} />
          <p className="text-sm text-tg-text-muted">Network: {data.data.network}</p>
          {data.data.published_at && (
            <p className="text-sm text-tg-text-muted">Published: {format(new Date(data.data.published_at), 'PP')}</p>
          )}
        </div>
      ) : (
        <p className="text-sm text-tg-warning">Server DID not provisioned</p>
      )}
    </div>
  );
}

function QuickDIDTest() {
  const [result, setResult] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const generate = async () => {
    setLoading(true);
    try {
      const res = await identityApi.create({ publish: false });
      if (res.ok) setResult(res.data);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <div className="flex items-center gap-2.5 mb-3">
        <Fingerprint className="h-5 w-5 text-tg-text-muted" />
        <h3 className="text-base font-medium text-tg-text-muted">Quick DID Test</h3>
      </div>
      <LoadingButton onClick={generate} loading={loading} variant="outline" size="sm">Generate Test DID</LoadingButton>
      {result && <div className="mt-3"><JsonViewer data={result} collapsed={false} /></div>}
    </div>
  );
}

function SessionStatsSection() {
  const { data, isLoading } = useQuery({
    queryKey: ['sessionStats'],
    queryFn: () => sessionApi.stats(),
    refetchInterval: 30000,
  });

  if (isLoading || !data?.ok) return null;

  return (
    <div className="grid gap-4 grid-cols-2 lg:grid-cols-4">
      <StatCard label="Total Sessions" value={data.data.total} />
      <StatCard label="Active" value={data.data.active} color="text-tg-info" />
      <StatCard label="Notarized" value={data.data.notarized} color="text-tg-success" />
      <StatCard label="Failed" value={data.data.failed} color="text-tg-danger" />
    </div>
  );
}

function RecentSessionsList() {
  const { data, isLoading } = useQuery({
    queryKey: ['recentSessions'],
    queryFn: () => sessionApi.list({ limit: '5' }),
  });

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      <div className="border-b border-border px-5 py-3.5">
        <h3 className="text-base font-medium text-tg-text-muted">Recent Sessions</h3>
      </div>
      <div className="divide-y divide-border">
        {isLoading ? (
          <div className="p-5"><div className="h-20 animate-pulse rounded bg-tg-surface" /></div>
        ) : !data?.ok || data.data.sessions.length === 0 ? (
          <p className="p-5 text-sm italic text-tg-text-muted">No sessions recorded yet.</p>
        ) : (
          data.data.sessions.map((s) => (
            <div key={s.session_id} className="flex items-center justify-between px-5 py-3.5">
              <div className="flex items-center gap-3">
                <code className="text-sm font-mono text-tg-text-secondary">{s.session_id.slice(0, 12)}...</code>
                <StatusBadge status={s.status} />
              </div>
              <span className="text-sm text-tg-text-muted">{format(new Date(s.started_at), 'PP p')}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
