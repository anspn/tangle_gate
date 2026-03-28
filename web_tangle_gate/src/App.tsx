import { useEffect } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter, Route, Routes } from 'react-router-dom';
import { Toaster as Sonner } from '@/components/ui/sonner';
import { TooltipProvider } from '@/components/ui/tooltip';
import { useAuthStore } from '@/stores/auth';
import { RequireAuth, RedirectIfAuthed } from '@/components/auth/RouteGuards';
import AppLayout from '@/components/layout/AppLayout';
import LoginPage from '@/pages/LoginPage';
import DashboardPage from '@/pages/DashboardPage';
import IdentityPage from '@/pages/IdentityPage';
import PortalPage from '@/pages/PortalPage';
import SessionsPage from '@/pages/SessionsPage';
import VerifyPage from '@/pages/VerifyPage';
import AgentPage from '@/pages/AgentPage';
import NotFound from '@/pages/NotFound';

const queryClient = new QueryClient();

function AuthInitializer({ children }: { children: React.ReactNode }) {
  const initialize = useAuthStore((s) => s.initialize);
  useEffect(() => { initialize(); }, [initialize]);
  return <>{children}</>;
}

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <Sonner />
      <BrowserRouter>
        <AuthInitializer>
          <Routes>
            <Route path="/login" element={<RedirectIfAuthed><LoginPage /></RedirectIfAuthed>} />
            <Route element={<AppLayout />}>
              <Route path="/" element={<RequireAuth roles={['admin']}><DashboardPage /></RequireAuth>} />
              <Route path="/identity" element={<RequireAuth roles={['admin']}><IdentityPage /></RequireAuth>} />
              <Route path="/agent" element={<RequireAuth roles={['admin']}><AgentPage /></RequireAuth>} />
              <Route path="/portal" element={<RequireAuth roles={['user']}><PortalPage /></RequireAuth>} />
              <Route path="/sessions" element={<RequireAuth roles={['admin', 'user']}><SessionsPage /></RequireAuth>} />
              <Route path="/verify" element={<RequireAuth roles={['admin', 'verifier']}><VerifyPage /></RequireAuth>} />
            </Route>
            <Route path="*" element={<NotFound />} />
          </Routes>
        </AuthInitializer>
      </BrowserRouter>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;
