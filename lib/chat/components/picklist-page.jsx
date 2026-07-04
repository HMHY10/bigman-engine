'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getOrders,
  getPicklists,
  getPicklist,
  addOrder,
  removeOrder,
  removePicklist,
  markPicklistPrinted,
  markPicklistCompleted,
  runOvernightBatch,
  printNext25,
  printSelectedOrders,
} from '../../picklist/actions.js';
import {
  PlusIcon,
  TrashIcon,
  RefreshIcon,
  SpinnerIcon,
  CheckIcon,
  FileTextIcon,
  ClockIcon,
} from './icons.js';
import { Dialog, EmptyState, formatDate, timeAgo } from './settings-shared.js';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

const STATUS_STYLES = {
  pending:   'bg-yellow-500/10 text-yellow-500',
  batched:   'bg-blue-500/10 text-blue-500',
  picked:    'bg-purple-500/10 text-purple-500',
  shipped:   'bg-green-500/10 text-green-500',
  printed:   'bg-blue-500/10 text-blue-500',
  active:    'bg-purple-500/10 text-purple-500',
  completed: 'bg-green-500/10 text-green-500',
};

const BATCH_LABELS = {
  overnight: 'Overnight',
  realtime:  'Realtime',
  manual:    'Manual',
};

function Badge({ value }) {
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium ${STATUS_STYLES[value] || 'bg-muted text-muted-foreground'}`}>
      {value}
    </span>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Order Dialog
// ─────────────────────────────────────────────────────────────────────────────

function AddOrderDialog({ open, onClose, onAdded }) {
  const [form, setForm] = useState({ orderNumber: '', sku: '', productName: '', quantity: 1, binLocation: '', customerName: '', source: 'manual' });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    const result = await addOrder({ ...form, quantity: Number(form.quantity) || 1 });
    setSaving(false);
    if (result?.error) { setError(result.error); return; }
    setForm({ orderNumber: '', sku: '', productName: '', quantity: 1, binLocation: '', customerName: '', source: 'manual' });
    onAdded();
    onClose();
  };

  return (
    <Dialog open={open} onClose={onClose} title="Add Order">
      <div className="space-y-3">
        {error && <p className="text-xs text-destructive">{error}</p>}
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">Order Number *</label>
          <input
            value={form.orderNumber}
            onChange={(e) => set('orderNumber', e.target.value)}
            placeholder="e.g. ORD-12345"
            className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">SKU *</label>
          <input
            value={form.sku}
            onChange={(e) => set('sku', e.target.value)}
            placeholder="e.g. AB-VITA-C-60"
            className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-foreground"
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">Product Name *</label>
          <input
            value={form.productName}
            onChange={(e) => set('productName', e.target.value)}
            placeholder="e.g. Vitamin C 1000mg Tablets (60)"
            className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
          />
        </div>
        <div className="flex gap-3">
          <div className="flex-1">
            <label className="text-xs font-medium text-muted-foreground block mb-1">Quantity</label>
            <input
              type="number"
              min="1"
              value={form.quantity}
              onChange={(e) => set('quantity', e.target.value)}
              className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
            />
          </div>
          <div className="flex-1">
            <label className="text-xs font-medium text-muted-foreground block mb-1">Bin / Location</label>
            <input
              value={form.binLocation}
              onChange={(e) => set('binLocation', e.target.value)}
              placeholder="e.g. A3-12"
              className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-foreground"
            />
          </div>
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">Customer Name</label>
          <input
            value={form.customerName}
            onChange={(e) => set('customerName', e.target.value)}
            placeholder="Optional"
            className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">Source</label>
          <select
            value={form.source}
            onChange={(e) => set('source', e.target.value)}
            className="w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-foreground"
          >
            <option value="manual">Manual</option>
            <option value="shopify">Shopify</option>
            <option value="amazon">Amazon</option>
            <option value="ebay">eBay</option>
          </select>
        </div>
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <button onClick={onClose} className="rounded-md px-3 py-1.5 text-sm font-medium border border-border text-muted-foreground hover:text-foreground transition-colors">
          Cancel
        </button>
        <button
          onClick={handleSave}
          disabled={saving || !form.orderNumber || !form.sku || !form.productName}
          className="rounded-md px-3 py-1.5 text-sm font-medium bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50 transition-colors"
        >
          {saving ? 'Adding...' : 'Add Order'}
        </button>
      </div>
    </Dialog>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Orders Table
// ─────────────────────────────────────────────────────────────────────────────

function OrdersTab({ onBatchCreated }) {
  const [orders, setOrders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState(new Set());
  const [addOpen, setAddOpen] = useState(false);
  const [actionLoading, setActionLoading] = useState(null);
  const [deletingId, setDeletingId] = useState(null);
  const [confirmDeleteId, setConfirmDeleteId] = useState(null);

  const reload = useCallback(async () => {
    setLoading(true);
    const data = await getOrders();
    setOrders(data || []);
    setSelected(new Set());
    setLoading(false);
  }, []);

  useEffect(() => { reload(); }, [reload]);

  const pending = orders.filter((o) => o.status === 'pending');

  const toggleSelect = (id) => {
    setSelected((s) => {
      const n = new Set(s);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });
  };

  const toggleAll = () => {
    const pendingIds = pending.map((o) => o.id);
    const allSelected = pendingIds.every((id) => selected.has(id));
    setSelected(allSelected ? new Set() : new Set(pendingIds));
  };

  const handlePrintNext25 = async () => {
    setActionLoading('next25');
    const result = await printNext25();
    setActionLoading(null);
    if (result?.error) { alert(result.error); return; }
    onBatchCreated(result.picklist);
    reload();
  };

  const handlePrintSelected = async () => {
    if (!selected.size) return;
    setActionLoading('selected');
    const result = await printSelectedOrders(Array.from(selected));
    setActionLoading(null);
    if (result?.error) { alert(result.error); return; }
    onBatchCreated(result.picklist);
    reload();
  };

  const handleOvernightBatch = async () => {
    setActionLoading('overnight');
    const result = await runOvernightBatch();
    setActionLoading(null);
    if (result?.error) { alert(result.error); return; }
    onBatchCreated(result.picklist);
    reload();
  };

  const handleDelete = async (id) => {
    if (confirmDeleteId !== id) {
      setConfirmDeleteId(id);
      setTimeout(() => setConfirmDeleteId(null), 3000);
      return;
    }
    setDeletingId(id);
    await removeOrder(id);
    setDeletingId(null);
    setConfirmDeleteId(null);
    reload();
  };

  const pendingCount = pending.length;
  const selectedPending = pending.filter((o) => selected.has(o.id));

  return (
    <>
      <AddOrderDialog open={addOpen} onClose={() => setAddOpen(false)} onAdded={reload} />

      {/* Action bar */}
      <div className="flex flex-wrap items-center gap-2 mb-4">
        <button
          onClick={() => setAddOpen(true)}
          className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
        >
          <PlusIcon size={12} /> Add order
        </button>
        <button
          onClick={handlePrintNext25}
          disabled={!pendingCount || actionLoading === 'next25'}
          className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50 transition-colors"
        >
          {actionLoading === 'next25' ? <SpinnerIcon size={12} className="animate-spin" /> : <FileTextIcon size={12} />}
          Print next 25
        </button>
        <button
          onClick={handlePrintSelected}
          disabled={!selectedPending.length || actionLoading === 'selected'}
          className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 transition-colors"
        >
          {actionLoading === 'selected' ? <SpinnerIcon size={12} className="animate-spin" /> : <FileTextIcon size={12} />}
          Print selected ({selectedPending.length})
        </button>
        <button
          onClick={handleOvernightBatch}
          disabled={!pendingCount || actionLoading === 'overnight'}
          className="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 transition-colors"
        >
          {actionLoading === 'overnight' ? <SpinnerIcon size={12} className="animate-spin" /> : <ClockIcon size={12} />}
          Overnight batch
        </button>
        <button onClick={reload} className="ml-auto rounded-md p-1.5 border border-border text-muted-foreground hover:text-foreground transition-colors" title="Refresh">
          <RefreshIcon size={14} />
        </button>
      </div>

      {loading ? (
        <div className="space-y-2">
          {[...Array(4)].map((_, i) => <div key={i} className="h-10 bg-border/50 rounded-md animate-pulse" />)}
        </div>
      ) : orders.length === 0 ? (
        <EmptyState
          message="No orders yet. Add orders manually or import them via the API."
          actionLabel="Add order"
          onAction={() => setAddOpen(true)}
        />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-3 py-2 w-8">
                  <input
                    type="checkbox"
                    checked={pendingCount > 0 && pending.every((o) => selected.has(o.id))}
                    onChange={toggleAll}
                    className="cursor-pointer"
                  />
                </th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">Order #</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">SKU</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">Product</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">Bin</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">Qty</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">Status</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-muted-foreground">Received</th>
                <th className="px-3 py-2 w-8" />
              </tr>
            </thead>
            <tbody>
              {orders.map((order) => (
                <tr key={order.id} className={`border-b border-border last:border-0 hover:bg-accent/30 ${selected.has(order.id) ? 'bg-accent/20' : ''}`}>
                  <td className="px-3 py-2 text-center">
                    {order.status === 'pending' && (
                      <input
                        type="checkbox"
                        checked={selected.has(order.id)}
                        onChange={() => toggleSelect(order.id)}
                        className="cursor-pointer"
                      />
                    )}
                  </td>
                  <td className="px-3 py-2 font-mono text-xs font-medium">{order.orderNumber}</td>
                  <td className="px-3 py-2 font-mono text-xs text-muted-foreground">{order.sku}</td>
                  <td className="px-3 py-2 text-xs max-w-[180px] truncate">{order.productName}</td>
                  <td className="px-3 py-2 font-mono text-xs font-semibold text-blue-500">{order.binLocation || <span className="text-muted-foreground">—</span>}</td>
                  <td className="px-3 py-2 text-xs text-center">{order.quantity}</td>
                  <td className="px-3 py-2"><Badge value={order.status} /></td>
                  <td className="px-3 py-2 text-xs text-muted-foreground whitespace-nowrap">{timeAgo(order.createdAt)}</td>
                  <td className="px-3 py-2 text-center">
                    {order.status === 'pending' && (
                      <button
                        onClick={() => handleDelete(order.id)}
                        disabled={deletingId === order.id}
                        className={`rounded-md p-1 border transition-colors ${
                          confirmDeleteId === order.id
                            ? 'border-destructive text-destructive hover:bg-destructive/10'
                            : 'border-transparent text-muted-foreground hover:text-destructive hover:border-destructive'
                        }`}
                        title={confirmDeleteId === order.id ? 'Click again to confirm' : 'Delete'}
                      >
                        <TrashIcon size={12} />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Picklists Tab
// ─────────────────────────────────────────────────────────────────────────────

function PicklistsTab({ newPicklist }) {
  const [picklists, setPicklists] = useState([]);
  const [loading, setLoading] = useState(true);
  const [confirmDeleteId, setConfirmDeleteId] = useState(null);
  const [expandedId, setExpandedId] = useState(null);
  const [expandedData, setExpandedData] = useState({});

  const reload = useCallback(async () => {
    setLoading(true);
    const data = await getPicklists();
    setPicklists(data || []);
    setLoading(false);
  }, []);

  useEffect(() => { reload(); }, [reload]);

  // When a new picklist is created from the Orders tab, open its print page and refresh
  useEffect(() => {
    if (!newPicklist) return;
    reload();
    window.open(`/admin/picklist/print/${newPicklist.id}`, '_blank');
  }, [newPicklist, reload]);

  const handleDelete = async (id) => {
    if (confirmDeleteId !== id) {
      setConfirmDeleteId(id);
      setTimeout(() => setConfirmDeleteId(null), 3000);
      return;
    }
    await removePicklist(id);
    setConfirmDeleteId(null);
    reload();
  };

  const handleMarkPrinted = async (id) => {
    await markPicklistPrinted(id);
    reload();
  };

  const handleMarkCompleted = async (id) => {
    await markPicklistCompleted(id);
    reload();
  };

  const handleExpand = async (id) => {
    if (expandedId === id) { setExpandedId(null); return; }
    setExpandedId(id);
    if (!expandedData[id]) {
      const data = await getPicklist(id);
      setExpandedData((d) => ({ ...d, [id]: data }));
    }
  };

  return (
    <>
      <div className="flex items-center justify-between mb-4">
        <p className="text-sm text-muted-foreground">{picklists.length} picklist{picklists.length !== 1 ? 's' : ''} total</p>
        <button onClick={reload} className="rounded-md p-1.5 border border-border text-muted-foreground hover:text-foreground transition-colors" title="Refresh">
          <RefreshIcon size={14} />
        </button>
      </div>

      {loading ? (
        <div className="space-y-2">
          {[...Array(3)].map((_, i) => <div key={i} className="h-16 bg-border/50 rounded-md animate-pulse" />)}
        </div>
      ) : picklists.length === 0 ? (
        <EmptyState message="No picklists yet. Use 'Print next 25' or 'Overnight batch' on the Orders tab." />
      ) : (
        <div className="flex flex-col gap-2">
          {picklists.map((pl) => (
            <div key={pl.id} className="rounded-lg border border-border bg-card overflow-hidden">
              <div className="flex items-center gap-3 p-3 cursor-pointer hover:bg-accent/30" onClick={() => handleExpand(pl.id)}>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-xs font-mono font-semibold">{pl.id.slice(0, 8).toUpperCase()}</span>
                    <Badge value={pl.status} />
                    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium bg-muted text-muted-foreground`}>
                      {BATCH_LABELS[pl.batchType] || pl.batchType}
                    </span>
                    <span className="text-xs text-muted-foreground">{pl.orderCount} order{pl.orderCount !== 1 ? 's' : ''}</span>
                  </div>
                  <p className="text-xs text-muted-foreground mt-0.5">{timeAgo(pl.createdAt)}{pl.notes ? ` — ${pl.notes}` : ''}</p>
                </div>
                <div className="flex items-center gap-1.5 shrink-0" onClick={(e) => e.stopPropagation()}>
                  <a
                    href={`/admin/picklist/print/${pl.id}`}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1 rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
                  >
                    <FileTextIcon size={12} /> Print
                  </a>
                  {pl.status === 'pending' && (
                    <button
                      onClick={() => handleMarkPrinted(pl.id)}
                      className="rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
                    >
                      Mark printed
                    </button>
                  )}
                  {(pl.status === 'pending' || pl.status === 'printed') && (
                    <button
                      onClick={() => handleMarkCompleted(pl.id)}
                      className="rounded-md px-2.5 py-1.5 text-xs font-medium border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
                    >
                      <CheckIcon size={12} />
                    </button>
                  )}
                  <button
                    onClick={() => handleDelete(pl.id)}
                    className={`rounded-md p-1.5 border transition-colors ${
                      confirmDeleteId === pl.id
                        ? 'border-destructive text-destructive hover:bg-destructive/10'
                        : 'border-border text-muted-foreground hover:text-destructive hover:border-destructive'
                    }`}
                    title={confirmDeleteId === pl.id ? 'Click again to confirm' : 'Delete picklist'}
                  >
                    <TrashIcon size={12} />
                  </button>
                </div>
              </div>

              {expandedId === pl.id && expandedData[pl.id] && (
                <div className="border-t border-border p-3 overflow-x-auto">
                  <p className="text-xs font-medium text-muted-foreground mb-2">
                    {expandedData[pl.id].items?.length || 0} lines
                    {pl.printedAt ? ` — Printed ${timeAgo(pl.printedAt)}` : ''}
                    {pl.completedAt ? ` — Completed ${formatDate(pl.completedAt)}` : ''}
                  </p>
                  {expandedData[pl.id].items?.length > 0 && (
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="text-left border-b border-border">
                          <th className="pb-1 pr-4 text-muted-foreground font-medium">SKU</th>
                          <th className="pb-1 pr-4 text-muted-foreground font-medium">Product</th>
                          <th className="pb-1 pr-4 text-muted-foreground font-medium">Bin</th>
                          <th className="pb-1 text-muted-foreground font-medium text-center">Qty</th>
                        </tr>
                      </thead>
                      <tbody>
                        {expandedData[pl.id].items.map((item) => (
                          <tr key={item.id} className="border-b border-border/50 last:border-0">
                            <td className="py-1 pr-4 font-mono">{item.sku}</td>
                            <td className="py-1 pr-4 max-w-[200px] truncate">{item.productName}</td>
                            <td className="py-1 pr-4 font-mono font-semibold text-blue-500">{item.binLocation || '—'}</td>
                            <td className="py-1 text-center">{item.quantity}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Page
// ─────────────────────────────────────────────────────────────────────────────

export function PicklistPage() {
  const [activeTab, setActiveTab] = useState('orders');
  const [newPicklist, setNewPicklist] = useState(null);

  const handleBatchCreated = (picklist) => {
    setNewPicklist(picklist);
    setActiveTab('picklists');
  };

  const tabs = [
    { id: 'orders', label: 'Orders' },
    { id: 'picklists', label: 'Picklists' },
  ];

  return (
    <>
      <div className="mb-4">
        <p className="text-sm text-muted-foreground">Manage warehouse pick lists. Orders are batched by SKU for efficient picking.</p>
      </div>

      <div className="flex gap-1 border-b border-border mb-4">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`px-3 py-2 text-sm font-medium border-b-2 transition-colors ${
              activeTab === tab.id
                ? 'border-foreground text-foreground'
                : 'border-transparent text-muted-foreground hover:text-foreground hover:border-border'
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {activeTab === 'orders' && <OrdersTab onBatchCreated={handleBatchCreated} />}
      {activeTab === 'picklists' && <PicklistsTab newPicklist={newPicklist} />}
    </>
  );
}
