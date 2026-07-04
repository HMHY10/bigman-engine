'use client';

import { useState, useEffect, useTransition } from 'react';
import { getReadyOrders, printNext, printSelected } from './actions.js';

// ── Icons (inline SVG, no external dep) ──────────────────────────────────────
function PrintIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="6 9 6 2 18 2 18 9"/>
      <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/>
      <rect x="6" y="14" width="12" height="8"/>
    </svg>
  );
}

function RefreshIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="23 4 23 10 17 10"/>
      <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>
    </svg>
  );
}

function CheckboxIcon({ checked }) {
  return (
    <div className={`w-4 h-4 rounded border flex items-center justify-center shrink-0 transition-colors ${
      checked ? 'bg-foreground border-foreground' : 'border-border'
    }`}>
      {checked && (
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="white" strokeWidth="2">
          <polyline points="1.5,5 4,7.5 8.5,2.5"/>
        </svg>
      )}
    </div>
  );
}

// ── Status badge ──────────────────────────────────────────────────────────────
function BatchTimerBadge({ state, batchSize }) {
  if (!state) return null;
  const { batch_start_epoch, last_batch_epoch, last_batch_id } = state;

  const parts = [];

  if (batch_start_epoch && batch_start_epoch !== 'null') {
    const startMs = Number(batch_start_epoch) * 1000;
    const elapsed = Math.floor((Date.now() - startMs) / 60000);
    const timeLimit = 60;
    const remaining = timeLimit - elapsed;
    parts.push(
      <span key="timer" className="inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] bg-yellow-500/10 text-yellow-500">
        <span className="w-1.5 h-1.5 rounded-full bg-yellow-500 animate-pulse" />
        Batch accumulating — {elapsed}m elapsed, prints in {remaining > 0 ? `${remaining}m` : 'soon'}
      </span>
    );
  }

  if (last_batch_id) {
    const lastMs = Number(last_batch_epoch) * 1000;
    const mins = Math.floor((Date.now() - lastMs) / 60000);
    const timeLabel = mins < 60 ? `${mins}m ago` : `${Math.floor(mins / 60)}h ago`;
    parts.push(
      <span key="last" className="text-[11px] text-muted-foreground">
        Last batch: <span className="font-mono text-foreground">{last_batch_id}</span> ({timeLabel})
      </span>
    );
  }

  if (parts.length === 0) return null;

  return (
    <div className="flex flex-wrap items-center gap-3 px-4 py-2.5 bg-muted/50 rounded-lg border border-border text-sm">
      {parts}
    </div>
  );
}

// ── Order row ─────────────────────────────────────────────────────────────────
function OrderRow({ order, selected, onToggle }) {
  const itemCount = (order.products || []).reduce((s, p) => s + (Number(p.quantity) || 1), 0);
  const customer = order.delivery_fullname || order.buyer_login || 'Unknown';
  const skus = [...new Set((order.products || []).map((p) => p.sku || p.storage_id || 'N/A'))];

  return (
    <div
      className={`flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
        selected ? 'border-foreground/30 bg-foreground/5' : 'border-border bg-card hover:bg-accent/40'
      }`}
      onClick={() => onToggle(order.order_id)}
    >
      <div className="pt-0.5">
        <CheckboxIcon checked={selected} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium font-mono">#{order.order_id}</span>
          <span className="text-xs text-muted-foreground">{customer}</span>
        </div>
        <div className="flex flex-wrap gap-1 mt-1">
          {skus.slice(0, 4).map((sku) => (
            <span key={sku} className="font-mono text-[10px] bg-muted text-muted-foreground px-1.5 py-0.5 rounded">
              {sku}
            </span>
          ))}
          {skus.length > 4 && (
            <span className="text-[10px] text-muted-foreground">+{skus.length - 4} more</span>
          )}
        </div>
      </div>
      <span className="text-xs text-muted-foreground shrink-0 pt-0.5">{itemCount} item{itemCount !== 1 ? 's' : ''}</span>
    </div>
  );
}

// ── SKU summary table ─────────────────────────────────────────────────────────
function SkuSummary({ orders }) {
  const skuMap = new Map();
  for (const order of orders) {
    for (const p of order.products || []) {
      const sku = p.sku || p.storage_id || 'N/A';
      const qty = Number(p.quantity) || 1;
      skuMap.set(sku, (skuMap.get(sku) || 0) + qty);
    }
  }
  const rows = [...skuMap.entries()].sort(([a], [b]) => a.localeCompare(b));
  if (rows.length === 0) return null;

  return (
    <div className="rounded-lg border border-border overflow-hidden">
      <table className="w-full text-xs">
        <thead>
          <tr className="bg-muted">
            <th className="text-left px-3 py-2 font-medium text-muted-foreground">SKU</th>
            <th className="text-right px-3 py-2 font-medium text-muted-foreground">Total Qty</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(([sku, qty], i) => (
            <tr key={sku} className={i % 2 === 0 ? '' : 'bg-muted/30'}>
              <td className="px-3 py-1.5 font-mono">{sku}</td>
              <td className="px-3 py-1.5 text-right font-bold">{qty}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────────
export default function PicklistPage() {
  const [orders, setOrders] = useState([]);
  const [state, setState] = useState(null);
  const [batchSize, setBatchSize] = useState(25);
  const [selected, setSelected] = useState(new Set());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [activeTab, setActiveTab] = useState('orders'); // 'orders' | 'sku'
  const [isPrinting, startPrint] = useTransition();

  const load = () => {
    setLoading(true);
    setError('');
    getReadyOrders()
      .then(({ orders, state, batchSize }) => {
        setOrders(orders);
        setState(state);
        setBatchSize(batchSize);
        // Auto-select all by default
        setSelected(new Set(orders.map((o) => o.order_id)));
      })
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false));
  };

  useEffect(() => { load(); }, []);

  const toggleOrder = (id) => {
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  const toggleAll = () => {
    if (selected.size === orders.length) {
      setSelected(new Set());
    } else {
      setSelected(new Set(orders.map((o) => o.order_id)));
    }
  };

  const openPrint = (batchId) => {
    window.open(`/picklist/print/${batchId}`, '_blank');
  };

  const handlePrintNext = () => {
    startPrint(async () => {
      try {
        const { batchId } = await printNext(batchSize);
        openPrint(batchId);
        load();
      } catch (err) {
        setError(err.message);
      }
    });
  };

  const handlePrintSelected = () => {
    if (selected.size === 0) {
      setError('Select at least one order to print.');
      return;
    }
    startPrint(async () => {
      try {
        const { batchId } = await printSelected([...selected]);
        openPrint(batchId);
        load();
      } catch (err) {
        setError(err.message);
      }
    });
  };

  const selectedOrders = orders.filter((o) => selected.has(o.order_id));
  const totalSelectedItems = selectedOrders.reduce(
    (s, o) => s + (o.products || []).reduce((s2, p) => s2 + (Number(p.quantity) || 1), 0),
    0
  );

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-4 py-6">

        {/* Header */}
        <div className="flex items-center justify-between mb-6">
          <div>
            <h1 className="text-2xl font-bold">Picklist</h1>
            <p className="text-sm text-muted-foreground mt-0.5">
              Warehouse pick list generator — ArryBarry fulfilment
            </p>
          </div>
          <button
            onClick={load}
            disabled={loading}
            className="inline-flex items-center gap-1.5 px-2.5 py-1.5 text-xs border border-border rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors disabled:opacity-50"
          >
            <RefreshIcon />
            Refresh
          </button>
        </div>

        {/* Batch state */}
        {state && <div className="mb-4"><BatchTimerBadge state={state} batchSize={batchSize} /></div>}

        {/* Error */}
        {error && (
          <div className="mb-4 px-4 py-3 rounded-lg border border-destructive/30 bg-destructive/5 text-destructive text-sm">
            {error}
          </div>
        )}

        {/* Action buttons */}
        <div className="flex flex-wrap gap-2 mb-5">
          <button
            onClick={handlePrintNext}
            disabled={isPrinting || loading || orders.length === 0}
            className="inline-flex items-center gap-2 px-3 py-1.5 text-sm bg-foreground text-background rounded-md hover:bg-foreground/90 disabled:opacity-50 transition-colors"
          >
            <PrintIcon />
            {isPrinting ? 'Generating…' : `Print next ${batchSize}`}
          </button>

          <button
            onClick={handlePrintSelected}
            disabled={isPrinting || loading || selected.size === 0}
            className="inline-flex items-center gap-2 px-3 py-1.5 text-sm border border-border rounded-md text-foreground hover:bg-accent transition-colors disabled:opacity-50"
          >
            <PrintIcon />
            {isPrinting ? 'Generating…' : `Print selected (${selected.size})`}
          </button>
        </div>

        {/* Selection summary */}
        {selected.size > 0 && !loading && (
          <div className="mb-4 text-xs text-muted-foreground">
            {selected.size} order{selected.size !== 1 ? 's' : ''} selected &nbsp;&bull;&nbsp; {totalSelectedItems} items total
          </div>
        )}

        {/* Tabs */}
        <div className="flex gap-0 border-b border-border mb-4">
          {['orders', 'sku'].map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
                activeTab === tab
                  ? 'border-foreground text-foreground'
                  : 'border-transparent text-muted-foreground hover:text-foreground'
              }`}
            >
              {tab === 'orders' ? `Orders (${orders.length})` : 'SKU Preview'}
            </button>
          ))}
          {orders.length > 0 && !loading && (
            <button
              onClick={toggleAll}
              className="ml-auto text-xs text-muted-foreground hover:text-foreground px-3 py-2 transition-colors"
            >
              {selected.size === orders.length ? 'Deselect all' : 'Select all'}
            </button>
          )}
        </div>

        {/* Content */}
        {loading ? (
          <div className="flex flex-col gap-2">
            {[...Array(5)].map((_, i) => (
              <div key={i} className="h-16 animate-pulse rounded-lg bg-border/50" />
            ))}
          </div>
        ) : orders.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-16 text-center">
            <div className="rounded-full bg-muted p-4 mb-4">
              <PrintIcon />
            </div>
            <p className="text-sm font-medium mb-1">No ready orders</p>
            <p className="text-xs text-muted-foreground max-w-sm">
              No orders are currently in the ready-to-pick status in BaseLinker.
              {!process.env.BL_PICKLIST_STATUS_ID && (
                <span className="block mt-1 text-yellow-500">
                  Set BL_PICKLIST_STATUS_ID in Doppler to filter by status.
                </span>
              )}
            </p>
          </div>
        ) : activeTab === 'orders' ? (
          <div className="flex flex-col gap-2">
            {orders.map((order) => (
              <OrderRow
                key={order.order_id}
                order={order}
                selected={selected.has(order.order_id)}
                onToggle={toggleOrder}
              />
            ))}
          </div>
        ) : (
          <SkuSummary orders={selectedOrders} />
        )}
      </div>
    </div>
  );
}
