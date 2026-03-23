import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Switch } from '@/components/ui/switch';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader, EmptyState } from '@/components/shared/UIElements';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { DIDDisplay, SensitiveDisplay } from '@/components/shared/DataDisplay';
import { JsonViewer } from '@/components/shared/JsonViewer';
import { ConfirmDialog } from '@/components/shared/ConfirmDialog';
import { identityApi, userApi } from '@/lib/api';
import type { UserInfo, AssignDidResponse, AuthorizeResponse } from '@/types';

export default function IdentityPage() {
  const [lastCreatedDid, setLastCreatedDid] = useState('');

  return (
    <div className="space-y-6">
      <PageHeader title="Identity Management" subtitle="Create, resolve, and manage DIDs and users" />
      <div className="grid gap-6 lg:grid-cols-2">
        <CreateDIDForm onCreated={setLastCreatedDid} />
        <ResolveDIDForm initialDid={lastCreatedDid} />
      </div>
      <DeactivateDIDForm initialDid={lastCreatedDid} />
      <UserManagementSection />
    </div>
  );
}

function CreateDIDForm({ onCreated }: { onCreated: (did: string) => void }) {
  const [publish, setPublish] = useState(true);
  const [network, setNetwork] = useState<string>('iota');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<any>(null);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const req: any = { publish };
      if (!publish) req.network = network;
      const res = await identityApi.create(req);
      if (res.ok) {
        setResult(res.data);
        onCreated(res.data.did);
        toast.success('DID created successfully');
      } else {
        setError((res.data as any).message || 'Failed to create DID');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <h3 className="text-sm font-semibold mb-4 text-foreground">Create DID</h3>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="flex items-center gap-3">
          <Switch checked={publish} onCheckedChange={setPublish} />
          <Label>{publish ? 'Publish on-chain' : 'Generate locally'}</Label>
        </div>
        {!publish && (
          <div className="space-y-2">
            <Label>Network</Label>
            <Select value={network} onValueChange={setNetwork}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                {['iota', 'smr', 'rms', 'atoi'].map(n => (
                  <SelectItem key={n} value={n}>{n.toUpperCase()}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        {error && <InlineNotice type="error" message={error} />}
        <LoadingButton type="submit" loading={loading}>
          {publish ? 'Publish DID' : 'Generate Local DID'}
        </LoadingButton>
      </form>
      {result && <div className="mt-4"><JsonViewer data={result} collapsed={false} /></div>}
    </div>
  );
}

function ResolveDIDForm({ initialDid }: { initialDid: string }) {
  const [did, setDid] = useState(initialDid);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<any>(null);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!/^did:iota(:[a-z]+)?:0x[a-fA-F0-9]+$/.test(did)) {
      setError('Invalid DID format. Expected: did:iota:0x...');
      return;
    }
    setError('');
    setLoading(true);
    try {
      const res = await identityApi.resolve(did);
      if (res.ok) setResult(res.data);
      else setError(res.status === 404 ? 'DID not found on-chain' : (res.data as any).message || 'Failed');
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <h3 className="text-sm font-semibold mb-4 text-foreground">Resolve DID</h3>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-2">
          <Label>DID</Label>
          <Input value={did} onChange={(e) => { setDid(e.target.value); setError(''); }} placeholder="did:iota:0x..." />
        </div>
        {error && <InlineNotice type="error" message={error} />}
        <LoadingButton type="submit" loading={loading} variant="outline">Resolve</LoadingButton>
      </form>
      {result && <div className="mt-4"><JsonViewer data={result} collapsed={false} /></div>}
    </div>
  );
}

function DeactivateDIDForm({ initialDid }: { initialDid: string }) {
  const [did, setDid] = useState(initialDid);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<any>(null);
  const [error, setError] = useState('');

  const handleDeactivate = async () => {
    setError('');
    setLoading(true);
    try {
      const res = await identityApi.revoke(did);
      if (res.ok) {
        setResult(res.data);
        toast.success('DID deactivated');
      } else {
        setError((res.data as any).message || 'Failed to deactivate');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <h3 className="text-sm font-semibold mb-4 text-foreground">Deactivate DID</h3>
      <div className="space-y-4">
        <div className="space-y-2">
          <Label>DID</Label>
          <Input value={did} onChange={(e) => setDid(e.target.value)} placeholder="did:iota:0x..." />
        </div>
        <p className="text-xs text-tg-danger font-medium">This action is irreversible.</p>
        {error && <InlineNotice type="error" message={error} />}
        <ConfirmDialog
          trigger={<LoadingButton loading={loading} variant="destructive">Deactivate</LoadingButton>}
          message="This will permanently deactivate the DID on-chain. This action cannot be undone."
          onConfirm={handleDeactivate}
        />
      </div>
      {result && <div className="mt-4"><JsonViewer data={result} collapsed={false} /></div>}
    </div>
  );
}

function UserManagementSection() {
  const queryClient = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['users'],
    queryFn: () => userApi.list(),
  });
  const [actionResult, setActionResult] = useState<{ type: string; data: AssignDidResponse | AuthorizeResponse } | null>(null);

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [role, setRole] = useState<string>('user');
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState('');

  const handleCreateUser = async (e: React.FormEvent) => {
    e.preventDefault();
    setCreateError('');
    setCreating(true);
    try {
      const res = await userApi.create({ email, password, role: role as 'user' | 'verifier' });
      if (res.ok) {
        toast.success(`User ${email} created`);
        setEmail('');
        setPassword('');
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        setCreateError(res.status === 409 ? 'User already exists' : (res.data as any).message || 'Failed');
      }
    } catch {
      setCreateError('Connection failed');
    } finally {
      setCreating(false);
    }
  };

  const handleAssignDid = async (userEmail: string) => {
    try {
      const res = await userApi.assignDid(userEmail);
      if (res.ok) {
        toast.success(`DID assigned to ${userEmail}`);
        setActionResult({ type: 'assign', data: res.data });
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        toast.error((res.data as any).message || 'Failed to assign DID');
      }
    } catch {
      toast.error('Connection failed');
    }
  };

  const handleAuthorize = async (userEmail: string) => {
    try {
      const res = await userApi.authorize(userEmail);
      if (res.ok) {
        toast.success('User authorized successfully');
        setActionResult({ type: 'authorize', data: res.data });
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        if (res.status === 422) toast.error('Assign a DID first');
        else if (res.status === 409) toast.error('User is already authorized');
        else if (res.status === 503) toast.error('Server DID not provisioned');
        else toast.error((res.data as any).message || 'Failed');
      }
    } catch {
      toast.error('Connection failed');
    }
  };

  const handleUnauthorize = async (userEmail: string) => {
    try {
      const res = await userApi.unauthorize(userEmail);
      if (res.ok) {
        toast.success('User unauthorized. Credentials revoked.');
        setActionResult(null);
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        toast.error((res.data as any).message || 'Failed');
      }
    } catch {
      toast.error('Connection failed');
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card shadow-tg-sm">
      <div className="border-b border-border px-5 py-3">
        <h3 className="text-sm font-semibold text-foreground">User Management</h3>
      </div>
      <div className="p-5 space-y-6">
        <form onSubmit={handleCreateUser} className="grid gap-4 md:grid-cols-4 items-end">
          <div className="space-y-2">
            <Label>Email</Label>
            <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="user@example.com" />
          </div>
          <div className="space-y-2">
            <Label>Password</Label>
            <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={6} />
          </div>
          <div className="space-y-2">
            <Label>Role</Label>
            <Select value={role} onValueChange={setRole}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="user">User</SelectItem>
                <SelectItem value="verifier">Verifier</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <LoadingButton type="submit" loading={creating}>Create User</LoadingButton>
        </form>
        {createError && <InlineNotice type="error" message={createError} />}

        {isLoading ? (
          <div className="h-32 animate-pulse rounded bg-tg-surface" />
        ) : !data?.ok || data.data.users.length === 0 ? (
          <EmptyState message="No users found." />
        ) : (
          <div className="overflow-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border text-left text-xs text-tg-text-muted">
                  <th className="pb-2 pr-4">Email</th>
                  <th className="pb-2 pr-4">Role</th>
                  <th className="pb-2 pr-4">DID</th>
                  <th className="pb-2 pr-4">Authorized</th>
                  <th className="pb-2 pr-4">Source</th>
                  <th className="pb-2">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {data.data.users.map((u: UserInfo) => (
                  <tr key={u.email} className="hover:bg-tg-surface transition-colors">
                    <td className="py-3 pr-4 text-foreground">{u.email}</td>
                    <td className="py-3 pr-4"><StatusBadge status={u.role} /></td>
                    <td className="py-3 pr-4">{u.did ? <DIDDisplay did={u.did} /> : <span className="text-tg-text-muted">None</span>}</td>
                    <td className="py-3 pr-4">
                      {u.did ? (
                        u.authorized
                          ? <span className="text-xs text-tg-success font-medium">Authorized</span>
                          : <span className="text-xs text-tg-danger font-medium">Unauthorized</span>
                      ) : <span className="text-tg-text-muted">—</span>}
                    </td>
                    <td className="py-3 pr-4"><span className="text-xs text-tg-text-muted">{u.source}</span></td>
                    <td className="py-3">
                      {u.source === 'dynamic' && (
                        <>
                          {!u.did && (
                            <LoadingButton size="sm" variant="outline" onClick={() => handleAssignDid(u.email)}>
                              Assign DID
                            </LoadingButton>
                          )}
                          {u.did && !u.authorized && (
                            <LoadingButton size="sm" variant="outline" onClick={() => handleAuthorize(u.email)}>
                              Authorize
                            </LoadingButton>
                          )}
                          {u.did && u.authorized && (
                            <ConfirmDialog
                              trigger={<LoadingButton size="sm" variant="outline">Unauthorize</LoadingButton>}
                              message={`Revoke credentials for ${u.email}?`}
                              onConfirm={() => handleUnauthorize(u.email)}
                            />
                          )}
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {actionResult?.type === 'assign' && (
          <div className="space-y-3">
            <h4 className="text-sm font-medium text-foreground">Assigned DID Details</h4>
            <SensitiveDisplay
              value={JSON.stringify((actionResult.data as AssignDidResponse).private_key_jwk, null, 2)}
              warning="Save this key securely. It will not be shown again."
            />
            <SensitiveDisplay
              value={(actionResult.data as AssignDidResponse).verification_method_fragment}
              warning="Verification method fragment — provide to user"
            />
          </div>
        )}
        {actionResult?.type === 'authorize' && (
          <div className="space-y-3">
            <h4 className="text-sm font-medium text-foreground">Authorization Result</h4>
            <SensitiveDisplay
              value={(actionResult.data as AuthorizeResponse).credential_jwt}
              warning="Provide this to the user. They need it to access the portal."
            />
          </div>
        )}
      </div>
    </div>
  );
}
