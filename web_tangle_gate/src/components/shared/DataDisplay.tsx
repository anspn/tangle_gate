import { useState } from 'react';
import { Copy, Check } from 'lucide-react';
import { toast } from 'sonner';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';

export function DIDDisplay({ did }: { did: string }) {
  const truncated = did.length > 30 ? `${did.slice(0, 16)}...${did.slice(-8)}` : did;

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <span className="inline-flex items-center gap-1.5 font-mono text-sm text-tg-text-secondary">
          {truncated}
          <CopyBtn value={did} />
        </span>
      </TooltipTrigger>
      <TooltipContent className="max-w-sm break-all font-mono text-xs">
        {did}
      </TooltipContent>
    </Tooltip>
  );
}

export function HashDisplay({ hash }: { hash: string }) {
  return (
    <div className="flex items-start gap-2">
      <code className="font-mono text-xs text-tg-text-secondary break-all">{hash}</code>
      <CopyBtn value={hash} />
    </div>
  );
}

export function CopyableField({ value, label }: { value: string; label?: string }) {
  return (
    <div className="space-y-1.5">
      {label && <span className="text-sm font-medium text-tg-text-muted">{label}</span>}
      <div className="flex items-center gap-2 rounded-md bg-tg-surface px-3 py-2.5 font-mono text-sm text-tg-text-secondary break-all">
        <span className="flex-1 min-w-0">{value}</span>
        <CopyBtn value={value} />
      </div>
    </div>
  );
}

export function SensitiveDisplay({ value, warning }: { value: string; warning: string }) {
  return (
    <div className="rounded-lg border border-tg-warning bg-tg-warning-bg p-4 space-y-2">
      <p className="text-xs font-medium text-tg-warning">{warning}</p>
      <div className="flex items-start gap-2">
        <pre className="flex-1 min-w-0 whitespace-pre-wrap break-all font-mono text-xs text-tg-text-secondary">
          {typeof value === 'object' ? JSON.stringify(value, null, 2) : value}
        </pre>
        <CopyBtn value={typeof value === 'object' ? JSON.stringify(value) : value} />
      </div>
    </div>
  );
}

function CopyBtn({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    await navigator.clipboard.writeText(value);
    setCopied(true);
    toast.success('Copied!', { duration: 2000 });
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <button onClick={copy} className="shrink-0 text-tg-text-muted hover:text-tg-text-primary transition-colors">
      {copied ? <Check className="h-3.5 w-3.5 text-tg-success" /> : <Copy className="h-3.5 w-3.5" />}
    </button>
  );
}
