import { useState } from 'react';
import { ChevronRight, ChevronDown } from 'lucide-react';

export function JsonViewer({ data, collapsed = true }: { data: unknown; collapsed?: boolean }) {
  const [isCollapsed, setIsCollapsed] = useState(collapsed);
  const json = typeof data === 'string' ? data : JSON.stringify(data, null, 2);

  return (
    <div className="rounded-lg border border-border bg-tg-surface overflow-hidden">
      <button
        onClick={() => setIsCollapsed(!isCollapsed)}
        className="flex items-center gap-1 w-full px-3 py-2 text-xs font-medium text-tg-text-muted hover:bg-tg-surface-hover transition-colors"
      >
        {isCollapsed ? <ChevronRight className="h-3.5 w-3.5" /> : <ChevronDown className="h-3.5 w-3.5" />}
        JSON Response
      </button>
      {!isCollapsed && (
        <pre className="px-3 pb-3 overflow-auto max-h-80 text-xs font-mono text-tg-text-secondary whitespace-pre-wrap">
          {json}
        </pre>
      )}
    </div>
  );
}
