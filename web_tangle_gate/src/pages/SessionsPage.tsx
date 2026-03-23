import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { RefreshCw, Download } from 'lucide-react';
import { format } from 'date-fns';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { PageHeader, StatCard, EmptyState } from '@/components/shared/UIElements';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { DIDDisplay, HashDisplay } from '@/components/shared/DataDisplay';
import { sessionApi, downloadSession } from '@/lib/api';
import { useAuthStore } from '@/stores/auth';
import type { Session } from '@/types';

export default function SessionsPage() {
  const role = useAuthStore((s) => s.role);

  return (
    <div className="space-y-6">
      <PageHeader title="Sessions" subtitle="Browse and inspect recorded terminal sessions" />
      {role === 'admin' && <SessionStatsSection />}
      <SessionTable />
    </div>
  );
}

function SessionStatsSection() {
  const { data } = useQuery({
    queryKey: ['sessionStats'],
    queryFn: () => sessionApi.stats(),
  });

  if (!data?.ok) return null;

  return (
    <div className="grid gap-4 grid-cols-2 lg:grid-cols-4">
      <StatCard label="Total" value={data.data.total} />
      <StatCard label="Active" value={data.data.active} color="text-tg-info" />
      <StatCard label="Notarized" value={data.data.notarized} color="text-tg-success" />
      <StatCard label="Failed" value={data.data.failed} color="text-tg-danger" />
    </div>
  );
}

function SessionTable() {
  const queryClient = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['sessions'],
    queryFn: () => sessionApi.list(),
  });
  const [selectedId, setSelectedId] = useState<string | null>(null);

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      <div className="flex items-center justify-between border-b border-border px-5 py-3">
        <h3 className="text-sm font-medium text-tg-text-muted">Session History</h3>
        <Button variant="ghost" size="sm" onClick={() => queryClient.invalidateQueries({ queryKey: ['sessions'] })}>
          <RefreshCw className="mr-1.5 h-3.5 w-3.5" /> Refresh
        </Button>
      </div>

      {isLoading ? (
        <div className="p-5"><div className="h-32 animate-pulse rounded bg-tg-surface" /></div>
      ) : !data?.ok || data.data.sessions.length === 0 ? (
        <EmptyState message="No sessions recorded yet." />
      ) : (
        <div className="overflow-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border text-left text-xs text-tg-text-muted">
                <th className="px-5 py-2">Session</th>
                <th className="px-5 py-2">DID</th>
                <th className="px-5 py-2">Started</th>
                <th className="px-5 py-2">Commands</th>
                <th className="px-5 py-2">Status</th>
                <th className="px-5 py-2">Hash</th>
                <th className="px-5 py-2">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {data.data.sessions.map((s) => (
                <tr key={s.session_id} className="hover:bg-tg-surface transition-colors">
                  <td className="px-5 py-3 font-mono text-xs text-tg-text-secondary">{s.session_id.slice(0, 12)}...</td>
                  <td className="px-5 py-3"><DIDDisplay did={s.did} /></td>
                  <td className="px-5 py-3 text-xs text-tg-text-muted">{format(new Date(s.started_at), 'PP p')}</td>
                  <td className="px-5 py-3 text-xs">{s.command_count}</td>
                  <td className="px-5 py-3"><StatusBadge status={s.status} /></td>
                  <td className="px-5 py-3 font-mono text-xs text-tg-text-muted">
                    {s.notarization_hash ? `${s.notarization_hash.slice(0, 12)}...` : '—'}
                  </td>
                  <td className="px-5 py-3">
                    <Button variant="ghost" size="sm" onClick={() => setSelectedId(s.session_id)}>View</Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selectedId && (
        <SessionDetailDialog sessionId={selectedId} onClose={() => setSelectedId(null)} />
      )}
    </div>
  );
}

function SessionDetailDialog({ sessionId, onClose }: { sessionId: string; onClose: () => void }) {
  const { data, isLoading, error } = useQuery({
    queryKey: ['session', sessionId],
    queryFn: () => sessionApi.get(sessionId),
  });
  const [downloading, setDownloading] = useState(false);

  const handleDownload = async () => {
    setDownloading(true);
    try {
      await downloadSession(sessionId);
      toast.success('Session history downloaded');
    } catch {
      toast.error('Download failed');
    } finally {
      setDownloading(false);
    }
  };

  const session: Session | undefined = data?.ok ? data.data : undefined;

  return (
    <Dialog open onOpenChange={() => onClose()}>
      <DialogContent className="bg-card border-border max-w-2xl max-h-[80vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-3">
            <span className="font-mono text-sm">{sessionId}</span>
            {session && <StatusBadge status={session.status} />}
          </DialogTitle>
        </DialogHeader>

        {isLoading ? (
          <div className="h-32 animate-pulse rounded bg-tg-surface" />
        ) : error || !session ? (
          <p className="text-sm text-tg-danger">Failed to load session details.</p>
        ) : (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span className="text-xs text-tg-text-muted">DID</span>
                <div className="mt-1"><DIDDisplay did={session.did} /></div>
              </div>
              <div>
                <span className="text-xs text-tg-text-muted">User ID</span>
                <p className="mt-1 font-mono text-xs text-tg-text-secondary">{session.user_id}</p>
              </div>
              <div>
                <span className="text-xs text-tg-text-muted">Started</span>
                <p className="mt-1 text-xs">{format(new Date(session.started_at), 'PPpp')}</p>
              </div>
              <div>
                <span className="text-xs text-tg-text-muted">Ended</span>
                <p className="mt-1 text-xs">{session.ended_at ? format(new Date(session.ended_at), 'PPpp') : '—'}</p>
              </div>
            </div>

            {session.notarization_hash && (
              <div>
                <span className="text-xs text-tg-text-muted">Notarization Hash</span>
                <div className="mt-1"><HashDisplay hash={session.notarization_hash} /></div>
              </div>
            )}
            {session.on_chain_id && (
              <div>
                <span className="text-xs text-tg-text-muted">On-Chain ID</span>
                <p className="mt-1 font-mono text-xs text-tg-text-secondary break-all">{session.on_chain_id}</p>
              </div>
            )}
            {session.error && (
              <div>
                <span className="text-xs text-tg-text-muted">Error</span>
                <p className="mt-1 text-xs text-tg-danger">{session.error}</p>
              </div>
            )}

            {session.commands && session.commands.length > 0 && (
              <div>
                <span className="text-xs text-tg-text-muted">Command History ({session.commands.length})</span>
                <pre className="mt-1 max-h-72 overflow-auto rounded bg-tg-surface p-3 font-mono text-xs text-tg-text-secondary">
                  {session.commands.map((c, i) => (
                    `${c.timestamp ? `[${c.timestamp}] ` : ''}${c.command}\n`
                  )).join('')}
                </pre>
              </div>
            )}
          </div>
        )}

        <DialogFooter>
          <LoadingButton variant="outline" size="sm" loading={downloading} onClick={handleDownload}>
            <Download className="mr-1.5 h-3.5 w-3.5" /> Download History
          </LoadingButton>
          <Button variant="ghost" size="sm" onClick={onClose}>Close</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
