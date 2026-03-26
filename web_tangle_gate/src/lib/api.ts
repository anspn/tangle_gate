import type {
  LoginRequest, LoginResponse, ChallengeResponse, VPLoginRequest, VPLoginResponse,
  CreateDidRequest, DidResponse, ApiError, UserInfo, CreateUserRequest,
  AssignDidResponse, AuthorizeResponse, Session, SessionStats,
  CreateVPForSessionRequest, CreateVPForSessionResponse, StartSessionRequest,
  OnChainNotarization, HashResponse, HealthResponse, ServerDidInfo, DashboardStats,
} from '@/types';

const API_BASE = '/api';

interface ApiResponse<T> {
  status: number;
  data: T;
  ok: boolean;
}

async function api<T>(
  method: 'GET' | 'POST',
  path: string,
  body?: unknown
): Promise<ApiResponse<T>> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const token = sessionStorage.getItem('iota_token');
  if (token) headers['Authorization'] = `Bearer ${token}`;

  const opts: RequestInit = { method, headers };
  if (body) opts.body = JSON.stringify(body);

  const res = await fetch(`${API_BASE}${path}`, opts);

  if (res.status === 401 && window.location.pathname !== '/login') {
    sessionStorage.removeItem('iota_token');
    sessionStorage.removeItem('iota_role');
    window.location.href = '/login';
  }

  const data = await res.json();
  return { status: res.status, data: data as T, ok: res.ok };
}

export const authApi = {
  login: (req: LoginRequest) => api<LoginResponse>('POST', '/auth/login', req),
  getChallenge: () => api<ChallengeResponse>('GET', '/auth/challenge'),
  vpLogin: async (req: VPLoginRequest): Promise<ApiResponse<VPLoginResponse>> => {
    const res = await fetch(`${API_BASE}/auth/present-with-credential`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    });
    const data = await res.json();
    return { status: res.status, data, ok: res.ok };
  },
};

export const identityApi = {
  create: (req: CreateDidRequest) => api<DidResponse>('POST', '/dids', req),
  resolve: (did: string) => api<DidResponse>('GET', `/dids/${encodeURIComponent(did)}`),
  revoke: (did: string) => api<ApiError>('POST', `/dids/${encodeURIComponent(did)}/revoke`, {}),
};

export const userApi = {
  list: () => api<{ users: UserInfo[]; count: number }>('GET', '/credentials/users'),
  create: (req: CreateUserRequest) => api<UserInfo>('POST', '/credentials/users', req),
  assignDid: (email: string) => api<AssignDidResponse>('POST', `/credentials/users/${encodeURIComponent(email)}/assign-did`, {}),
  authorize: (email: string) => api<AuthorizeResponse>('POST', `/credentials/users/${encodeURIComponent(email)}/authorize`, {}),
  unauthorize: (email: string) => api<ApiError>('POST', `/credentials/users/${encodeURIComponent(email)}/unauthorize`, {}),
  revokeDid: (email: string) => api<{ email: string; did: string; status: string; message: string }>('POST', `/credentials/users/${encodeURIComponent(email)}/revoke-did`, {}),
  deleteUser: (email: string) => api<{ email: string; did: string; status: string; message: string }>('POST', `/credentials/users/${encodeURIComponent(email)}/delete`, {}),
  reactivateDid: (email: string) => api<AssignDidResponse>('POST', `/credentials/users/${encodeURIComponent(email)}/reactivate-did`, {}),
};

export const sessionApi = {
  createVP: (req: CreateVPForSessionRequest) => api<CreateVPForSessionResponse>('POST', '/sessions/create-vp', req),
  start: (req: StartSessionRequest) => api<Session>('POST', '/sessions', req),
  end: (id: string) => api<Session>('POST', `/sessions/${id}/end`),
  list: (params?: Record<string, string>) => {
    const qs = params ? '?' + new URLSearchParams(params).toString() : '';
    return api<{ sessions: Session[]; count: number }>('GET', `/sessions${qs}`);
  },
  get: (id: string) => api<Session>('GET', `/sessions/${id}`),
  stats: () => api<SessionStats>('GET', '/sessions/stats'),
};

export const verifyApi = {
  readOnChain: (objectId: string) => api<OnChainNotarization>('GET', `/verify/${objectId}`),
  computeHash: (data: string) => api<HashResponse>('POST', '/verify/hash', { data }),
};

export const healthApi = {
  check: () => api<HealthResponse>('GET', '/health'),
};

export const credentialApi = {
  getServerDid: () => api<ServerDidInfo>('GET', '/credentials/server-did'),
};

export const dashboardApi = {
  stats: () => api<DashboardStats>('GET', '/dashboard/stats'),
};

export async function downloadSession(sessionId: string): Promise<void> {
  const token = sessionStorage.getItem('iota_token');
  const res = await fetch(`/api/sessions/${sessionId}/download`, {
    headers: { Authorization: `Bearer ${token ?? ''}` },
  });
  if (!res.ok) return;
  const blob = await res.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `session_${sessionId}.json`;
  a.click();
  URL.revokeObjectURL(url);
}
