import { useState, useEffect } from 'react';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader } from '@/components/shared/UIElements';
import { DIDDisplay } from '@/components/shared/DataDisplay';
import { sessionApi } from '@/lib/api';
import type { CreateVPForSessionResponse } from '@/types';

/** Decode a JWT payload (middle segment) without verification. */
function decodeJwtPayload(jwt: string): Record<string, any> | null {
  try {
    const parts = jwt.split('.');
    if (parts.length !== 3) return null;
    const payload = atob(parts[1].replace(/-/g, '+').replace(/_/g, '/'));
    return JSON.parse(payload);
  } catch {
    return null;
  }
}

type Phase = 'idle' | 'active_session';

export default function PortalPage() {
  const [phase, setPhase] = useState<Phase>('idle');
  const [sessionId, setSessionId] = useState('');
  const [holderDid, setHolderDid] = useState('');

  // VP JWT shown in the top card (editable or auto-filled)
  const [vpJwt, setVpJwt] = useState('');
  // Internal metadata from createVP (not shown to user)
  const [vpMeta, setVpMeta] = useState<{ challenge: string; holder_did: string } | null>(null);

  const [startLoading, setStartLoading] = useState(false);
  const [startError, setStartError] = useState('');

  useEffect(() => {
    const storedDid = sessionStorage.getItem('iota_portal_did');
    const storedSession = sessionStorage.getItem('iota_portal_session');
    if (storedDid && storedSession) {
      setHolderDid(storedDid);
      setSessionId(storedSession);
      setPhase('active_session');
    }
  }, []);

  const handleVPCreated = (data: CreateVPForSessionResponse) => {
    setVpJwt(data.presentation_jwt);
    setVpMeta({ challenge: data.challenge, holder_did: data.holder_did });
    setStartError('');
  };

  const handleStartSession = async () => {
    setStartError('');
    const jwt = vpJwt.trim();
    if (!jwt.startsWith('eyJ')) { setStartError('Invalid VP JWT format'); return; }

    // Resolve challenge + holder_did: prefer metadata from createVP, fall back to JWT decode
    let challenge: string;
    let holder_did: string;

    if (vpMeta && vpMeta.challenge && vpMeta.holder_did) {
      challenge = vpMeta.challenge;
      holder_did = vpMeta.holder_did;
    } else {
      const payload = decodeJwtPayload(jwt);
      if (!payload) { setStartError('Could not decode VP JWT payload'); return; }
      holder_did = payload.iss || '';
      challenge = payload.nonce || payload.vp?.nonce || '';
      if (!holder_did) { setStartError('VP JWT missing issuer (holder DID)'); return; }
      if (!challenge) { setStartError('VP JWT missing nonce (challenge)'); return; }
    }

    setStartLoading(true);
    try {
      const res = await sessionApi.start({ presentation_jwt: jwt, challenge, holder_did });
      if (res.ok) {
        setSessionId(res.data.session_id);
        setHolderDid(holder_did);
        sessionStorage.setItem('iota_portal_did', holder_did);
        sessionStorage.setItem('iota_portal_session', res.data.session_id);
        setPhase('active_session');
      } else {
        setStartError((res.data as any).message || 'Failed to start session');
      }
    } catch {
      setStartError('Connection failed');
    } finally {
      setStartLoading(false);
    }
  };

  const handleDisconnect = async () => {
    const iframe = document.getElementById('terminal-iframe') as HTMLIFrameElement;
    if (iframe) iframe.src = 'about:blank';
    await new Promise(r => setTimeout(r, 1000));
    try { await sessionApi.end(sessionId); } catch { console.warn('Failed to end session'); }
    sessionStorage.removeItem('iota_portal_did');
    sessionStorage.removeItem('iota_portal_session');
    setPhase('idle');
    setVpJwt('');
    setVpMeta(null);
    setSessionId('');
    setHolderDid('');
    setStartError('');
  };

  const vpReady = vpJwt.trim().startsWith('eyJ');

  return (
    <div className="space-y-8">
      <PageHeader title="Terminal Portal" subtitle="Create a VP and start a secure terminal session" />

      {phase === 'idle' && (
        <>
          {/* Top: VP JWT + Start Session */}
          <div className="rounded-lg border border-border bg-card p-6 shadow-tg-sm">
            <h3 className="text-base font-semibold mb-5 text-foreground">Verifiable Presentation</h3>
            <div className="space-y-4">
              <div className="space-y-2">
                <Label>VP JWT</Label>
                <Textarea
                  value={vpJwt}
                  onChange={(e) => { setVpJwt(e.target.value); setVpMeta(null); setStartError(''); }}
                  rows={5}
                  placeholder="eyJ..."
                />
                <p className="text-sm text-tg-text-muted">
                  {vpMeta ? 'VP created — ready to start session' : 'Paste an existing VP JWT or create one below'}
                </p>
              </div>
              {startError && <InlineNotice type="error" message={startError} />}
              <LoadingButton onClick={handleStartSession} loading={startLoading} disabled={!vpReady}>
                Start Session
              </LoadingButton>
            </div>
          </div>

          {/* Divider */}
          <div className="relative">
            <div className="absolute inset-0 flex items-center"><span className="w-full border-t border-border" /></div>
            <div className="relative flex justify-center"><span className="bg-background px-4 text-sm text-tg-text-muted">or create one</span></div>
          </div>

          {/* Bottom: Create VP form */}
          <VPCreationCard onCreated={handleVPCreated} />
        </>
      )}

      {phase === 'active_session' && <TerminalCard did={holderDid} onDisconnect={handleDisconnect} />}
    </div>
  );
}

function VPCreationCard({ onCreated }: { onCreated: (data: CreateVPForSessionResponse) => void }) {
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
      const res = await sessionApi.createVP({ credential_jwt: credentialJwt, private_key_jwk: privateKey });
      if (res.ok) onCreated(res.data);
      else {
        if (res.status === 422) setError('No DID assigned to your account. Contact admin.');
        else if (res.status === 403) setError('Not authorized for terminal access. Contact admin.');
        else setError((res.data as any).message || 'Failed to create VP');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-6 shadow-tg-sm">
      <h3 className="text-base font-semibold mb-5 text-foreground">Create Verifiable Presentation</h3>
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
        <LoadingButton type="submit" loading={loading}>Create VP</LoadingButton>
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
