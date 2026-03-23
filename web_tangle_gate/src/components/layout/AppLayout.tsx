import { useState } from 'react';
import { Outlet, Link, useLocation } from 'react-router-dom';
import { useAuthStore } from '@/stores/auth';
import { cn } from '@/lib/utils';
import { LogOut, LayoutDashboard, Fingerprint, Terminal, List, CheckCircle, Menu, X } from 'lucide-react';
import { Button } from '@/components/ui/button';

declare const __APP_VERSION__: string;

const navItems = {
  admin: [
    { path: '/', label: 'Dashboard', icon: LayoutDashboard },
    { path: '/identity', label: 'Identity', icon: Fingerprint },
    { path: '/sessions', label: 'Sessions', icon: List },
    { path: '/verify', label: 'Verify', icon: CheckCircle },
  ],
  user: [
    { path: '/portal', label: 'Portal', icon: Terminal },
    { path: '/sessions', label: 'Sessions', icon: List },
  ],
  verifier: [
    { path: '/verify', label: 'Verify', icon: CheckCircle },
  ],
};

function NavBar() {
  const { role, logout } = useAuthStore();
  const location = useLocation();
  const items = role ? navItems[role] || [] : [];
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <header className="sticky top-0 z-50 border-b border-border bg-card/80 backdrop-blur-md">
      <div className="container flex h-16 items-center justify-between">
        <div className="flex items-center gap-8">
          <Link to="/" className="flex items-center gap-2.5">
            <img src="/logo.svg" alt="TangleGate" className="h-7 w-7" />
            <span className="text-lg font-semibold text-foreground">TangleGate</span>
          </Link>
          <nav className="hidden md:flex items-center gap-1">
            {items.map(({ path, label, icon: Icon }) => (
              <Link
                key={path}
                to={path}
                className={cn(
                  'flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium transition-colors',
                  location.pathname === path
                    ? 'bg-tg-accent-soft text-primary'
                    : 'text-tg-text-secondary hover:text-foreground hover:bg-tg-surface'
                )}
              >
                <Icon className="h-4.5 w-4.5" />
                {label}
              </Link>
            ))}
          </nav>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={logout} className="hidden md:inline-flex text-tg-text-secondary hover:text-foreground">
            <LogOut className="mr-1.5 h-4.5 w-4.5" />
            Logout
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="md:hidden text-tg-text-secondary hover:text-foreground"
            onClick={() => setMobileOpen(!mobileOpen)}
            aria-label="Toggle menu"
          >
            {mobileOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
          </Button>
        </div>
      </div>

      {/* Mobile menu */}
      {mobileOpen && (
        <div className="md:hidden border-t border-border bg-card/95 backdrop-blur-md">
          <nav className="container flex flex-col gap-1 py-3">
            {items.map(({ path, label, icon: Icon }) => (
              <Link
                key={path}
                to={path}
                onClick={() => setMobileOpen(false)}
                className={cn(
                  'flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors',
                  location.pathname === path
                    ? 'bg-tg-accent-soft text-primary'
                    : 'text-tg-text-secondary hover:text-foreground hover:bg-tg-surface'
                )}
              >
                <Icon className="h-4 w-4" />
                {label}
              </Link>
            ))}
            <button
              onClick={() => { setMobileOpen(false); logout(); }}
              className="flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium text-tg-text-secondary hover:text-foreground hover:bg-tg-surface transition-colors"
            >
              <LogOut className="h-4 w-4" />
              Logout
            </button>
          </nav>
        </div>
      )}
    </header>
  );
}

function Footer() {
  return (
    <footer className="border-t border-border py-5">
      <div className="container text-center text-sm text-tg-text-muted">
        © 2026 anspn · TangleGate v{__APP_VERSION__} · MIT License
      </div>
    </footer>
  );
}

export default function AppLayout() {
  return (
    <div className="flex min-h-screen flex-col">
      <NavBar />
      <main className="container flex-1 py-8">
        <Outlet />
      </main>
      <Footer />
    </div>
  );
}
