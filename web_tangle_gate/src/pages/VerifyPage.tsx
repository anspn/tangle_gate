import { useState, useRef } from 'react';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Button } from '@/components/ui/button';
import { LoadingButton } from '@/components/shared/LoadingButton';
import { InlineNotice, PageHeader } from '@/components/shared/UIElements';
import { HashDisplay, CopyableField } from '@/components/shared/DataDisplay';
import { verifyApi } from '@/lib/api';
import { toast } from 'sonner';
import type { OnChainNotarization } from '@/types';
import { CheckCircle2, XCircle, Upload, Trash2 } from 'lucide-react';

export default function VerifyPage() {
  // On-chain card state
  const [objectId, setObjectId] = useState('');
  const [onChainResult, setOnChainResult] = useState<OnChainNotarization | null>(null);
  const [onChainError, setOnChainError] = useState('');
  const [onChainLoading, setOnChainLoading] = useState(false);
  const [onChainEmptyWarning, setOnChainEmptyWarning] = useState(false);

  // Hash card state
  const [documentText, setDocumentText] = useState('');
  const [fileName, setFileName] = useState<string | null>(null);
  const [contentHash, setContentHash] = useState('');
  const [hashLoading, setHashLoading] = useState(false);
  const [hashEmptyWarning, setHashEmptyWarning] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  // Match state
  const [verifyLoading, setVerifyLoading] = useState(false);
  const [matchResult, setMatchResult] = useState<'match' | 'mismatch' | null>(null);

  // -- On-chain read logic --
  const doReadOnChain = async (id: string): Promise<string | null> => {
    if (!id.trim()) {
      setOnChainEmptyWarning(true);
      return null;
    }
    if (!/^0x[a-fA-F0-9]+$/.test(id)) {
      setOnChainError('Invalid Object ID format. Expected: 0x...');
      return null;
    }
    setOnChainError('');
    setOnChainEmptyWarning(false);
    setOnChainLoading(true);
    try {
      const res = await verifyApi.readOnChain(id);
      if (res.ok) {
        setOnChainResult(res.data);
        return res.data.state_data;
      } else {
        setOnChainError((res.data as any).message || 'Failed to read on-chain data');
        return null;
      }
    } catch {
      setOnChainError('Connection failed');
      return null;
    } finally {
      setOnChainLoading(false);
    }
  };

  // -- Hash compute logic --
  const doComputeHash = async (text: string): Promise<string | null> => {
    if (!text.trim()) {
      setHashEmptyWarning(true);
      return null;
    }
    setHashEmptyWarning(false);
    setHashLoading(true);
    try {
      const res = await verifyApi.computeHash(text);
      if (res.ok) {
        setContentHash(res.data.hash);
        return res.data.hash;
      } else {
        toast.error('Hash computation failed');
        return null;
      }
    } catch {
      toast.error('Connection failed');
      return null;
    } finally {
      setHashLoading(false);
    }
  };

  const handleVerifyMatch = async () => {
    setVerifyLoading(true);
    setMatchResult(null);

    // Trigger both operations in parallel, treating each independently
    const chainPromise = onChainResult
      ? Promise.resolve(onChainResult.state_data)
      : doReadOnChain(objectId);

    const hashPromise = contentHash
      ? Promise.resolve(contentHash)
      : doComputeHash(documentText);

    const [chainHash, docHash] = await Promise.all([chainPromise, hashPromise]);

    // Both must succeed for comparison
    if (chainHash && docHash) {
      setMatchResult(chainHash === docHash ? 'match' : 'mismatch');
    }
    setVerifyLoading(false);
  };

  // -- Clear handlers --
  const handleClearOnChain = () => {
    setObjectId('');
    setOnChainResult(null);
    setOnChainError('');
    setOnChainEmptyWarning(false);
    setMatchResult(null);
  };

  const handleClearHash = () => {
    setDocumentText('');
    setFileName(null);
    setContentHash('');
    setHashEmptyWarning(false);
    setMatchResult(null);
    if (fileRef.current) fileRef.current.value = '';
  };

  return (
    <div className="space-y-6">
      <PageHeader title="Verification" subtitle="Read on-chain notarizations and verify document integrity" />
      <div className="grid gap-6 lg:grid-cols-2">
        {/* Search Object card */}
        <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
          <h3 className="text-sm font-semibold mb-4 text-foreground">Search Object</h3>
          <form onSubmit={(e) => { e.preventDefault(); doReadOnChain(objectId).then(() => setMatchResult(null)); }} className="space-y-4">
            <div className="space-y-2">
              <Label>Object ID</Label>
              <Input value={objectId} onChange={(e) => { setObjectId(e.target.value); setOnChainError(''); setOnChainEmptyWarning(false); setOnChainResult(null); setMatchResult(null); }} placeholder="0x..." />
            </div>
            {onChainError && <InlineNotice type="error" message={onChainError} />}
            {onChainEmptyWarning && <InlineNotice type="error" message="An empty input will never match any document" />}
            <div className="flex gap-2">
              <LoadingButton type="submit" loading={onChainLoading} className="flex-1">Compute Hash</LoadingButton>
              {objectId.trim() && (
                <Button type="button" variant="outline" onClick={handleClearOnChain}>
                  <Trash2 className="mr-2 h-4 w-4" />
                  Clear Content
                </Button>
              )}
            </div>
          </form>
          {onChainResult && (
            <div className="mt-4 space-y-3">
              <CopyableField value={onChainResult.object_id} label="Object ID" />
              <div>
                <span className="text-xs text-tg-text-muted">State Data (Hash)</span>
                <div className="mt-1"><HashDisplay hash={onChainResult.state_data} /></div>
              </div>
              <div className="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <span className="text-xs text-tg-text-muted">Description</span>
                  <p className="mt-1 text-tg-text-secondary">{onChainResult.description}</p>
                </div>
                <div>
                  <span className="text-xs text-tg-text-muted">Immutable</span>
                  <p className="mt-1 text-tg-text-secondary">{onChainResult.immutable ? 'Yes' : 'No'}</p>
                </div>
              </div>
              <div>
                <span className="text-xs text-tg-text-muted">Notarized On</span>
                <p className="mt-1 text-sm text-tg-text-secondary">{formatTimestamp(onChainResult.created_at)}</p>
              </div>
            </div>
          )}
        </div>

        {/* Document Hash card */}
        <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
          <h3 className="text-sm font-semibold mb-4 text-foreground">Document Hash</h3>
          <form onSubmit={(e) => { e.preventDefault(); doComputeHash(documentText).then(() => setMatchResult(null)); }} className="space-y-4">
            <div className="space-y-2">
              <Label>Session Document JSON</Label>
              <Textarea
                value={documentText}
                onChange={(e) => { setDocumentText(e.target.value); setHashEmptyWarning(false); setContentHash(''); setMatchResult(null); }}
                rows={6}
                placeholder="Paste session JSON or upload a file..."
              />
            </div>
            {hashEmptyWarning && <InlineNotice type="error" message="An empty input will never match any document" />}
            <div className="flex items-center gap-3">
              <Label className="shrink-0 mb-0">Or upload file</Label>
              <input ref={fileRef} type="file" accept=".json" onChange={(e) => {
                const file = e.target.files?.[0];
                if (!file) return;
                setFileName(file.name);
                setHashEmptyWarning(false);
                setContentHash('');
                setMatchResult(null);
                const reader = new FileReader();
                reader.onload = (ev) => setDocumentText(ev.target?.result as string || '');
                reader.readAsText(file);
              }} className="hidden" />
              <Button
                type="button"
                variant="outline"
                className="cursor-pointer"
                onClick={() => fileRef.current?.click()}
              >
                <Upload className="mr-2 h-4 w-4" />
                {fileName ?? 'Choose File'}
              </Button>
            </div>
            <div className="flex gap-2">
              <LoadingButton type="submit" loading={hashLoading} className="flex-1">Compute Hash</LoadingButton>
              {documentText.trim() && (
                <Button type="button" variant="outline" onClick={handleClearHash}>
                  <Trash2 className="mr-2 h-4 w-4" />
                  Clear Content
                </Button>
              )}
            </div>
          </form>
          {contentHash && (
            <div className="mt-4">
              <span className="text-xs text-tg-text-muted">Content Hash</span>
              <div className="mt-1"><HashDisplay hash={contentHash} /></div>
            </div>
          )}
        </div>
      </div>

      <LoadingButton
        loading={verifyLoading}
        onClick={handleVerifyMatch}
        className="w-full py-3 text-base font-semibold"
        size="lg"
      >
        Verify Match
      </LoadingButton>

      {matchResult && onChainResult && contentHash && (
        <MatchResult
          onChainHash={onChainResult.state_data}
          computedHash={contentHash}
          match={matchResult === 'match'}
        />
      )}
    </div>
  );
}

function formatTimestamp(ts: number): string {
  if (!ts) return '—';
  const date = new Date(ts);
  return date.toLocaleString();
}

function MatchResult({ onChainHash, computedHash, match }: { onChainHash: string; computedHash: string; match: boolean }) {
  return (
    <div className={`rounded-lg border p-5 ${match ? 'border-tg-success bg-tg-success-bg' : 'border-tg-danger bg-tg-danger-bg'}`}>
      <div className="flex items-center gap-3 mb-4">
        {match ? (
          <><CheckCircle2 className="h-6 w-6 text-tg-success" /><span className="text-lg font-bold text-tg-success">MATCH</span></>
        ) : (
          <><XCircle className="h-6 w-6 text-tg-danger" /><span className="text-lg font-bold text-tg-danger">MISMATCH</span></>
        )}
      </div>
      <div className="space-y-2">
        <div>
          <span className="text-xs text-tg-text-muted">On-Chain Hash</span>
          <p className="font-mono text-xs text-tg-text-secondary break-all">{onChainHash}</p>
        </div>
        <div>
          <span className="text-xs text-tg-text-muted">Computed Hash</span>
          <p className="font-mono text-xs text-tg-text-secondary break-all">{computedHash}</p>
        </div>
      </div>
    </div>
  );
}
