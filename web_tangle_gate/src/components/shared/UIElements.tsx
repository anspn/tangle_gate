import { cn } from '@/lib/utils';
import { AlertCircle, AlertTriangle, CheckCircle2, Info } from 'lucide-react';

const typeConfig = {
  success: { className: 'bg-tg-success-bg border-tg-success text-tg-success', icon: CheckCircle2 },
  error: { className: 'bg-tg-danger-bg border-tg-danger text-tg-danger', icon: AlertCircle },
  warning: { className: 'bg-amber-50 border-amber-400 text-amber-700 dark:bg-amber-950/30 dark:border-amber-600 dark:text-amber-400', icon: AlertTriangle },
  info: { className: 'bg-tg-info-bg border-tg-info text-tg-info', icon: Info },
};

export function InlineNotice({ type, message }: { type: 'success' | 'error' | 'warning' | 'info'; message: string }) {
  const config = typeConfig[type];
  const Icon = config.icon;

  return (
    <div className={cn('flex items-center gap-2.5 rounded-lg border px-4 py-3 text-sm', config.className)}>
      <Icon className="h-5 w-5 shrink-0" />
      {message}
    </div>
  );
}

export function EmptyState({ message }: { message: string }) {
  return (
    <div className="flex items-center justify-center py-16">
      <p className="text-base italic text-tg-text-muted">{message}</p>
    </div>
  );
}

export function PageHeader({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div className="space-y-1.5">
      <h1 className="text-3xl font-semibold tracking-tight text-foreground">{title}</h1>
      {subtitle && <p className="text-base text-tg-text-secondary">{subtitle}</p>}
    </div>
  );
}

export function StatCard({ label, value, color }: { label: string; value: string | number; color?: string }) {
  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <p className="text-sm font-medium text-tg-text-muted">{label}</p>
      <p className={cn('mt-1.5 text-4xl font-bold tracking-tight', color || 'text-foreground')}>
        {value}
      </p>
    </div>
  );
}
