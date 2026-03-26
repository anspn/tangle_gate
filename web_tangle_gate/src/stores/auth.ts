import { create } from 'zustand';
import type { User } from '@/types';

interface AuthState {
  token: string | null;
  role: 'admin' | 'user' | 'verifier' | null;
  user: User | null;
  isLoggedIn: boolean;
  ready: boolean;
  login: (token: string, user: User) => void;
  logout: () => void;
  initialize: () => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  token: null,
  role: null,
  user: null,
  isLoggedIn: false,
  ready: false,

  login: (token, user) => {
    sessionStorage.setItem('iota_token', token);
    sessionStorage.setItem('iota_role', user.role);
    set({ token, role: user.role, user, isLoggedIn: true });
  },

  logout: () => {
    sessionStorage.removeItem('iota_token');
    sessionStorage.removeItem('iota_role');
    sessionStorage.removeItem('iota_portal_did');
    sessionStorage.removeItem('iota_portal_session');
    set({ token: null, role: null, user: null, isLoggedIn: false });
    window.location.href = '/login';
  },

  initialize: () => {
    const token = sessionStorage.getItem('iota_token');
    const role = sessionStorage.getItem('iota_role') as AuthState['role'];
    if (token && role) {
      set({ token, role, isLoggedIn: true, user: { id: '', email: '', role }, ready: true });
    } else {
      set({ ready: true });
    }
  },
}));
