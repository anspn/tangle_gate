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
import { CheckCircle2, XCircle, Upload } from 'lucide-react';

export default function VerifyPage() {
  const [onChainData, setOnChainData] = useState<OnChainNotarization | null>(null);
  const [computedHash, setComputedHash] = useState('');

  return (
    <div className="space-y-6">
      <PageHeader title="Verification" subtitle="Read on-chain notarizations and verify document integrity" />
      <div className="grid gap-6 lg:grid-cols-2">
        <OnChainReadCard onData={setOnChainData} />
        <HashCompareCard onChainHash={onChainData?.state_data || null} onComputed={setComputedHash} />
      </div>
      {onChainData && computedHash && (
        <MatchResult onChainHash={onChainData.state_data} computedHash={computedHash} />
      )}
    </div>
  );
}

function OnChainReadCard({ onData }: { onData: (data: OnChainNotarization) => void }) {
  const [objectId, setObjectId] = useState('');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<OnChainNotarization | null>(null);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!/^0x[a-fA-F0-9]+$/.test(objectId)) {
      setError('Invalid Object ID format. Expected: 0x...');
      return;
    }
    setError('');
    setLoading(true);
    try {
      const res = await verifyApi.readOnChain(objectId);
      if (res.ok) {
        setResult(res.data);
        onData(res.data);
      } else {
        setError((res.data as any).message || 'Failed to read on-chain data');
      }
    } catch {
      setError('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <h3 className="text-sm font-semibold mb-4 text-foreground">Read On-Chain Data</h3>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-2">
          <Label>Object ID</Label>
          <Input value={objectId} onChange={(e) => { setObjectId(e.target.value); setError(''); }} placeholder="0x..." />
        </div>
        {error && <InlineNotice type="error" message={error} />}
        <LoadingButton type="submit" loading={loading}>Read On-Chain Data</LoadingButton>
      </form>
      {result && (
        <div className="mt-4 space-y-3">
          <CopyableField value={result.object_id} label="Object ID" />
          <div>
            <span className="text-xs text-tg-text-muted">State Data (Hash)</span>
            <div className="mt-1"><HashDisplay hash={result.state_data} /></div>
          </div>
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <span className="text-xs text-tg-text-muted">Description</span>
              <p className="mt-1 text-tg-text-secondary">{result.description}</p>
            </div>
            <div>
              <span className="text-xs text-tg-text-muted">Immutable</span>
              <p className="mt-1 text-tg-text-secondary">{result.immutable ? 'Yes' : 'No'}</p>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function HashCompareCard({ onChainHash, onComputed }: { onChainHash: string | null; onComputed: (hash: string) => void }) {
  const [document, setDocument] = useState('');
  const [loading, setLoading] = useState(false);
  const [fileName, setFileName] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setFileName(file.name);
    const reader = new FileReader();
    reader.onload = (ev) => setDocument(ev.target?.result as string || '');
    reader.readAsText(file);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!document.trim()) return;
    setLoading(true);
    try {
      const res = await verifyApi.computeHash(document);
      if (res.ok) onComputed(res.data.hash);
      else toast.error('Hash computation failed');
    } catch {
      toast.error('Connection failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5 shadow-tg-sm">
      <h3 className="text-sm font-semibold mb-4 text-foreground">Compute & Compare Hash</h3>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-2">
          <Label>Session Document JSON</Label>
          <Textarea value={document} onChange={(e) => setDocument(e.target.value)} rows={6} placeholder="Paste session JSON or upload a file..." />
        </div>
        <div className="space-y-2">
          <Label>Or upload file</Label>
          <input ref={fileRef} type="file" accept=".json" onChange={handleFileUpload} className="hidden" />
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
        <LoadingButton type="submit" loading={loading}>Compute & Compare Hash</LoadingButton>
      </form>
      {!onChainHash && (
        <p className="mt-3 text-xs text-tg-text-muted italic">Read on-chain data first to compare</p>
      )}
    </div>
  );
}

function MatchResult({ onChainHash, computedHash }: { onChainHash: string; computedHash: string }) {
  const match = onChainHash === computedHash;

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
