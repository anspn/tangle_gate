import { useState, useEffect, useCallback, useRef } from 'react';
import { Upload } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader } from '@/components/shared/UIElements';
import { DIDDisplay } from '@/components/shared/DataDisplay';
import { sessionApi } from '@/lib/api';
import type { CreateVPForSessionResponse } from '@/types';

type Phase = 'idle' | 'active_session' | 'terminated';

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

  const handleTerminated = useCallback(() => {
    // Remove the iframe immediately to prevent ttyd reconnection
    const iframe = document.getElementById('terminal-iframe') as HTMLIFrameElement;
    if (iframe) iframe.src = 'about:blank';
    sessionStorage.removeItem('iota_portal_did');
    sessionStorage.removeItem('iota_portal_session');
    // Clear sessionId so beforeunload doesn't try to end an already-terminated session
    setSessionId('');
    setPhase('terminated');
  }, []);

  const handleReturnToIdle = useCallback(() => {
    setPhase('idle');
    setSessionId('');
    setHolderDid('');
  }, []);

  return (
    <div className="space-y-8">
      <PageHeader title="Terminal Portal" subtitle="Present your Verifiable Credential to start a secure terminal session" />
      {phase === 'idle' && <VPCreationCard onSessionStarted={handleSessionStarted} />}
      {phase === 'active_session' && (
        <TerminalCard
          sessionId={sessionId}
          did={holderDid}
          onDisconnect={handleDisconnect}
          onTerminated={handleTerminated}
        />
      )}
      {phase === 'terminated' && <TerminatedBanner onReturn={handleReturnToIdle} />}
    </div>
  );
}

function VPCreationCard({ onSessionStarted }: { onSessionStarted: (sessionId: string, did: string) => void }) {
  const [credentialJwt, setCredentialJwt] = useState('');
  const [privateKey, setPrivateKey] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      try {
        const data = JSON.parse(ev.target?.result as string);
        let filled = false;
        if (data.credential_jwt && typeof data.credential_jwt === 'string') {
          setCredentialJwt(data.credential_jwt);
          filled = true;
        }
        if (data.private_key_jwk) {
          const jwk = typeof data.private_key_jwk === 'string' ? data.private_key_jwk : JSON.stringify(data.private_key_jwk, null, 2);
          setPrivateKey(jwk);
          filled = true;
        }
        if (filled) {
          setError('');
          toast.success('Credentials loaded from file');
        } else {
          toast.error('File does not contain credential_jwt or private_key_jwk');
        }
      } catch {
        toast.error('Invalid JSON file');
      }
    };
    reader.readAsText(file);
    // Reset so the same file can be re-selected
    e.target.value = '';
  };

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
        if (vpRes.status === 503) setError((vpRes.data as any).message || 'Verification agent is unreachable. Try again later.');
        else if (vpRes.status === 422) setError((vpRes.data as any).message || 'No DID assigned to your account. Contact admin.');
        else if (vpRes.status === 403) setError((vpRes.data as any).message || 'Not authorized for terminal access. Contact admin.');
        else setError((vpRes.data as any).message || 'Failed to create VP');
        return;
      }

      // Step 2: Start session with VP
      const { presentation_jwt, challenge, holder_did } = vpRes.data;
      const sessionRes = await sessionApi.start({ presentation_jwt, challenge, holder_did });
      if (sessionRes.ok) {
        onSessionStarted(sessionRes.data.session_id, holder_did);
      } else {
        if (sessionRes.status === 503) setError((sessionRes.data as any).message || 'Verification agent is unreachable. Try again later.');
        else setError((sessionRes.data as any).message || 'Failed to start session');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-6 shadow-tg-sm">
      <div className="flex items-center justify-between mb-5">
        <h3 className="text-base font-semibold text-foreground">Start Terminal Session</h3>
        <div>
          <input ref={fileInputRef} type="file" accept=".json,application/json" className="hidden" onChange={handleFileUpload} />
          <Button variant="outline" size="sm" onClick={() => fileInputRef.current?.click()}>
            <Upload className="mr-1 h-3 w-3" /> Import Credentials File
          </Button>
        </div>
      </div>
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

function TerminalCard({
  sessionId,
  did,
  onDisconnect,
  onTerminated,
}: {
  sessionId: string;
  did: string;
  onDisconnect: () => void;
  onTerminated: () => void;
}) {
  const [disconnecting, setDisconnecting] = useState(false);

  // Poll session status every 3s to detect admin termination
  useEffect(() => {
    const interval = setInterval(async () => {
      try {
        const res = await sessionApi.get(sessionId);
        if (res.ok && res.data.status !== 'active') {
          clearInterval(interval);
          onTerminated();
        }
      } catch {
        // Network error — don't terminate on transient failures
      }
    }, 3000);
    return () => clearInterval(interval);
  }, [sessionId, onTerminated]);

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

function TerminatedBanner({ onReturn }: { onReturn: () => void }) {
  return (
    <div className="rounded-lg border border-destructive/50 bg-destructive/10 p-6 shadow-tg-sm">
      <div className="flex items-start gap-4">
        <div className="flex-shrink-0 mt-0.5">
          <svg xmlns="http://www.w3.org/2000/svg" className="h-6 w-6 text-destructive" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4.5c-.77-.833-2.694-.833-3.464 0L3.34 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
        </div>
        <div className="flex-1">
          <h3 className="text-lg font-semibold text-destructive">Session Terminated</h3>
          <p className="mt-1 text-sm text-foreground/80">
            Your terminal session has been terminated by an administrator. All commands have been recorded and will be notarized on the IOTA Tangle.
          </p>
        </div>
      </div>
      <div className="mt-5">
        <LoadingButton variant="outline" onClick={onReturn} loading={false}>
          Return to Portal
        </LoadingButton>
      </div>
    </div>
  );
}
