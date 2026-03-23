import { Navigate } from 'react-router-dom';
import { useAuthStore } from '@/stores/auth';

const roleLanding = {
  admin: '/',
  user: '/portal',
  verifier: '/verify',
};

export function RequireAuth({ roles, children }: { roles: string[]; children: React.ReactNode }) {
  const { isLoggedIn, role } = useAuthStore();

  if (!isLoggedIn) return <Navigate to="/login" replace />;
  if (role && !roles.includes(role)) {
    return <Navigate to={roleLanding[role as keyof typeof roleLanding] || '/login'} replace />;
  }

  return <>{children}</>;
}

export function RedirectIfAuthed({ children }: { children: React.ReactNode }) {
  const { isLoggedIn, role } = useAuthStore();

  if (isLoggedIn && role) {
    return <Navigate to={roleLanding[role as keyof typeof roleLanding] || '/'} replace />;
  }

  return <>{children}</>;
}
