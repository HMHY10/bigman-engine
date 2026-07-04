'use client';

import { useState, useEffect, useCallback, useTransition } from 'react';
import { getPicklistStatus, printNextBatch, printSelectedOrders } from '../actions.js';

// ── Icons ──────────────────────────────────────────────────────────────

function PackageIcon({ size = 16 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M16.5 9.4 7.55 4.24"/>
      <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
      <polyline points="3.29 7 12 12 20.71 7"/>
      <line x1="12" x2="12" y1="22" y2="12"/>
    </svg>
  );
}

function PrinterIcon({ size = 16 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="6 9 6 2 18 2 18 9"/>
      <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/>
      <rect width="12" height="8" x="6" y="14"/>
    </svg>
  );
}

function RefreshIcon({ size = 16 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>
      <path d="M21 3v5h-5"/>
      <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>
      <path d="M8 16H3v5"/>
    </svg>
  );
}

function ClockIcon({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="10"/>
      <polyline points="12 6 12 12 16 14"/>
    </svg>
  );
}

// ── Helpers ────────────────────────────────────────────────────────────

function formatTime(epoch) {
  if (!epoch) return '—';
  const d = new Date(epoch * 1000);
  return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
}

function formatPlatform(p) {
  if (!p || p === 'unknown') return '—';
  return p.charAt(0).toUpperCase() + p.slice(1).replace(/_/g, ' ');
}

function elapsedMinutes(epoch) {
  return Math.floor((Date.now() / 1000 - epoch) / 60);
}

// ── Timer Banner ───────────────────────────────────────────────────────

function TimerBanner({ timer, batchSize }) {
  if (!timer) return null;
  const elapsed = elapsedMinutes(timer.started_at);
  const remaining = Math.max(0, 60 - elapsed);
  const pct = Math.min(100, (elapsed / 60) * 100);

  return (
    <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-4 mb-4">
      <div className="flex items-center gap-2 mb-2">
        <ClockIcon size={14} />
        <span className="text-sm font-medium text-yellow-500">Auto-batch timer running</span>
      </div>
      <div className="text-xs text-muted-foreground mb-2">
        {timer.order_count} order{timer.order_count !== 1 ? 's' : ''} waiting — will auto-print in{' '}
        <strong className="text-foreground">{remaining} min</strong> if {batchSize} not reached
      </div>
      <div className="h-1.5 rounded-full bg-border overflow-hidden">
        <div
          className="h-full rounded-full bg-yellow-500 transition-all"
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}

// ── Queue Status Card ──────────────────────────────────────────────────

function QueueCard({ readyCount, printedCount, batchSize }) {
  const fillPct = Math.min(100, (readyCount / batchSize) * 100);
  return (
    <div className="rounded-lg border bg-card p-4 mb-4">
      <div className="flex items-center justify-between mb-3">
        <div>
          <p className="text-base font-medium">{readyCount} orders ready to pick</p>
          <p className="text-xs text-muted-foreground mt-0.5">{printedCount} already printed today</p>
        </div>
        <div className="text-right">
          <p className="text-xs text-muted-foreground">Batch threshold</p>
          <p className="text-sm font-medium">{readyCount} / {batchSize}</p>
        </div>
      </div>
      <div className="h-2 rounded-full bg-border overflow-hidden">
        <div
          className="h-full rounded-full bg-green-500 transition-all"
          style={{ width: `${fillPct}%` }}
        />
      </div>
    </div>
  );
}

// ── Order Row ──────────────────────────────────────────────────────────

function OrderRow({ order, selected, onToggle }) {
  return (
    <label className="flex items-center gap-3 p-3 rounded-md hover:bg-accent/50 cursor-pointer">
      <input
        type="checkbox"
        checked={selected}
        onChange={() => onToggle(order.order_id)}
        className="shrink-0"
      />
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="font-mono text-sm font-medium">#{order.order_id}</span>
          <span className="text-[10px] bg-muted text-muted-foreground px-1.5 py-0.5 rounded">
            {formatPlatform(order.platform)}
          </span>
        </div>
        <p className="text-xs text-muted-foreground truncate mt-0.5">{order.customer}</p>
      </div>
      <div className="text-right shrink-0">
        <p className="text-xs text-muted-foreground">{formatTime(order.date_add)}</p>
        <p className="text-xs text-muted-foreground">{order.product_count} SKU{order.product_count !== 1 ? 's' : ''}</p>
      </div>
    </label>
  );
}

// ── Recent Batches ─────────────────────────────────────────────────────

function RecentBatches({ batches }) {
  if (!batches.length) return null;

  return (
    <div className="mt-6">
      <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-2">Recent picklists</p>
      <div className="flex flex-col gap-1">
        {batches.map((id) => (
          <a
            key={id}
            href={`/picklist/print/${id}`}
            target="_blank"
            rel="noreferrer"
            className="flex items-center gap-2 text-xs text-muted-foreground hover:text-foreground px-2 py-1.5 rounded hover:bg-accent/50 transition-colors"
          >
            <PrinterIcon size={12} />
            <span className="font-mono">{id}</span>
          </a>
        ))}
      </div>
    </div>
  );
}

// ── Main Page ──────────────────────────────────────────────────────────

export function PicklistPage() {
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [selectedIds, setSelectedIds] = useState(new Set());
  const [isPrinting, startPrint] = useTransition();
  const [feedback, setFeedback] = useState(null);

  const load = useCallback(async () => {
    try {
      const data = await getPicklistStatus();
      setStatus(data);
    } catch (e) {
      console.error('Failed to load picklist status', e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    const interval = setInterval(load, 60_000); // refresh every minute
    return () => clearInterval(interval);
  }, [load]);

  function toggleOrder(orderId) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(orderId)) next.delete(orderId);
      else next.add(orderId);
      return next;
    });
  }

  function toggleAll() {
    if (!status) return;
    const allIds = status.orders.map((o) => o.order_id);
    if (selectedIds.size === allIds.length) {
      setSelectedIds(new Set());
    } else {
      setSelectedIds(new Set(allIds));
    }
  }

  function openPrint(batchId) {
    window.open(`/picklist/print/${batchId}?autoprint=1`, '_blank');
    setFeedback({ ok: true, msg: 'Picklist opened in new tab' });
    setTimeout(() => setFeedback(null), 4000);
    load();
  }

  function handlePrintNext() {
    startPrint(async () => {
      setFeedback(null);
      const result = await printNextBatch(status?.batch_size);
      if (result.error) {
        setFeedback({ ok: false, msg: result.error });
      } else {
        openPrint(result.batch_id);
      }
    });
  }

  function handlePrintSelected() {
    if (selectedIds.size === 0) return;
    startPrint(async () => {
      setFeedback(null);
      const result = await printSelectedOrders([...selectedIds]);
      if (result.error) {
        setFeedback({ ok: false, msg: result.error });
      } else {
        openPrint(result.batch_id);
      }
    });
  }

  const allSelected = status && selectedIds.size === status.orders.length && status.orders.length > 0;
  const busy = isPrinting;

  return (
    <>
      <div className="flex items-center justify-between mb-4">
        <div />
        <button
          onClick={load}
          className="flex items-center gap-1.5 px-2.5 py-1.5 text-xs border border-border text-muted-foreground hover:text-foreground hover:bg-accent rounded-md transition-colors"
          disabled={loading}
        >
          <RefreshIcon size={12} />
          Refresh
        </button>
      </div>

      {loading ? (
        <div className="space-y-3">
          <div className="h-24 animate-pulse rounded-lg bg-border/50" />
          <div className="h-16 animate-pulse rounded-lg bg-border/50" />
        </div>
      ) : !status ? (
        <p className="text-sm text-muted-foreground">Failed to load picklist status.</p>
      ) : (
        <>
          <TimerBanner timer={status.timer} batchSize={status.batch_size} />
          <QueueCard
            readyCount={status.ready_count}
            printedCount={status.printed_count}
            batchSize={status.batch_size}
          />

          {/* Action buttons */}
          <div className="flex gap-2 mb-4 flex-wrap">
            <button
              onClick={handlePrintNext}
              disabled={busy || status.ready_count === 0}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm bg-foreground text-background rounded-md hover:bg-foreground/90 disabled:opacity-50 transition-colors"
            >
              <PrinterIcon size={14} />
              {busy ? 'Generating…' : `Print next ${status.batch_size}`}
            </button>
            <button
              onClick={handlePrintSelected}
              disabled={busy || selectedIds.size === 0}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 rounded-md transition-colors"
            >
              <PrinterIcon size={14} />
              {busy ? 'Generating…' : `Print selected (${selectedIds.size})`}
            </button>
          </div>

          {/* Feedback */}
          {feedback && (
            <div
              className={`rounded-md px-3 py-2 text-xs mb-4 ${
                feedback.ok
                  ? 'bg-green-500/10 text-green-500 border border-green-500/30'
                  : 'bg-destructive/10 text-destructive border border-destructive/30'
              }`}
            >
              {feedback.msg}
            </div>
          )}

          {/* Order list */}
          {status.orders.length > 0 ? (
            <div className="rounded-lg border bg-card">
              <div className="flex items-center justify-between px-3 py-2 border-b">
                <label className="flex items-center gap-2 text-xs text-muted-foreground cursor-pointer">
                  <input
                    type="checkbox"
                    checked={allSelected}
                    onChange={toggleAll}
                  />
                  {allSelected ? 'Deselect all' : `Select all (${status.orders.length})`}
                </label>
              </div>
              <div className="divide-y">
                {status.orders.map((order) => (
                  <OrderRow
                    key={order.order_id}
                    order={order}
                    selected={selectedIds.has(order.order_id)}
                    onToggle={toggleOrder}
                  />
                ))}
              </div>
            </div>
          ) : (
            <div className="rounded-lg border border-dashed p-8 text-center">
              <div className="flex justify-center mb-3">
                <PackageIcon size={24} />
              </div>
              <p className="text-sm font-medium mb-1">No orders ready to pick</p>
              <p className="text-xs text-muted-foreground">Orders will appear here when they reach &quot;ready to pick&quot; status in BaseLinker.</p>
            </div>
          )}

          <RecentBatches batches={status.recent_batches} />
        </>
      )}
    </>
  );
}
