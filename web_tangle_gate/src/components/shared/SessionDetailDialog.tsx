import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Download } from 'lucide-react';
import { format } from 'date-fns';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { CopyableField } from '@/components/shared/DataDisplay';
import { sessionApi, downloadSession } from '@/lib/api';
import type { Session } from '@/types';

export function SessionDetailDialog({ sessionId, onClose }: { sessionId: string; onClose: () => void }) {
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
