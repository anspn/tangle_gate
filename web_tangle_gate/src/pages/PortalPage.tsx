import { useState, useEffect, useCallback, useRef } from 'react';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader } from '@/components/shared/UIElements';
import { DIDDisplay } from '@/components/shared/DataDisplay';
import { sessionApi } from '@/lib/api';
import type { CreateVPForSessionResponse } from '@/types';

type Phase = 'idle' | 'active_session';

export default function PortalPage() {
  const [phase, setPhase] = useState<Phase>('idle');
  const [sessionId, setSessionId] = useState('');
  const [holderDid, setHolderDid] = useState('');

  const sessionIdRef = useRef('');

  // Keep ref in sync for use in beforeunload
  useEffect(() => { sessionIdRef.current = sessionId; }, [sessionId]);

  // On mount: if a stored session exists, end it and reset to idle
  useEffect(() => {
    const storedSession = sessionStorage.getItem('iota_portal_session');
    if (storedSession) {
      // End the orphaned session (page was reloaded)
      sessionApi.end(storedSession).catch(() => {});
      sessionStorage.removeItem('iota_portal_did');
      sessionStorage.removeItem('iota_portal_session');
    }
  }, []);

  // End session on page unload (reload, tab close, navigation)
  useEffect(() => {
    const handleBeforeUnload = () => {
      const sid = sessionIdRef.current;
      if (!sid) return;
      const token = sessionStorage.getItem('iota_token');
      const blob = new Blob([JSON.stringify({})], { type: 'application/json' });
      // sendBeacon doesn't support custom headers, so use fetch with keepalive
      fetch(`/api/sessions/${sid}/end`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token ?? ''}`,
          'Content-Type': 'application/json',
        },
        body: '{}',
        keepalive: true,
      }).catch(() => {});
      sessionStorage.removeItem('iota_portal_did');
      sessionStorage.removeItem('iota_portal_session');
    };
    window.addEventListener('beforeunload', handleBeforeUnload);
    return () => window.removeEventListener('beforeunload', handleBeforeUnload);
  }, []);

  const handleSessionStarted = useCallback((sid: string, did: string) => {
    setSessionId(sid);
    setHolderDid(did);
    sessionStorage.setItem('iota_portal_did', did);
    sessionStorage.setItem('iota_portal_session', sid);
    setPhase('active_session');
  }, []);

  const handleDisconnect = async () => {
    const iframe = document.getElementById('terminal-iframe') as HTMLIFrameElement;
    if (iframe) iframe.src = 'about:blank';
    await new Promise(r => setTimeout(r, 1000));
    try { await sessionApi.end(sessionId); } catch { console.warn('Failed to end session'); }
    sessionStorage.removeItem('iota_portal_did');
    sessionStorage.removeItem('iota_portal_session');
    setPhase('idle');
    setSessionId('');
    setHolderDid('');
  };

  return (
    <div className="space-y-8">
      <PageHeader title="Terminal Portal" subtitle="Present your Verifiable Credential to start a secure terminal session" />
      {phase === 'idle' && <VPCreationCard onSessionStarted={handleSessionStarted} />}
      {phase === 'active_session' && <TerminalCard did={holderDid} onDisconnect={handleDisconnect} />}
    </div>
  );
}

function VPCreationCard({ onSessionStarted }: { onSessionStarted: (sessionId: string, did: string) => void }) {
  const [credentialJwt, setCredentialJwt] = useState('');
  const [privateKey, setPrivateKey] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    if (!credentialJwt.startsWith('eyJ')) { setError('Invalid credential JWT format'); return; }
    try { JSON.parse(privateKey); } catch { setError('Private Key JWK must be valid JSON'); return; }

    setLoading(true);
    try {
      // Step 1: Create VP
      const vpRes = await sessionApi.createVP({ credential_jwt: credentialJwt, private_key_jwk: privateKey });
      if (!vpRes.ok) {
        if (vpRes.status === 422) setError('No DID assigned to your account. Contact admin.');
        else if (vpRes.status === 403) setError('Not authorized for terminal access. Contact admin.');
        else setError((vpRes.data as any).message || 'Failed to create VP');
        return;
      }

      // Step 2: Start session with VP
      const { presentation_jwt, challenge, holder_did } = vpRes.data;
      const sessionRes = await sessionApi.start({ presentation_jwt, challenge, holder_did });
      if (sessionRes.ok) {
        onSessionStarted(sessionRes.data.session_id, holder_did);
      } else {
        setError((sessionRes.data as any).message || 'Failed to start session');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-6 shadow-tg-sm">
      <h3 className="text-base font-semibold mb-5 text-foreground">Start Terminal Session</h3>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div className="space-y-2">
            <Label>Credential JWT</Label>
            <Textarea value={credentialJwt} onChange={(e) => setCredentialJwt(e.target.value)} rows={6} required placeholder="eyJ..." />
            <p className="text-sm text-tg-text-muted">The credential JWT provided by an admin</p>
          </div>
          <div className="space-y-2">
            <Label>Private Key JWK</Label>
            <Textarea value={privateKey} onChange={(e) => setPrivateKey(e.target.value)} rows={6} required placeholder='{"kty": "OKP", ...}' />
            <p className="text-sm text-tg-text-muted">Your Ed25519 private key JWK</p>
          </div>
        </div>
        {error && <InlineNotice type="error" message={error} />}
        <LoadingButton type="submit" loading={loading}>Start Session</LoadingButton>
      </form>
    </div>
  );
}

function TerminalCard({ did, onDisconnect }: { did: string; onDisconnect: () => void }) {
  const [disconnecting, setDisconnecting] = useState(false);

  const handleDisconnect = async () => {
    setDisconnecting(true);
    await onDisconnect();
    setDisconnecting(false);
  };

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm overflow-hidden">
      <div className="flex items-center justify-between border-b border-border px-5 py-3">
        <div className="flex items-center gap-3">
          <h3 className="text-base font-semibold text-foreground">Terminal</h3>
          <DIDDisplay did={did} />
        </div>
        <LoadingButton variant="destructive" size="sm" loading={disconnecting} onClick={handleDisconnect}>
          Disconnect
        </LoadingButton>
      </div>
      <iframe
        id="terminal-iframe"
        src="http://localhost:7681"
        sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
        allow="clipboard-read; clipboard-write"
        className="w-full border-0"
        style={{ height: 500 }}
        title="Terminal"
      />
    </div>
  );
}
