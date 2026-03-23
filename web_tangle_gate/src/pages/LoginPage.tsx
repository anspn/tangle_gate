import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice } from '@/components/shared/UIElements';
import { CopyableField } from '@/components/shared/DataDisplay';
import { authApi } from '@/lib/api';
import { useAuthStore } from '@/stores/auth';

const roleLanding = { admin: '/', user: '/portal', verifier: '/verify' };

export default function LoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <div className="w-full max-w-md space-y-8">
        <div className="flex flex-col items-center gap-3">
          <img src="/logo.svg" alt="TangleGate" className="h-14 w-14" />
          <h1 className="text-3xl font-bold text-foreground">TangleGate</h1>
          <p className="text-base text-tg-text-muted">Decentralized Identity & Session Notarization</p>
        </div>

        <div className="rounded-lg border border-border bg-card p-8 shadow-tg-md">
          <Tabs defaultValue="password">
            <TabsList className="w-full mb-6">
              <TabsTrigger value="password" className="flex-1 text-sm">Email & Password</TabsTrigger>
              <TabsTrigger value="vp" className="flex-1 text-sm">Verifiable Presentation</TabsTrigger>
            </TabsList>
            <TabsContent value="password"><PasswordLoginForm /></TabsContent>
            <TabsContent value="vp"><VPLoginForm /></TabsContent>
          </Tabs>
        </div>

        <div className="space-y-1.5 text-center text-sm text-tg-text-muted">
          <p>Test accounts:</p>
          <p className="font-mono text-xs">admin@iota.local / iota_admin_2026</p>
          <p className="font-mono text-xs">user@iota.local / iota_user_2026</p>
          <p className="font-mono text-xs">verifier@iota.local / iota_verifier_2026</p>
        </div>
      </div>
    </div>
  );
}

function PasswordLoginForm() {
  const navigate = useNavigate();
  const login = useAuthStore((s) => s.login);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [did, setDid] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const req: any = { email, password };
      if (did.trim()) req.did = did.trim();
      const res = await authApi.login(req);
      if (!res.ok) {
        setError((res.data as any).message || 'Email or password is incorrect');
        return;
      }
      login(res.data.token, res.data.user);
      navigate(roleLanding[res.data.user.role as keyof typeof roleLanding] || '/');
    } catch {
      setError('Cannot reach server');
    } finally {
      setLoading(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {error && <InlineNotice type="error" message={error} />}
      <div className="space-y-2">
        <Label>Email</Label>
        <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="admin@iota.local" />
      </div>
      <div className="space-y-2">
        <Label>Password</Label>
        <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={6} />
      </div>
      <div className="space-y-2">
        <Label className="text-tg-text-muted">DID (optional)</Label>
        <Input value={did} onChange={(e) => setDid(e.target.value)} placeholder="did:iota:0x..." />
        <p className="text-xs text-tg-text-muted">Enter your assigned DID to verify ownership</p>
      </div>
      <LoadingButton type="submit" loading={loading} className="w-full">Sign In</LoadingButton>
    </form>
  );
}

function VPLoginForm() {
  const navigate = useNavigate();
  const login = useAuthStore((s) => s.login);
  const [challenge, setChallenge] = useState('');
  const [fetchingChallenge, setFetchingChallenge] = useState(false);
  const [holderDoc, setHolderDoc] = useState('');
  const [credentialJwt, setCredentialJwt] = useState('');
  const [privateKey, setPrivateKey] = useState('');
  const [fragment, setFragment] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const fetchChallenge = async () => {
    setFetchingChallenge(true);
    setError('');
    try {
      const res = await authApi.getChallenge();
      if (res.ok) setChallenge(res.data.challenge);
      else setError('Failed to fetch challenge');
    } catch {
      setError('Cannot reach server');
    } finally {
      setFetchingChallenge(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    try { JSON.parse(holderDoc); } catch { setError('Holder DID Document must be valid JSON'); return; }
    try { JSON.parse(privateKey); } catch { setError('Private Key JWK must be valid JSON'); return; }
    if (!credentialJwt.startsWith('eyJ')) { setError('Invalid credential JWT format'); return; }

    setLoading(true);
    try {
      const res = await authApi.vpLogin({
        holder_doc_json: holderDoc,
        credential_jwt: credentialJwt,
        challenge,
        private_key_jwk: privateKey,
        fragment,
      });
      if (!res.ok) {
        setError((res.data as any).message || 'VP authentication failed');
        setChallenge('');
        return;
      }
      login(res.data.token, res.data.user);
      navigate(roleLanding[res.data.user.role as keyof typeof roleLanding] || '/');
    } catch {
      setError('Cannot reach server');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="space-y-4">
      {error && <InlineNotice type="error" message={error} />}

      <div className="space-y-2">
        <LoadingButton onClick={fetchChallenge} loading={fetchingChallenge} variant="outline" className="w-full">
          Get Challenge
        </LoadingButton>
        {challenge && <CopyableField value={challenge} label="Challenge (single-use)" />}
      </div>

      {challenge && (
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label>Holder DID Document (JSON)</Label>
            <Textarea value={holderDoc} onChange={(e) => setHolderDoc(e.target.value)} rows={4} required />
          </div>
          <div className="space-y-2">
            <Label>Credential JWT</Label>
            <Textarea value={credentialJwt} onChange={(e) => setCredentialJwt(e.target.value)} rows={3} required />
          </div>
          <div className="space-y-2">
            <Label>Private Key JWK (JSON)</Label>
            <Textarea value={privateKey} onChange={(e) => setPrivateKey(e.target.value)} rows={3} required />
          </div>
          <div className="space-y-2">
            <Label>Verification Method Fragment</Label>
            <Input value={fragment} onChange={(e) => setFragment(e.target.value)} required />
          </div>
          <LoadingButton type="submit" loading={loading} className="w-full">Sign in with VP</LoadingButton>
        </form>
      )}
    </div>
  );
}
