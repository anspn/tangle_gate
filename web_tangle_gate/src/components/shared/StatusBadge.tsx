import { cn } from '@/lib/utils';

const statusConfig = {
  active: { label: 'Active', className: 'bg-tg-info-bg text-tg-info' },
  ended: { label: 'Ended', className: 'bg-tg-surface text-tg-text-muted' },
  notarized: { label: 'Notarized', className: 'bg-tg-success-bg text-tg-success' },
  failed: { label: 'Failed', className: 'bg-tg-danger-bg text-tg-danger' },
  ok: { label: 'Healthy', className: 'bg-tg-success-bg text-tg-success' },
  degraded: { label: 'Degraded', className: 'bg-tg-warning-bg text-tg-warning' },
};

export function StatusBadge({ status }: { status: string }) {
  const config = statusConfig[status as keyof typeof statusConfig] || {
    label: status,
    className: 'bg-tg-surface text-tg-text-muted',
  };

  return (
    <span className={cn('inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-sm font-medium', config.className)}>
      {(status === 'active' || status === 'ok') && (
        <span className="h-1.5 w-1.5 rounded-full bg-current animate-pulse-dot" />
      )}
      {config.label}
    </span>
  );
}
