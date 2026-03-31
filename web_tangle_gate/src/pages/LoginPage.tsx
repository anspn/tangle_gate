import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice } from '@/components/shared/UIElements';
import { authApi } from '@/lib/api';
import { useAuthStore } from '@/stores/auth';

const roleLanding = { admin: '/', user: '/portal', verifier: '/verify' };

export default function LoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <div className="w-full max-w-md space-y-8">
        <div className="flex flex-col items-center gap-3">
          <img src="/logo.svg" alt="TangleGate" className="h-28 w-28" />
          <h1 className="text-3xl font-bold text-foreground">TangleGate</h1>
          <p className="text-base text-tg-text-muted">Decentralized Identity & Session Notarization</p>
        </div>

        <div className="rounded-lg border border-border bg-card p-8 shadow-tg-md">
          <PasswordLoginForm />
        </div>

        <div className="space-y-1.5 text-center text-sm text-tg-text-muted">
          <p>Test accounts:</p>
          <p className="font-mono text-xs">admin@iota.local / iota_admin_2026</p>
          <p className="font-mono text-xs">verifier@iota.local / iota_verifier_2026</p>
        </div>
      </div>
    </div>
  );
}

function PasswordLoginForm() {
  const navigate = useNavigate();
  const login = useAuthStore((s) => s.login);
  const [identifier, setIdentifier] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const res = await authApi.login({ email: identifier.trim(), password });
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
        <Label>Email or DID</Label>
        <Input type="text" value={identifier} onChange={(e) => setIdentifier(e.target.value)} required placeholder="admin@iota.local or did:iota:0x..." />
      </div>
      <div className="space-y-2">
        <Label>Password</Label>
        <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={6} />
      </div>
      <LoadingButton type="submit" loading={loading} className="w-full">Sign In</LoadingButton>
    </form>
  );
}
