'use client';

import { useState, useEffect, use } from 'react';
import { getBatchManifest, createShippingLabels } from '../../actions.js';

function ExternalLinkIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>
      <polyline points="15 3 21 3 21 9"/>
      <line x1="10" y1="14" x2="21" y2="3"/>
    </svg>
  );
}

function PrintIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="6 9 6 2 18 2 18 9"/>
      <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/>
      <rect x="6" y="14" width="12" height="8"/>
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="20 6 9 17 4 12"/>
    </svg>
  );
}

export default function BatchPage({ params }) {
  const { batchId } = use(params);
  const [manifest, setManifest] = useState(null);
  const [loading, setLoading] = useState(true);
  const [labelling, setLabelling] = useState(false);
  const [results, setResults] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    getBatchManifest(batchId)
      .then((m) => setManifest(m))
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false));
  }, [batchId]);

  const handleCreateLabels = async () => {
    setLabelling(true);
    setError('');
    try {
      const { results } = await createShippingLabels(batchId);
      setResults(results);
    } catch (err) {
      setError(err.message);
    } finally {
      setLabelling(false);
    }
  };

  const successCount = results ? results.filter((r) => r.label_url).length : 0;
  const failCount = results ? results.filter((r) => r.error).length : 0;

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="max-w-2xl mx-auto px-4 py-8">

        {/* Header */}
        <div className="mb-6">
          <div className="text-xs font-mono text-muted-foreground mb-1">Pack Station</div>
          <h1 className="text-2xl font-bold">Shipping Labels</h1>
          {manifest && (
            <p className="text-sm text-muted-foreground mt-1">
              Batch <span className="font-mono text-foreground">{batchId}</span> &bull;{' '}
              {manifest.order_count} order{manifest.order_count !== 1 ? 's' : ''} &bull;{' '}
              {manifest.mode}
            </p>
          )}
        </div>

        {/* Error */}
        {error && (
          <div className="mb-4 px-4 py-3 rounded-lg border border-destructive/30 bg-destructive/5 text-destructive text-sm">
            {error}
          </div>
        )}

        {loading ? (
          <div className="space-y-3">
            <div className="h-24 animate-pulse rounded-lg bg-border/50" />
            <div className="h-16 animate-pulse rounded-lg bg-border/50" />
          </div>
        ) : !manifest ? (
          <div className="text-center py-16">
            <p className="text-sm font-medium mb-1">Batch not found</p>
            <p className="text-xs text-muted-foreground">Batch <span className="font-mono">{batchId}</span> does not exist or has expired.</p>
          </div>
        ) : (
          <>
            {/* Batch info */}
            <div className="rounded-lg border border-border p-4 mb-5">
              <div className="grid grid-cols-2 gap-3 text-sm">
                <div>
                  <div className="text-xs text-muted-foreground mb-0.5">Batch ID</div>
                  <div className="font-mono text-xs">{manifest.batch_id}</div>
                </div>
                <div>
                  <div className="text-xs text-muted-foreground mb-0.5">Mode</div>
                  <div className="capitalize">{manifest.mode.replace(/-/g, ' ')}</div>
                </div>
                <div>
                  <div className="text-xs text-muted-foreground mb-0.5">Created</div>
                  <div>{new Date(manifest.created_at).toLocaleString('en-GB')}</div>
                </div>
                <div>
                  <div className="text-xs text-muted-foreground mb-0.5">Orders</div>
                  <div className="font-bold">{manifest.order_count}</div>
                </div>
              </div>
            </div>

            {/* Orders list */}
            <div className="mb-5">
              <p className="text-xs text-muted-foreground mb-2 uppercase tracking-wide font-medium">Order Numbers</p>
              <div className="flex flex-wrap gap-1.5">
                {manifest.order_ids.map((id) => (
                  <span key={id} className={`font-mono text-xs px-2 py-1 rounded border ${
                    results
                      ? results.find((r) => String(r.order_id) === String(id))?.label_url
                        ? 'border-green-500/30 bg-green-500/5 text-green-500'
                        : results.find((r) => String(r.order_id) === String(id))?.error
                          ? 'border-destructive/30 bg-destructive/5 text-destructive'
                          : 'border-border bg-muted text-muted-foreground'
                      : 'border-border bg-muted text-muted-foreground'
                  }`}>
                    #{id}
                  </span>
                ))}
              </div>
            </div>

            {/* Label results */}
            {results && (
              <div className="mb-5 space-y-2">
                <div className="flex gap-3 text-sm mb-3">
                  {successCount > 0 && (
                    <span className="inline-flex items-center gap-1 text-green-500">
                      <CheckIcon /> {successCount} label{successCount !== 1 ? 's' : ''} ready
                    </span>
                  )}
                  {failCount > 0 && (
                    <span className="text-destructive">{failCount} failed</span>
                  )}
                </div>

                {results.map((r) => (
                  <div key={r.order_id} className="flex items-center justify-between p-3 rounded-lg border border-border text-sm">
                    <span className="font-mono text-xs">#{r.order_id}</span>
                    {r.label_url ? (
                      <a
                        href={r.label_url}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1 text-xs text-green-500 hover:underline"
                      >
                        Open label <ExternalLinkIcon />
                      </a>
                    ) : (
                      <span className="text-xs text-destructive">{r.error || 'Failed'}</span>
                    )}
                  </div>
                ))}
              </div>
            )}

            {/* Action buttons */}
            <div className="flex flex-wrap gap-2">
              {!results && (
                <button
                  onClick={handleCreateLabels}
                  disabled={labelling}
                  className="inline-flex items-center gap-2 px-4 py-2 text-sm bg-foreground text-background rounded-md hover:bg-foreground/90 disabled:opacity-50 transition-colors"
                >
                  <PrintIcon />
                  {labelling ? 'Creating labels…' : `Create ${manifest.order_count} shipping labels`}
                </button>
              )}

              {results && failCount > 0 && (
                <button
                  onClick={handleCreateLabels}
                  disabled={labelling}
                  className="inline-flex items-center gap-2 px-3 py-1.5 text-sm border border-border rounded-md hover:bg-accent transition-colors disabled:opacity-50"
                >
                  Retry failed
                </button>
              )}

              <a
                href={`/picklist/print/${batchId}`}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-2 px-3 py-1.5 text-sm border border-border rounded-md hover:bg-accent transition-colors"
              >
                <PrintIcon />
                View pick list
              </a>

              <a
                href="/picklist"
                className="inline-flex items-center gap-2 px-3 py-1.5 text-sm border border-border text-muted-foreground rounded-md hover:bg-accent hover:text-foreground transition-colors"
              >
                Back to orders
              </a>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
