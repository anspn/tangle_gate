import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader } from '@/components/shared/UIElements';
import { agentApi } from '@/lib/api';
import { Wifi, WifiOff, Settings, RefreshCw, Radio } from 'lucide-react';
import { Button } from '@/components/ui/button';

export default function AgentPage() {
  return (
    <div className="space-y-6">
      <PageHeader title="Agent Management" subtitle="Monitor and configure the verification agent" />
      <AgentStatusCard />
      <AgentConfigCard />
    </div>
  );
}

// =============================================================================
// Agent Status Card — live connection status
// =============================================================================

function AgentStatusCard() {
  const queryClient = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['agentStatus'],
    queryFn: () => agentApi.status(),
    refetchInterval: 10_000,
  });

  const status = data?.ok ? data.data : null;

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
        {isLoading ? (
          <div className="h-24 animate-pulse rounded bg-tg-surface" />
        ) : !status ? (
          <InlineNotice type="error" message="Failed to fetch agent status" />
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <StatusIndicator
              label="HTTP API"
              description="Agent verification endpoint reachability"
              connected={status.agent_reachable}
            />
            <StatusIndicator
              label="WebSocket"
              description="Real-time session event channel"
              connected={status.ws_connected}
            />
            <div className="rounded-lg border border-border bg-tg-surface/50 p-4">
              <div className="flex items-center gap-2 mb-1">
                <Radio className="h-4 w-4 text-tg-text-muted" />
                <span className="text-sm font-medium text-foreground">Connected Agents</span>
              </div>
              <span className="text-2xl font-semibold text-foreground">{status.ws_agent_count}</span>
              <p className="text-xs text-tg-text-muted mt-1">Active WebSocket connections</p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function StatusIndicator({ label, description, connected }: { label: string; description: string; connected: boolean }) {
  return (
    <div className="rounded-lg border border-border bg-tg-surface/50 p-4">
      <div className="flex items-center gap-2 mb-1">
        {connected ? (
          <Wifi className="h-4 w-4 text-tg-success" />
        ) : (
          <WifiOff className="h-4 w-4 text-tg-danger" />
        )}
        <span className="text-sm font-medium text-foreground">{label}</span>
      </div>
      <div className="flex items-center gap-2">
        <span
          className={`inline-block h-2.5 w-2.5 rounded-full ${
            connected ? 'bg-tg-success' : 'bg-tg-danger'
          }`}
        />
        <span className={`text-sm font-medium ${connected ? 'text-tg-success' : 'text-tg-danger'}`}>
          {connected ? 'Connected' : 'Disconnected'}
        </span>
      </div>
      <p className="text-xs text-tg-text-muted mt-1">{description}</p>
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
  const [apiKey, setApiKey] = useState('');
  const [timeout, setTimeout] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [initialized, setInitialized] = useState(false);

  // Populate fields once data loads
  if (data?.ok && !initialized) {
    setUrl(data.data.url);
    setApiKey('');
    setTimeout(String(data.data.timeout));
    setInitialized(true);
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setSaving(true);
    try {
      const body: Record<string, string | number> = {};
      if (url.trim()) body.url = url.trim();
      if (apiKey.trim()) body.api_key = apiKey.trim();
      if (timeout.trim()) body.timeout = parseInt(timeout.trim(), 10);

      if (Object.keys(body).length === 0) {
        setError('No changes to save');
        setSaving(false);
        return;
      }

      const res = await agentApi.updateConfig(body);
      if (res.ok) {
        toast.success('Agent configuration updated');
        setApiKey('');
        queryClient.invalidateQueries({ queryKey: ['agentConfig'] });
        queryClient.invalidateQueries({ queryKey: ['agentStatus'] });
        queryClient.invalidateQueries({ queryKey: ['health'] });
        setInitialized(false);
      } else {
        setError((res.data as any).message || 'Failed to update configuration');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setSaving(false);
    }
  };

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
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="space-y-2">
                <Label>Agent URL</Label>
                <Input
                  value={url}
                  onChange={(e) => setUrl(e.target.value)}
                  placeholder="http://localhost:8800"
                />
                <p className="text-xs text-tg-text-muted">HTTP endpoint of the agent</p>
              </div>
              <div className="space-y-2">
                <Label>API Key</Label>
                <Input
                  type="password"
                  value={apiKey}
                  onChange={(e) => setApiKey(e.target.value)}
                  placeholder={data?.ok ? data.data.api_key : 'Enter new API key'}
                />
                <p className="text-xs text-tg-text-muted">Leave blank to keep current key</p>
              </div>
              <div className="space-y-2">
                <Label>Timeout (ms)</Label>
                <Input
                  type="number"
                  min={1000}
                  value={timeout}
                  onChange={(e) => setTimeout(e.target.value)}
                  placeholder="30000"
                />
                <p className="text-xs text-tg-text-muted">Request timeout in milliseconds</p>
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
