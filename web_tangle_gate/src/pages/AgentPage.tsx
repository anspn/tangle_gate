import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice } from '@/components/shared/UIElements';
import { agentApi } from '@/lib/api';
import { Wifi, WifiOff, Settings, RefreshCw, Radio, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';

export default function AgentPage() {
  return (
    <div className="space-y-6">
      <div>
        <div className="flex items-center gap-3">
          <h1 className="text-3xl font-semibold tracking-tight text-foreground">Agent Management</h1>
          <span className="rounded-full bg-amber-500/15 px-2.5 py-0.5 text-xs font-semibold text-amber-600 ring-1 ring-amber-500/30">beta</span>
        </div>
        <p className="mt-1.5 text-base text-tg-text-secondary">Monitor and configure the verification agent</p>
      </div>
      <AgentStatusCard />
      <AgentConfigCard />
    </div>
  );
}

// =============================================================================
// Agent Status Card — live connection status
// =============================================================================

type ConnectionState = 'connecting' | 'connected' | 'disconnected';

function deriveState(isLoading: boolean, isFetching: boolean, value: boolean | undefined): ConnectionState {
  // First load or refetching after an error — show connecting
  if (isLoading) return 'connecting';
  // We have data — use it
  if (value !== undefined) return value ? 'connected' : 'disconnected';
  // Fetching but no data yet (shouldn't normally happen)
  if (isFetching) return 'connecting';
  return 'disconnected';
}

function AgentStatusCard() {
  const queryClient = useQueryClient();
  const { data, isLoading, isFetching } = useQuery({
    queryKey: ['agentStatus'],
    queryFn: () => agentApi.status(),
    refetchInterval: 10_000,
    retry: false,
  });

  const status = data?.ok ? data.data : null;
  const httpState = deriveState(isLoading, isFetching, status?.agent_reachable);
  const wsState = deriveState(isLoading, isFetching, status?.ws_connected);

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      <div className="flex items-center justify-between border-b border-border px-5 py-3">
        <div className="flex items-center gap-2">
          <Radio className="h-4 w-4 text-tg-text-muted" />
          <h3 className="text-sm font-semibold text-foreground">Connection Status</h3>
        </div>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => queryClient.invalidateQueries({ queryKey: ['agentStatus'] })}
        >
          <RefreshCw className="mr-1.5 h-3.5 w-3.5" /> Refresh
        </Button>
      </div>
      <div className="p-5">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <StatusIndicator
            label="HTTP API"
            state={httpState}
          />
          <StatusIndicator
            label="WebSocket"
            state={wsState}
          />
        </div>
      </div>
    </div>
  );
}

function StatusIndicator({ label, state }: {
  label: string;
  state: ConnectionState;
}) {
  const icon = {
    connecting: <Loader2 className="h-4 w-4 text-amber-500 animate-spin" />,
    connected: <Wifi className="h-4 w-4 text-tg-success" />,
    disconnected: <WifiOff className="h-4 w-4 text-tg-danger" />,
  }[state];

  const dotColor = {
    connecting: 'bg-amber-500',
    connected: 'bg-tg-success',
    disconnected: 'bg-tg-danger',
  }[state];

  const textColor = {
    connecting: 'text-amber-500',
    connected: 'text-tg-success',
    disconnected: 'text-tg-danger',
  }[state];

  const stateLabel = {
    connecting: 'Connecting',
    connected: 'Connected',
    disconnected: 'Disconnected',
  }[state];

  return (
    <div className="rounded-lg border border-border bg-tg-surface/50 p-4">
      <div className="flex items-center gap-2 mb-1">
        {icon}
        <span className="text-sm font-medium text-foreground">{label}</span>
      </div>
      <div className="flex items-center gap-2">
        <span className={`inline-block h-2.5 w-2.5 rounded-full ${dotColor}`} />
        <span className={`text-sm font-medium ${textColor}`}>{stateLabel}</span>
      </div>
    </div>
  );
}

// =============================================================================
// Agent Config Card — view and update config
// =============================================================================

function AgentConfigCard() {
  const queryClient = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['agentConfig'],
    queryFn: () => agentApi.getConfig(),
  });

  const [url, setUrl] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [initialized, setInitialized] = useState(false);

  // Populate fields once data loads
  if (data?.ok && !initialized) {
    setUrl(data.data.url);
    setInitialized(true);
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setSaving(true);
    try {
      const body: Record<string, string | number> = {};
      if (url.trim()) body.url = url.trim();

      if (Object.keys(body).length === 0) {
        setError('No changes to save');
        setSaving(false);
        return;
      }

      const res = await agentApi.updateConfig(body);
      if (res.ok) {
        toast.success('Agent configuration updated');
        // Update local state from the response immediately
        setUrl(res.data.url);
        // Update the query cache so the WS URL reflects the new config
        queryClient.setQueryData(['agentConfig'], res);
        queryClient.invalidateQueries({ queryKey: ['agentStatus'] });
        queryClient.invalidateQueries({ queryKey: ['health'] });
      } else {
        setError((res.data as any).message || 'Failed to update configuration');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setSaving(false);
    }
  };

  const wsUrl = data?.ok ? data.data.ws_url?.replace(/\/ws\/events\/?$/, '') : '';

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      <div className="flex items-center gap-2 border-b border-border px-5 py-3">
        <Settings className="h-4 w-4 text-tg-text-muted" />
        <h3 className="text-sm font-semibold text-foreground">Agent Client Configuration</h3>
      </div>
      <div className="p-5">
        {isLoading ? (
          <div className="h-32 animate-pulse rounded bg-tg-surface" />
        ) : (
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label>Agent URL</Label>
                <Input
                  value={url}
                  onChange={(e) => setUrl(e.target.value)}
                  placeholder="http://localhost:8800"
                />
                <p className="text-xs text-tg-text-muted">Base HTTP URL of the agent service</p>
              </div>
              <div className="space-y-2">
                <Label>WebSocket URL</Label>
                <Input
                  value={wsUrl}
                  disabled
                  className="bg-muted text-muted-foreground"
                />
                <p className="text-xs text-tg-text-muted">Queried from Agent URL</p>
              </div>
            </div>
            {error && <InlineNotice type="error" message={error} />}
            <LoadingButton type="submit" loading={saving}>Save Configuration</LoadingButton>
          </form>
        )}
      </div>
    </div>
  );
}
