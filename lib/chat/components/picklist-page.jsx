'use client';

import { useState, useEffect, useCallback } from 'react';
import { PageLayout } from './page-layout.js';
import { SpinnerIcon, CheckIcon, ClipboardListIcon, PrinterIcon, RefreshIcon } from './icons.js';
import {
  getPendingOrdersForPicklist,
  getPicklistsList,
  printNextBatch,
  printSelectedOrders,
  markPrinted,
  getPicklistSettings,
  savePicklistSettings,
} from '../../picklist/actions.js';

// ─────────────────────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────────────────────

function formatTs(ts) {
  if (!ts) return '—';
  return new Date(ts).toLocaleString('en-GB', { dateStyle: 'short', timeStyle: 'short' });
}

function timeAgo(ts) {
  if (!ts) return '';
  const mins = Math.floor((Date.now() - ts) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

const STATUS_STYLES = {
  pending:     'bg-yellow-500/10 text-yellow-500',
  in_picklist: 'bg-blue-500/10 text-blue-500',
  picked:      'bg-green-500/10 text-green-500',
  shipped:     'bg-muted text-muted-foreground',
};

const PICKLIST_STATUS_STYLES = {
  pending:   'bg-yellow-500/10 text-yellow-500',
  printed:   'bg-blue-500/10 text-blue-500',
  completed: 'bg-green-500/10 text-green-500',
};

const TYPE_STYLES = {
  overnight: 'bg-purple-500/10 text-purple-500',
  batch:     'bg-blue-500/10 text-blue-500',
  manual:    'bg-muted text-muted-foreground',
};

// ─────────────────────────────────────────────────────────────────────────────
// Skeleton loading
// ─────────────────────────────────────────────────────────────────────────────

function Skeleton({ className }) {
  return <div className={`bg-border/50 rounded-md animate-pulse ${className}`} />;
}

// ─────────────────────────────────────────────────────────────────────────────
// Order row with checkbox
// ─────────────────────────────────────────────────────────────────────────────

function OrderRow({ order, selected, onToggle }) {
  const skuSummary = (order.items || [])
    .map(i => `${i.sku} ×${i.quantity}`)
    .join(', ');

  return (
    <div
      className={`flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors ${
        selected ? 'border-foreground bg-muted/50' : 'border-border hover:bg-muted/30'
      }`}
      onClick={() => onToggle(order.id)}
    >
      <div className="mt-0.5 shrink-0">
        <div className={`w-4 h-4 rounded border-2 flex items-center justify-center transition-colors ${
          selected ? 'border-foreground bg-foreground' : 'border-border'
        }`}>
          {selected && <CheckIcon size={10} className="text-background" />}
        </div>
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-mono text-sm font-medium">{order.externalRef || order.externalId}</span>
          {order.source && (
            <span className="text-[10px] px-1.5 py-0.5 rounded bg-muted text-muted-foreground uppercase">
              {order.source}
            </span>
          )}
          <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${STATUS_STYLES[order.status] || ''}`}>
            {order.status}
          </span>
        </div>
        {order.customerName && (
          <p className="text-xs text-muted-foreground mt-0.5">{order.customerName}</p>
        )}
        {skuSummary && (
          <p className="text-xs text-muted-foreground font-mono mt-0.5 truncate">{skuSummary}</p>
        )}
      </div>
      <div className="text-xs text-muted-foreground shrink-0 text-right">
        <div>{timeAgo(order.createdAt)}</div>
        {(order.items || []).length > 0 && (
          <div className="mt-0.5">{(order.items || []).length} item{(order.items || []).length !== 1 ? 's' : ''}</div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Picklist row
// ─────────────────────────────────────────────────────────────────────────────

function PicklistRow({ picklist }) {
  const printUrl = `/print/picklist/${picklist.id}`;

  return (
    <div className="flex items-center gap-3 p-3 rounded-lg border border-border">
      <div className="shrink-0 rounded-md bg-muted p-2">
        <ClipboardListIcon size={14} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-mono text-sm font-medium">{picklist.id.slice(0, 8).toUpperCase()}</span>
          <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${TYPE_STYLES[picklist.type] || ''}`}>
            {picklist.type}
          </span>
          <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${PICKLIST_STATUS_STYLES[picklist.status] || ''}`}>
            {picklist.status}
          </span>
        </div>
        <p className="text-xs text-muted-foreground mt-0.5">
          {picklist.orderCount} orders &bull; Created {formatTs(picklist.createdAt)}
          {picklist.printedAt && ` &bull; Printed ${formatTs(picklist.printedAt)}`}
        </p>
      </div>
      <div className="flex items-center gap-1.5 shrink-0">
        <a
          href={printUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
        >
          <PrinterIcon size={12} />
          Print
        </a>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings panel
// ─────────────────────────────────────────────────────────────────────────────

function SettingsPanel({ onClose }) {
  const [settings, setSettings] = useState({ shippingLabelWebhookUrl: '', batchSize: 25, maxWaitMinutes: 15 });
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    getPicklistSettings().then(s => { setSettings(s); setLoading(false); }).catch(() => setLoading(false));
  }, []);

  const handleSave = async () => {
    setSaving(true);
    await savePicklistSettings(settings);
    setSaving(false);
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };

  return (
    <div className="rounded-lg border border-border bg-card p-4 mb-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-medium">Picklist Settings</h3>
        <button onClick={onClose} className="text-xs text-muted-foreground hover:text-foreground transition-colors">Close</button>
      </div>

      {loading ? (
        <div className="space-y-3"><Skeleton className="h-8" /><Skeleton className="h-8" /></div>
      ) : (
        <div className="space-y-3">
          <div>
            <label className="text-xs font-medium text-muted-foreground block mb-1">Batch size (orders per picklist)</label>
            <input
              type="number"
              min={1} max={200}
              value={settings.batchSize}
              onChange={e => setSettings(s => ({ ...s, batchSize: parseInt(e.target.value) || 25 }))}
              className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
            />
          </div>
          <div>
            <label className="text-xs font-medium text-muted-foreground block mb-1">Time-limit fallback (minutes)</label>
            <input
              type="number"
              min={1} max={120}
              value={settings.maxWaitMinutes}
              onChange={e => setSettings(s => ({ ...s, maxWaitMinutes: parseInt(e.target.value) || 15 }))}
              className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
            />
            <p className="text-[10px] text-muted-foreground mt-1">Auto-batch pending orders after this many minutes even if under batch size.</p>
          </div>
          <div>
            <label className="text-xs font-medium text-muted-foreground block mb-1">Shipping label webhook URL</label>
            <input
              type="url"
              value={settings.shippingLabelWebhookUrl}
              onChange={e => setSettings(s => ({ ...s, shippingLabelWebhookUrl: e.target.value }))}
              placeholder="https://your-shipping-system/print-label"
              className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
            />
            <p className="text-[10px] text-muted-foreground mt-1">Called with order IDs when a picker scans the picklist QR on return.</p>
          </div>
          <div className="flex justify-end">
            <button
              onClick={handleSave}
              disabled={saving}
              className={`rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
                saved
                  ? 'border border-green-500 text-green-500'
                  : 'bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50'
              }`}
            >
              {saved ? <span className="inline-flex items-center gap-1"><CheckIcon size={12} /> Saved</span> : saving ? 'Saving...' : 'Save settings'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main page
// ─────────────────────────────────────────────────────────────────────────────

export function PicklistPage({ session }) {
  const [tab, setTab] = useState('orders');
  const [pendingOrders, setPendingOrders] = useState([]);
  const [picklists, setPicklists] = useState([]);
  const [selected, setSelected] = useState(new Set());
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [feedback, setFeedback] = useState(null);
  const [showSettings, setShowSettings] = useState(false);

  const showFeedback = (msg, type = 'success') => {
    setFeedback({ msg, type });
    setTimeout(() => setFeedback(null), 3500);
  };

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const [orders, lists] = await Promise.all([
        getPendingOrdersForPicklist(),
        getPicklistsList(20),
      ]);
      setPendingOrders(orders);
      setPicklists(lists);
      setSelected(new Set()); // clear selection on refresh
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { loadData(); }, [loadData]);

  const toggleOrder = (id) => {
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const toggleAll = () => {
    if (selected.size === pendingOrders.length) {
      setSelected(new Set());
    } else {
      setSelected(new Set(pendingOrders.map(o => o.id)));
    }
  };

  const handlePrintNext25 = async () => {
    setActionLoading(true);
    const result = await printNextBatch(25);
    setActionLoading(false);
    if (result?.error) {
      showFeedback(result.error, 'error');
    } else {
      showFeedback(`Picklist ${result.picklist.id.slice(0, 8).toUpperCase()} created`);
      window.open(`/print/picklist/${result.picklist.id}`, '_blank');
      loadData();
    }
  };

  const handlePrintSelected = async () => {
    if (!selected.size) return;
    setActionLoading(true);
    const result = await printSelectedOrders([...selected]);
    setActionLoading(false);
    if (result?.error) {
      showFeedback(result.error, 'error');
    } else {
      showFeedback(`Picklist ${result.picklist.id.slice(0, 8).toUpperCase()} created`);
      window.open(`/print/picklist/${result.picklist.id}`, '_blank');
      loadData();
    }
  };

  return (
    <PageLayout session={session}>
      <div className="mb-6">
        <h1 className="text-2xl font-semibold">Picklists</h1>
        <p className="text-sm text-muted-foreground mt-1">Pick, batch, and ship warehouse orders</p>
      </div>

      {/* Feedback banner */}
      {feedback && (
        <div className={`mb-4 rounded-lg border px-4 py-3 text-sm ${
          feedback.type === 'error'
            ? 'border-destructive/30 bg-destructive/5 text-destructive'
            : 'border-green-500/30 bg-green-500/5 text-green-500'
        }`}>
          {feedback.msg}
        </div>
      )}

      {/* Settings panel */}
      {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}

      {/* Header + action buttons */}
      <div className="flex items-center justify-between mb-4 flex-wrap gap-2">
        <div className="flex items-center gap-2">
          <span className="text-sm text-muted-foreground">
            {loading ? '—' : `${pendingOrders.length} pending`}
          </span>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          <button
            onClick={loadData}
            disabled={loading}
            className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors disabled:opacity-50"
          >
            <RefreshIcon size={12} className={loading ? 'animate-spin' : ''} />
            Refresh
          </button>
          <button
            onClick={() => setShowSettings(s => !s)}
            className="rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
          >
            Settings
          </button>
          <button
            onClick={handlePrintSelected}
            disabled={actionLoading || selected.size === 0}
            className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors disabled:opacity-50"
          >
            <PrinterIcon size={12} />
            Print selected {selected.size > 0 ? `(${selected.size})` : ''}
          </button>
          <button
            onClick={handlePrintNext25}
            disabled={actionLoading || pendingOrders.length === 0}
            className="inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium bg-foreground text-background hover:bg-foreground/90 transition-colors disabled:opacity-50"
          >
            {actionLoading ? <SpinnerIcon size={14} className="animate-spin" /> : <PrinterIcon size={14} />}
            Print next 25
          </button>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 mb-4 border-b border-border">
        {[['orders', 'Pending Orders'], ['history', 'Picklist History']].map(([key, label]) => (
          <button
            key={key}
            onClick={() => setTab(key)}
            className={`px-3 py-1.5 text-sm font-medium border-b-2 -mb-px transition-colors ${
              tab === key
                ? 'border-foreground text-foreground'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            {label}
            {key === 'orders' && !loading && pendingOrders.length > 0 && (
              <span className="ml-1.5 inline-flex items-center justify-center rounded-full bg-foreground text-background text-[10px] font-medium px-1.5 py-0.5 leading-none">
                {pendingOrders.length}
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Orders tab */}
      {tab === 'orders' && (
        <>
          {loading ? (
            <div className="space-y-2">
              {[...Array(5)].map((_, i) => <Skeleton key={i} className="h-16" />)}
            </div>
          ) : pendingOrders.length === 0 ? (
            <div className="rounded-lg border border-dashed bg-card p-8 flex flex-col items-center text-center">
              <ClipboardListIcon size={24} className="text-muted-foreground mb-3" />
              <p className="text-sm font-medium mb-1">No pending orders</p>
              <p className="text-xs text-muted-foreground">Orders will appear here when received from your sales channels.</p>
            </div>
          ) : (
            <>
              {/* Select all */}
              <div className="flex items-center gap-2 mb-2 px-1">
                <button
                  onClick={toggleAll}
                  className="text-xs text-muted-foreground hover:text-foreground transition-colors"
                >
                  {selected.size === pendingOrders.length ? 'Deselect all' : `Select all (${pendingOrders.length})`}
                </button>
              </div>
              <div className="space-y-2">
                {pendingOrders.map(order => (
                  <OrderRow
                    key={order.id}
                    order={order}
                    selected={selected.has(order.id)}
                    onToggle={toggleOrder}
                  />
                ))}
              </div>
            </>
          )}
        </>
      )}

      {/* History tab */}
      {tab === 'history' && (
        <>
          {loading ? (
            <div className="space-y-2">
              {[...Array(4)].map((_, i) => <Skeleton key={i} className="h-16" />)}
            </div>
          ) : picklists.length === 0 ? (
            <div className="rounded-lg border border-dashed bg-card p-8 flex flex-col items-center text-center">
              <ClipboardListIcon size={24} className="text-muted-foreground mb-3" />
              <p className="text-sm font-medium mb-1">No picklists yet</p>
              <p className="text-xs text-muted-foreground">Picklists appear here after being created.</p>
            </div>
          ) : (
            <div className="space-y-2">
              {picklists.map(pl => (
                <PicklistRow key={pl.id} picklist={pl} />
              ))}
            </div>
          )}
        </>
      )}
    </PageLayout>
  );
}
