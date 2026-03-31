import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader, EmptyState } from '@/components/shared/UIElements';
import { StatusBadge } from '@/components/shared/StatusBadge';
import { DIDDisplay, SensitiveDisplay } from '@/components/shared/DataDisplay';
import { JsonViewer } from '@/components/shared/JsonViewer';
import { ConfirmDialog } from '@/components/shared/ConfirmDialog';
import { identityApi, userApi } from '@/lib/api';
import type { UserInfo, AssignDidResponse, AuthorizeResponse } from '@/types';

export default function IdentityPage() {
  return (
    <div className="space-y-6">
      <PageHeader title="Identity Management" subtitle="Manage users and resolve DIDs" />
      <UserManagementSection />
      <ResolveDIDForm />
    </div>
  );
}

function ResolveDIDForm() {
  const [did, setDid] = useState('');
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
      if (res.ok) {
        const data = { ...res.data };
        if (typeof data.document === 'string') {
          try { data.document = JSON.parse(data.document); } catch { /* keep as string */ }
        }
        setResult(data);
      } else {
        setError(res.status === 404 ? 'DID not found on-chain' : (res.data as any).message || 'Failed');
      }
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

function getUserStatus(u: UserInfo): string {
  if (u.status === 'deleted') return 'Deleted';
  if (u.status === 'did_revoked') return 'DID Revoked';
  if (!u.did) return '—';
  return u.authorized ? 'Authorized' : 'Unauthorized';
}

function getStatusColor(status: string): string {
  switch (status) {
    case 'Authorized': return 'text-tg-success';
    case 'Unauthorized': return 'text-tg-warning';
    case 'DID Revoked': return 'text-tg-danger';
    case 'Deleted': return 'text-tg-text-muted line-through';
    default: return 'text-tg-text-muted';
  }
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

  const handleRevokeDid = async (userEmail: string) => {
    try {
      const res = await userApi.revokeDid(userEmail);
      if (res.ok) {
        toast.success('DID revoked on-chain.');
        setActionResult(null);
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        toast.error((res.data as any).message || 'Failed to revoke DID');
      }
    } catch {
      toast.error('Connection failed');
    }
  };

  const handleDeleteUser = async (userEmail: string) => {
    try {
      const res = await userApi.deleteUser(userEmail);
      if (res.ok) {
        toast.success('User deleted.');
        setActionResult(null);
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        toast.error((res.data as any).message || 'Failed to delete user');
      }
    } catch {
      toast.error('Connection failed');
    }
  };

  const handlePermanentDeleteUser = async (userEmail: string) => {
    try {
      const res = await userApi.permanentDeleteUser(userEmail);
      if (res.ok) {
        toast.success('User permanently deleted.');
        setActionResult(null);
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        toast.error((res.data as any).message || 'Failed to permanently delete user');
      }
    } catch {
      toast.error('Connection failed');
    }
  };

  const handleReactivateDid = async (userEmail: string) => {
    try {
      const res = await userApi.reactivateDid(userEmail);
      if (res.ok) {
        toast.success('New DID assigned successfully.');
        setActionResult({ type: 'assign', data: res.data as AssignDidResponse });
        queryClient.invalidateQueries({ queryKey: ['users'] });
      } else {
        toast.error((res.data as any).message || 'Failed to reactivate DID');
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
                  <th className="pb-2 pr-4">Status</th>
                  <th className="pb-2">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {data.data.users.map((u: UserInfo) => {
                  const status = getUserStatus(u);
                  return (
                  <tr key={u.email} className="hover:bg-tg-surface transition-colors">
                    <td className="py-3 pr-4 text-foreground">{u.email}</td>
                    <td className="py-3 pr-4"><StatusBadge status={u.role} /></td>
                    <td className="py-3 pr-4">{u.did ? <DIDDisplay did={u.did} /> : <span className="text-tg-text-muted">None</span>}</td>
                    <td className="py-3 pr-4">
                      <span className={`text-xs font-medium ${getStatusColor(status)}`}>{status}</span>
                    </td>
                    <td className="py-3">
                      {u.source === 'dynamic' && status !== 'Deleted' && (
                        <div className="flex gap-2 flex-wrap">
                          {status !== 'DID Revoked' && (
                            <>
                              {!u.did && (
                                <LoadingButton size="sm" variant="outline" className="min-w-[7rem]" onClick={() => handleAssignDid(u.email)}>
                                  Assign DID
                                </LoadingButton>
                              )}
                              {u.did && !u.authorized && (
                                <LoadingButton size="sm" variant="outline" className="min-w-[7rem]" onClick={() => handleAuthorize(u.email)}>
                                  Authorize
                                </LoadingButton>
                              )}
                              {u.did && u.authorized && (
                                <ConfirmDialog
                                  trigger={<LoadingButton size="sm" variant="outline" className="min-w-[7rem]">Unauthorize</LoadingButton>}
                                  message={`Revoke credentials for ${u.email}?`}
                                  cancelLabel="Go back"
                                  onConfirm={() => handleUnauthorize(u.email)}
                                />
                              )}
                              {u.did && (
                                <ConfirmDialog
                                  trigger={<LoadingButton size="sm" variant="outline" className="min-w-[7rem]">Revoke DID</LoadingButton>}
                                  title="Revoke DID"
                                  message={`This will permanently deactivate the DID assigned to ${u.email} on-chain. This action is irreversible.`}
                                  confirmLabel="Revoke"
                                  cancelLabel="Go back"
                                  onConfirm={() => handleRevokeDid(u.email)}
                                />
                              )}
                            </>
                          )}
                          {status === 'DID Revoked' && (
                            <ConfirmDialog
                              trigger={<LoadingButton size="sm" variant="outline" className="min-w-[7rem]">Reactivate DID</LoadingButton>}
                              title="Reactivate DID"
                              message={`The previous DID was permanently deactivated. This will generate and publish a new DID on-chain for ${u.email}, resetting their status to Unauthorized.`}
                              confirmLabel="Reactivate"
                              cancelLabel="Go back"
                              destructive={false}
                              onConfirm={() => handleReactivateDid(u.email)}
                            />
                          )}
                          <ConfirmDialog
                            trigger={<LoadingButton size="sm" variant="destructive" className="min-w-[7rem]">Delete User</LoadingButton>}
                            title="Delete User"
                            message={`This will irreversibly delete ${u.email}'s credentials from the system. Their DID will be revoked on-chain and their access will be permanently disabled.`}
                            confirmLabel="Delete"
                            cancelLabel="Go back"
                            onConfirm={() => handleDeleteUser(u.email)}
                          />
                        </div>
                      )}
                      {u.source === 'dynamic' && status === 'Deleted' && !u.did && (
                        <ConfirmDialog
                          trigger={<LoadingButton size="sm" variant="destructive" className="min-w-[7rem]">Permanently Delete</LoadingButton>}
                          title="Permanently Delete User"
                          message={`This will permanently remove ${u.email} from the database. This action cannot be undone.`}
                          confirmLabel="Permanently Delete"
                          cancelLabel="Go back"
                          onConfirm={() => handlePermanentDeleteUser(u.email)}
                        />
                      )}
                    </td>
                  </tr>
                  );
                })}
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
