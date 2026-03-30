import { useState, useMemo } from 'react';
import { useQuery, useQueryClient, useMutation } from '@tanstack/react-query';
import { toast } from 'sonner';
import { RefreshCw, Download, Square, RotateCcw, ChevronLeft, ChevronRight } from 'lucide-react';
import { format } from 'date-fns';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { PageHeader, StatCard, EmptyState } from '@/components/shared/UIElements';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { DIDDisplay, CopyableField } from '@/components/shared/DataDisplay';
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
  const role = useAuthStore((s) => s.role);
  const { data, isLoading } = useQuery({
    queryKey: ['sessions'],
    queryFn: () => sessionApi.list(),
  });
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [page, setPage] = useState(0);
  const PAGE_SIZE = 15;

  const allSessions = data?.ok ? data.data.sessions : [];
  const totalPages = Math.max(1, Math.ceil(allSessions.length / PAGE_SIZE));
  const pagedSessions = useMemo(
    () => allSessions.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE),
    [allSessions, page],
  );

  const terminateMutation = useMutation({
    mutationFn: (id: string) => sessionApi.terminate(id),
    onSuccess: (res) => {
      if (res.ok) {
        toast.success(res.data.message || 'Session terminated');
        queryClient.invalidateQueries({ queryKey: ['sessions'] });
        queryClient.invalidateQueries({ queryKey: ['sessionStats'] });
      } else {
        toast.error((res.data as any).message || 'Failed to terminate session');
      }
    },
    onError: () => toast.error('Connection failed'),
  });

  const retryMutation = useMutation({
    mutationFn: (id: string) => sessionApi.retryNotarization(id),
    onSuccess: (res) => {
      if (res.ok) {
        toast.success(res.data.message || 'Notarization succeeded');
        queryClient.invalidateQueries({ queryKey: ['sessions'] });
        queryClient.invalidateQueries({ queryKey: ['sessionStats'] });
      } else {
        toast.error((res.data as any).message || 'Notarization failed');
      }
    },
    onError: () => toast.error('Connection failed'),
  });

  const handleTerminate = (id: string) => {
    terminateMutation.mutate(id);
  };

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      <div className="flex items-center justify-between border-b border-border px-5 py-3">
        <h3 className="text-sm font-medium text-tg-text-muted">Session History</h3>
        <div className="flex items-center gap-2">
          {allSessions.length > PAGE_SIZE && (
            <div className="flex items-center gap-1 text-xs text-tg-text-muted">
              <Button variant="ghost" size="sm" disabled={page === 0} onClick={() => setPage(page - 1)}>
                <ChevronLeft className="h-3.5 w-3.5" />
              </Button>
              <span>{page + 1} / {totalPages}</span>
              <Button variant="ghost" size="sm" disabled={page >= totalPages - 1} onClick={() => setPage(page + 1)}>
                <ChevronRight className="h-3.5 w-3.5" />
              </Button>
            </div>
          )}
          <Button variant="ghost" size="sm" onClick={() => queryClient.invalidateQueries({ queryKey: ['sessions'] })}>
            <RefreshCw className="mr-1.5 h-3.5 w-3.5" /> Refresh
          </Button>
        </div>
      </div>

      {isLoading ? (
        <div className="p-5"><div className="h-32 animate-pulse rounded bg-tg-surface" /></div>
      ) : !data?.ok || allSessions.length === 0 ? (
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
              {pagedSessions.map((s) => (
                <tr key={s.session_id} className="hover:bg-tg-surface transition-colors">
                  <td className="px-5 py-3 font-mono text-xs text-tg-text-secondary">{s.session_id.slice(0, 12)}...</td>
                  <td className="px-5 py-3"><DIDDisplay did={s.did} /></td>
                  <td className="px-5 py-3 text-xs text-tg-text-muted">{format(new Date(s.started_at), 'PP p')}</td>
                  <td className="px-5 py-3 text-xs">{s.command_count}</td>
                  <td className="px-5 py-3"><StatusBadge status={s.status} /></td>
                  <td className="px-5 py-3 font-mono text-xs text-tg-text-muted">
                    {s.notarization_hash ? `${s.notarization_hash.slice(0, 12)}...` : '—'}
                  </td>
                  <td className="px-5 py-3 space-x-1">
                    {role === 'admin' && s.status === 'active' && (
                      <LoadingButton
                        variant="outline"
                        size="sm"
                        className="text-tg-danger border-tg-danger hover:bg-tg-danger/10"
                        loading={terminateMutation.isPending && terminateMutation.variables === s.session_id}
                        onClick={() => handleTerminate(s.session_id)}
                      >
                        <Square className="mr-1 h-3 w-3" /> Terminate
                      </LoadingButton>
                    )}
                    {role === 'admin' && s.status === 'failed' && (
                      <LoadingButton
                        variant="outline"
                        size="sm"
                        className="text-tg-info border-tg-info hover:bg-tg-info/10"
                        loading={retryMutation.isPending && retryMutation.variables === s.session_id}
                        onClick={() => retryMutation.mutate(s.session_id)}
                      >
                        <RotateCcw className="mr-1 h-3 w-3" /> Notarize
                      </LoadingButton>
                    )}
                    <Button variant="ghost" size="sm" onClick={() => setSelectedId(s.session_id)}>View</Button>
                    <Button variant="ghost" size="sm" onClick={() => downloadSession(s.session_id)}>
                      <Download className="mr-1 h-3 w-3" /> Download
                    </Button>
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
      <DialogContent className="bg-card border-border max-w-[56rem] max-h-[80vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-3">
            <span className="font-mono text-sm truncate">{sessionId}</span>
            {session && <StatusBadge status={session.status} />}
          </DialogTitle>
        </DialogHeader>

        {isLoading ? (
          <div className="h-32 animate-pulse rounded bg-tg-surface" />
        ) : error || !session ? (
          <p className="text-sm text-tg-danger">Failed to load session details.</p>
        ) : (
          <div className="space-y-4 min-w-0">
            {/* Started / Ended */}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <span className="text-sm font-medium text-tg-text-muted">Started</span>
                <p className="mt-1 text-sm">{format(new Date(session.started_at), 'PPpp')}</p>
              </div>
              <div>
                <span className="text-sm font-medium text-tg-text-muted">Ended</span>
                <p className="mt-1 text-sm">{session.ended_at ? format(new Date(session.ended_at), 'PPpp') : '—'}</p>
              </div>
            </div>

            {/* DID */}
            <CopyableField value={session.did} label="DID" />

            {/* Notarization Hash */}
            {session.notarization_hash && (
              <CopyableField value={session.notarization_hash} label="Notarization Hash" />
            )}

            {/* On-Chain ID */}
            {session.on_chain_id && (
              <CopyableField value={session.on_chain_id} label="On-Chain ID" />
            )}

            {/* Error */}
            {session.error && (
              <div>
                <span className="text-sm font-medium text-tg-text-muted">Error</span>
                <p className="mt-1 text-sm text-tg-danger">{session.error}</p>
              </div>
            )}

            {/* Command History */}
            {session.commands && session.commands.length > 0 && (
              <div className="min-w-0">
                <span className="text-sm font-medium text-tg-text-muted">Command History ({session.commands.length})</span>
                <div className="mt-1 max-h-72 overflow-y-auto overflow-x-auto rounded bg-tg-surface p-3">
                  <pre className="font-mono text-xs text-tg-text-secondary whitespace-pre w-max">{session.commands.map((c) => (
                    `${c.timestamp ? `[${c.timestamp}] ` : ''}${c.command}\n`
                  )).join('')}</pre>
                </div>
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
