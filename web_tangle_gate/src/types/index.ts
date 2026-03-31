// ============================================================================
// Common
// ============================================================================
export interface ApiError {
  error: string;
  message: string;
}

// ============================================================================
// Auth
// ============================================================================
export interface User {
  id: string;
  email: string;
  role: 'admin' | 'user' | 'verifier';
}

export interface LoginRequest {
  email: string;
  password: string;
}

export interface LoginResponse {
  token: string;
  expires_at: string;
  user: User;
}

// ============================================================================
// Users & Identity
// ============================================================================
export interface UserInfo {
  email: string;
  role: string;
  did: string | null;
  authorized?: boolean;
  status?: 'active' | 'did_revoked' | 'deleted';
  source: 'dynamic' | 'config';
}

export interface CreateUserRequest {
  email: string;
  password: string;
  role?: 'user' | 'verifier';
}

export interface AssignDidResponse {
  email: string;
  did: string;
  did_document: string;
  verification_method_fragment: string;
  private_key_jwk: Record<string, string>;
  message: string;
}

export interface AuthorizeResponse {
  email: string;
  did: string;
  authorized: boolean;
  credential_jwt: string;
  message: string;
}

export interface CredentialBundle {
  email: string;
  did: string;
  private_key_jwk?: Record<string, string>;
  verification_method_fragment?: string;
  credential_jwt?: string;
}

export interface CreateDidRequest {
  publish?: boolean;
  network?: 'iota' | 'smr' | 'rms' | 'atoi';
}

export interface DidResponse {
  did: string;
  network: string;
  label: string | null;
  created_at: string;
  status: string;
  document: Record<string, any> | null;
}

export interface ServerDidInfo {
  did: string;
  network: string;
  verification_method_fragment: string;
  published_at?: string;
}

// ============================================================================
// Sessions
// ============================================================================
export interface Session {
  session_id: string;
  did: string;
  user_id: string;
  started_at: string;
  ended_at: string | null;
  status: 'active' | 'ended' | 'notarized' | 'failed';
  command_count: number;
  notarization_hash: string | null;
  on_chain_id: string | null;
  error: string | null;
  commands?: SessionCommand[];
}

export interface SessionCommand {
  command: string;
  timestamp?: string;
}

export interface SessionStats {
  total: number;
  active: number;
  notarized: number;
  failed: number;
}

export interface CreateVPForSessionRequest {
  credential_jwt: string;
  private_key_jwk: string;
}

export interface CreateVPForSessionResponse {
  presentation_jwt: string;
  challenge: string;
  holder_did: string;
}

export interface StartSessionRequest {
  presentation_jwt: string;
  challenge: string;
  holder_did: string;
}

// ============================================================================
// Verification
// ============================================================================
export interface OnChainNotarization {
  object_id: string;
  state_data: string;
  state_metadata: string | null;
  description: string;
  method: 'Locked' | 'Dynamic';
  immutable: boolean;
  created_at: number;
  last_state_change_at: number;
  state_version_count: number;
}

export interface HashResponse {
  hash: string;
  algorithm: string;
  data_size: number;
}

// ============================================================================
// Health
// ============================================================================
export interface HealthResponse {
  status: string;
  nif_loaded: boolean;
  agent_reachable: boolean;
  ledger_reachable: boolean;
  timestamp: string;
}

// ============================================================================
// Agent
// ============================================================================
export interface AgentStatus {
  agent_reachable: boolean;
  ws_connected: boolean;
  ws_url: string;
  timestamp: string;
}

export interface AgentConfig {
  url: string;
  ws_url: string;
  api_key: string;
  timeout: number;
}

// ============================================================================
// Dashboard
// ============================================================================
export interface DashboardStats {
  users: {
    total: number;
    by_status: Record<string, number>;
    authorized: number;
    unauthorized: number;
  };
  credentials: {
    total: number;
    active: number;
    revoked: number;
    by_date: Array<{ date: string; count: number }>;
    revoked_by_date: Array<{ date: string; count: number }>;
  };
  sessions_by_date: Array<{
    date: string;
    total: number;
    notarized: number;
  }>;
  logins_by_date: Array<{
    date: string;
    user_logins: number;
    verifier_logins: number;
  }>;
}
