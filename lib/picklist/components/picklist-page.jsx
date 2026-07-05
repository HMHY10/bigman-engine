'use client';

import { useState, useEffect, useCallback } from 'react';
import { PageLayout } from '../../chat/components/page-layout.js';
import {
  getWarehouseSummary,
  getPicklistDetail,
  printNextN,
  printSelected,
  runOvernightBatchAction,
  markPicklistPrinted,
  completePicklist,
  cancelOrder,
  createManualOrder,
} from '../actions.js';

// ─── Status pill ──────────────────────────────────────────────────────────────

function StatusPill({ status }) {
  const map = {
    pending: 'bg-yellow-500/10 text-yellow-500',
    batched: 'bg-blue-500/10 text-blue-500',
    picked: 'bg-green-500/10 text-green-500',
    shipped: 'bg-green-500/10 text-green-500',
    cancelled: 'bg-border/50 text-muted-foreground',
    printing: 'bg-blue-500/10 text-blue-500',
    printed: 'bg-blue-500/10 text-blue-500',
    completed: 'bg-green-500/10 text-green-500',
  };
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${map[status] || 'bg-border/50 text-muted-foreground'}`}>
      {status}
    </span>
  );
}

// ─── Picklist detail modal ────────────────────────────────────────────────────

function PicklistModal({ picklistId, onClose, onComplete }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [completing, setCompleting] = useState(false);

  useEffect(() => {
    getPicklistDetail(picklistId).then((d) => {
      setData(d);
      setLoading(false);
    });
  }, [picklistId]);

  const handlePrint = () => {
    window.open(`/warehouse/picklists/${picklistId}/print`, '_blank');
    markPicklistPrinted(picklistId).catch(() => {});
  };

  const handleComplete = async () => {
    setCompleting(true);
    await completePicklist(picklistId);
    setCompleting(false);
    onComplete?.();
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={onClose}>
      <div
        className="relative bg-card border border-border rounded-lg max-w-2xl w-full mx-4 max-h-[80vh] overflow-y-auto p-6"
        onClick={(e) => e.stopPropagation()}
      >
        <button
          onClick={onClose}
          className="absolute top-4 right-4 text-muted-foreground hover:text-foreground transition-colors"
          aria-label="Close"
        >
          ✕
        </button>

        {loading ? (
          <div className="space-y-3">
            <div className="h-6 animate-pulse rounded bg-border/50 w-1/3" />
            <div className="h-48 animate-pulse rounded bg-border/50" />
          </div>
        ) : !data ? (
          <p className="text-muted-foreground text-sm">Picklist not found.</p>
        ) : (
          <>
            <div className="flex items-center gap-3 mb-4">
              <h2 className="text-base font-semibold">
                Picklist {data.picklist.id.slice(0, 8).toUpperCase()}
              </h2>
              <StatusPill status={data.picklist.status} />
              <span className="text-xs text-muted-foreground">
                {data.picklist.batchType} · {data.picklist.orderCount} orders
              </span>
            </div>

            {/* SKU Groups */}
            <div className="mb-4">
              <h3 className="text-sm font-medium mb-2">Items by SKU</h3>
              <div className="rounded-lg border border-border overflow-hidden">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border bg-muted/50">
                      <th className="text-left px-3 py-2 font-medium text-muted-foreground">SKU</th>
                      <th className="text-left px-3 py-2 font-medium text-muted-foreground">Name</th>
                      <th className="text-left px-3 py-2 font-medium text-muted-foreground">Bin</th>
                      <th className="text-right px-3 py-2 font-medium text-muted-foreground">Qty</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.skuGroups.map((grp, i) => (
                      <tr key={i} className="border-b border-border last:border-0">
                        <td className="px-3 py-2 font-mono text-xs">{grp.sku || '—'}</td>
                        <td className="px-3 py-2">{grp.name}</td>
                        <td className="px-3 py-2 text-muted-foreground">{grp.binLocation || '—'}</td>
                        <td className="px-3 py-2 text-right font-medium">{grp.totalQuantity}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>

            {/* Order list */}
            <div className="mb-4">
              <h3 className="text-sm font-medium mb-2">Orders ({data.orderRows.length})</h3>
              <div className="space-y-1">
                {data.orderRows.map((order) => (
                  <div key={order.id} className="flex items-center justify-between px-3 py-2 rounded-md border border-border text-sm">
                    <span className="font-medium">{order.externalId || order.id.slice(0, 8)}</span>
                    <span className="text-muted-foreground">{order.customerName}</span>
                    <StatusPill status={order.status} />
                  </div>
                ))}
              </div>
            </div>

            <div className="flex gap-2 mt-5 justify-end">
              <button
                onClick={handlePrint}
                className="px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 transition-colors"
              >
                Print Picklist
              </button>
              {data.picklist.status !== 'completed' && (
                <button
                  onClick={handleComplete}
                  disabled={completing}
                  className="px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors disabled:opacity-50"
                >
                  {completing ? 'Completing...' : 'Mark Complete'}
                </button>
              )}
              <button
                onClick={onClose}
                className="px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:text-foreground transition-colors"
              >
                Close
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ─── Add order modal ──────────────────────────────────────────────────────────

function AddOrderModal({ onClose, onAdded }) {
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    externalId: '',
    customerName: '',
    addressLine1: '',
    addressCity: '',
    addressPostcode: '',
    notes: '',
    lineItemsRaw: '',
  });

  const handleSave = async () => {
    setSaving(true);
    let lineItems = [];
    try {
      lineItems = JSON.parse(form.lineItemsRaw || '[]');
    } catch {
      // treat as plain text SKU list
      lineItems = form.lineItemsRaw
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => {
          const [sku, ...rest] = l.split(' ');
          return { sku, name: rest.join(' ') || sku, quantity: 1, binLocation: '' };
        });
    }
    await createManualOrder({
      externalId: form.externalId || null,
      customerName: form.customerName,
      customerAddress: {
        line1: form.addressLine1,
        city: form.addressCity,
        postcode: form.addressPostcode,
      },
      notes: form.notes,
      lineItems,
    });
    setSaving(false);
    onAdded?.();
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={onClose}>
      <div
        className="bg-card border border-border rounded-lg max-w-md w-full mx-4 p-6"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-base font-semibold mb-4">Add Manual Order</h2>
        <div className="space-y-3">
          <div>
            <label className="text-sm text-muted-foreground">Order Reference</label>
            <input
              className="mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm"
              value={form.externalId}
              onChange={(e) => setForm({ ...form, externalId: e.target.value })}
              placeholder="e.g. ORD-1234"
            />
          </div>
          <div>
            <label className="text-sm text-muted-foreground">Customer Name</label>
            <input
              className="mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm"
              value={form.customerName}
              onChange={(e) => setForm({ ...form, customerName: e.target.value })}
            />
          </div>
          <div>
            <label className="text-sm text-muted-foreground">Address</label>
            <input
              className="mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm mb-1"
              value={form.addressLine1}
              onChange={(e) => setForm({ ...form, addressLine1: e.target.value })}
              placeholder="Address line 1"
            />
            <div className="flex gap-2">
              <input
                className="w-full rounded-md border border-border bg-input px-3 py-2 text-sm"
                value={form.addressCity}
                onChange={(e) => setForm({ ...form, addressCity: e.target.value })}
                placeholder="City"
              />
              <input
                className="w-28 rounded-md border border-border bg-input px-3 py-2 text-sm"
                value={form.addressPostcode}
                onChange={(e) => setForm({ ...form, addressPostcode: e.target.value })}
                placeholder="Postcode"
              />
            </div>
          </div>
          <div>
            <label className="text-sm text-muted-foreground">
              Line Items (JSON or one per line: SKU name)
            </label>
            <textarea
              rows={4}
              className="mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm font-mono"
              value={form.lineItemsRaw}
              onChange={(e) => setForm({ ...form, lineItemsRaw: e.target.value })}
              placeholder={'[{"sku":"AB123","name":"Product","quantity":2,"binLocation":"A1"}]'}
            />
          </div>
          <div>
            <label className="text-sm text-muted-foreground">Notes</label>
            <input
              className="mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm"
              value={form.notes}
              onChange={(e) => setForm({ ...form, notes: e.target.value })}
            />
          </div>
        </div>
        <div className="mt-5 flex justify-end gap-2">
          <button
            onClick={handleSave}
            disabled={saving}
            className="px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50 transition-colors"
          >
            {saving ? 'Saving...' : 'Add Order'}
          </button>
          <button
            onClick={onClose}
            className="px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:text-foreground transition-colors"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Main page ────────────────────────────────────────────────────────────────

export function PicklistPage({ session }) {
  const [loading, setLoading] = useState(true);
  const [data, setData] = useState({ pendingCount: 0, recentOrders: [], recentPicklists: [] });
  const [selectedOrderIds, setSelectedOrderIds] = useState(new Set());
  const [activeTab, setActiveTab] = useState('orders');
  const [viewingPicklist, setViewingPicklist] = useState(null);
  const [showAddOrder, setShowAddOrder] = useState(false);
  const [actionLoading, setActionLoading] = useState(false);
  const [actionFeedback, setActionFeedback] = useState('');
  const [confirmOvernight, setConfirmOvernight] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    const result = await getWarehouseSummary();
    setData(result);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  // Auto-refresh every 30s
  useEffect(() => {
    const interval = setInterval(load, 30_000);
    return () => clearInterval(interval);
  }, [load]);

  const feedback = (msg) => {
    setActionFeedback(msg);
    setTimeout(() => setActionFeedback(''), 3000);
  };

  const handlePrintNext25 = async () => {
    setActionLoading(true);
    const { picklist } = await printNextN(25);
    setActionLoading(false);
    if (picklist) {
      feedback(`Picklist created: ${picklist.id.slice(0, 8).toUpperCase()}`);
      await load();
      setViewingPicklist(picklist.id);
    } else {
      feedback('No pending orders to batch.');
    }
  };

  const handlePrintSelected = async () => {
    if (!selectedOrderIds.size) return;
    setActionLoading(true);
    const { picklist } = await printSelected(Array.from(selectedOrderIds));
    setActionLoading(false);
    setSelectedOrderIds(new Set());
    if (picklist) {
      feedback(`Picklist created: ${picklist.id.slice(0, 8).toUpperCase()}`);
      await load();
      setViewingPicklist(picklist.id);
    } else {
      feedback('No pending orders in selection.');
    }
  };

  const handleOvernightBatch = async () => {
    setConfirmOvernight(false);
    setActionLoading(true);
    const { picklist } = await runOvernightBatchAction();
    setActionLoading(false);
    if (picklist) {
      feedback(`Overnight picklist created: ${picklist.orderCount} orders`);
      await load();
      setViewingPicklist(picklist.id);
    } else {
      feedback('No pending orders for overnight batch.');
    }
  };

  const toggleOrderSelect = (id) => {
    setSelectedOrderIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const pendingOrders = data.recentOrders.filter((o) => o.status === 'pending');
  const otherOrders = data.recentOrders.filter((o) => o.status !== 'pending');

  if (loading) {
    return (
      <PageLayout session={session}>
        <div className="space-y-3">
          <div className="h-8 animate-pulse rounded-md bg-border/50 w-48" />
          <div className="h-24 animate-pulse rounded-md bg-border/50" />
          <div className="h-48 animate-pulse rounded-md bg-border/50" />
        </div>
      </PageLayout>
    );
  }

  return (
    <PageLayout session={session}>
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold">Warehouse</h1>
          <p className="text-sm text-muted-foreground mt-0.5">Picklist automation &amp; order fulfilment</p>
        </div>
        <button
          onClick={() => setShowAddOrder(true)}
          className="px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 transition-colors"
        >
          + Add Order
        </button>
      </div>

      {/* Stats bar */}
      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="rounded-lg border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">Pending Orders</p>
          <p className="text-2xl font-semibold mt-1">{data.pendingCount}</p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">Active Picklists</p>
          <p className="text-2xl font-semibold mt-1">
            {data.recentPicklists.filter((p) => p.status !== 'completed').length}
          </p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">Completed Today</p>
          <p className="text-2xl font-semibold mt-1">
            {data.recentPicklists.filter((p) => {
              if (p.status !== 'completed' || !p.completedAt) return false;
              const d = new Date(p.completedAt);
              const now = new Date();
              return d.getDate() === now.getDate() && d.getMonth() === now.getMonth();
            }).length}
          </p>
        </div>
      </div>

      {/* Action toolbar */}
      <div className="flex flex-wrap items-center gap-2 mb-4">
        <button
          onClick={handlePrintNext25}
          disabled={actionLoading || data.pendingCount === 0}
          className="px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50 transition-colors"
        >
          Print next 25
        </button>
        <button
          onClick={handlePrintSelected}
          disabled={actionLoading || selectedOrderIds.size === 0}
          className="px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 transition-colors"
        >
          Print selected ({selectedOrderIds.size})
        </button>
        <button
          onClick={() => setConfirmOvernight(true)}
          disabled={actionLoading || data.pendingCount === 0}
          className="px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 transition-colors"
        >
          Overnight batch (all {data.pendingCount})
        </button>
        {actionFeedback && (
          <span className="text-sm text-green-500">{actionFeedback}</span>
        )}
      </div>

      {/* Overnight confirm */}
      {confirmOvernight && (
        <div className="mb-4 rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-4">
          <p className="text-sm font-medium text-yellow-500 mb-1">
            Batch all {data.pendingCount} pending orders?
          </p>
          <p className="text-sm text-muted-foreground mb-3">
            This will create a single picklist with all pending orders, with no size cap.
          </p>
          <div className="flex gap-2">
            <button
              onClick={handleOvernightBatch}
              className="px-3 py-1.5 text-sm font-medium rounded-md bg-yellow-500/20 text-yellow-500 hover:bg-yellow-500/30 transition-colors"
            >
              Yes, batch all
            </button>
            <button
              onClick={() => setConfirmOvernight(false)}
              className="px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {/* Tabs */}
      <div className="flex gap-1 border-b border-border mb-4">
        {[
          { id: 'orders', label: `Orders (${pendingOrders.length} pending)` },
          { id: 'picklists', label: `Picklists (${data.recentPicklists.length})` },
          { id: 'history', label: 'History' },
        ].map((tab) => (
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

      {/* Orders tab */}
      {activeTab === 'orders' && (
        <div className="space-y-2">
          {pendingOrders.length === 0 ? (
            <div className="rounded-lg border border-dashed border-border p-8 text-center">
              <p className="text-muted-foreground text-sm">No pending orders.</p>
            </div>
          ) : (
            <div className="rounded-lg border border-border overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border bg-muted/50">
                    <th className="px-3 py-2 w-10">
                      <input
                        type="checkbox"
                        className="h-4 w-4 rounded border-border"
                        checked={selectedOrderIds.size === pendingOrders.length && pendingOrders.length > 0}
                        onChange={(e) => {
                          if (e.target.checked) {
                            setSelectedOrderIds(new Set(pendingOrders.map((o) => o.id)));
                          } else {
                            setSelectedOrderIds(new Set());
                          }
                        }}
                      />
                    </th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Ref</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Customer</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Items</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Source</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Received</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {pendingOrders.map((order) => (
                    <tr key={order.id} className="border-b border-border last:border-0 hover:bg-muted/30">
                      <td className="px-3 py-2">
                        <input
                          type="checkbox"
                          className="h-4 w-4 rounded border-border"
                          checked={selectedOrderIds.has(order.id)}
                          onChange={() => toggleOrderSelect(order.id)}
                        />
                      </td>
                      <td className="px-3 py-2 font-mono text-xs">{order.externalId || order.id.slice(0, 8)}</td>
                      <td className="px-3 py-2">{order.customerName || '—'}</td>
                      <td className="px-3 py-2 text-muted-foreground">
                        {order.lineItems.length} item{order.lineItems.length !== 1 ? 's' : ''}
                      </td>
                      <td className="px-3 py-2 text-muted-foreground">{order.source}</td>
                      <td className="px-3 py-2 text-muted-foreground text-xs">
                        {new Date(order.receivedAt).toLocaleString('en-GB', {
                          day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
                        })}
                      </td>
                      <td className="px-3 py-2"><StatusPill status={order.status} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {/* Picklists tab */}
      {activeTab === 'picklists' && (
        <div className="space-y-2">
          {data.recentPicklists.filter((p) => p.status !== 'completed').length === 0 ? (
            <div className="rounded-lg border border-dashed border-border p-8 text-center">
              <p className="text-muted-foreground text-sm">No active picklists.</p>
            </div>
          ) : (
            <div className="rounded-lg border border-border overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border bg-muted/50">
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">ID</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Type</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Orders</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Created</th>
                    <th className="text-left px-3 py-2 font-medium text-muted-foreground">Status</th>
                    <th className="px-3 py-2" />
                  </tr>
                </thead>
                <tbody>
                  {data.recentPicklists
                    .filter((p) => p.status !== 'completed')
                    .map((pl) => (
                      <tr key={pl.id} className="border-b border-border last:border-0 hover:bg-muted/30">
                        <td className="px-3 py-2 font-mono text-xs">{pl.id.slice(0, 8).toUpperCase()}</td>
                        <td className="px-3 py-2 text-muted-foreground">{pl.batchType}</td>
                        <td className="px-3 py-2">{pl.orderCount}</td>
                        <td className="px-3 py-2 text-muted-foreground text-xs">
                          {new Date(pl.createdAt).toLocaleString('en-GB', {
                            day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
                          })}
                        </td>
                        <td className="px-3 py-2"><StatusPill status={pl.status} /></td>
                        <td className="px-3 py-2 text-right">
                          <button
                            onClick={() => setViewingPicklist(pl.id)}
                            className="px-2.5 py-1.5 text-xs font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
                          >
                            View
                          </button>
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {/* History tab */}
      {activeTab === 'history' && (
        <div className="space-y-2">
          {[...pendingOrders, ...otherOrders].filter((o) => o.status !== 'pending').length === 0 &&
          data.recentPicklists.filter((p) => p.status === 'completed').length === 0 ? (
            <div className="rounded-lg border border-dashed border-border p-8 text-center">
              <p className="text-muted-foreground text-sm">No completed picklists yet.</p>
            </div>
          ) : (
            <>
              {data.recentPicklists.filter((p) => p.status === 'completed').length > 0 && (
                <div className="rounded-lg border border-border overflow-hidden">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-border bg-muted/50">
                        <th className="text-left px-3 py-2 font-medium text-muted-foreground">Picklist ID</th>
                        <th className="text-left px-3 py-2 font-medium text-muted-foreground">Type</th>
                        <th className="text-left px-3 py-2 font-medium text-muted-foreground">Orders</th>
                        <th className="text-left px-3 py-2 font-medium text-muted-foreground">Completed</th>
                        <th className="px-3 py-2" />
                      </tr>
                    </thead>
                    <tbody>
                      {data.recentPicklists
                        .filter((p) => p.status === 'completed')
                        .map((pl) => (
                          <tr key={pl.id} className="border-b border-border last:border-0 hover:bg-muted/30">
                            <td className="px-3 py-2 font-mono text-xs">{pl.id.slice(0, 8).toUpperCase()}</td>
                            <td className="px-3 py-2 text-muted-foreground">{pl.batchType}</td>
                            <td className="px-3 py-2">{pl.orderCount}</td>
                            <td className="px-3 py-2 text-muted-foreground text-xs">
                              {pl.completedAt
                                ? new Date(pl.completedAt).toLocaleString('en-GB', {
                                    day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
                                  })
                                : '—'}
                            </td>
                            <td className="px-3 py-2 text-right">
                              <button
                                onClick={() => setViewingPicklist(pl.id)}
                                className="px-2.5 py-1.5 text-xs font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
                              >
                                View
                              </button>
                            </td>
                          </tr>
                        ))}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </div>
      )}

      {/* Modals */}
      {viewingPicklist && (
        <PicklistModal
          picklistId={viewingPicklist}
          onClose={() => setViewingPicklist(null)}
          onComplete={load}
        />
      )}
      {showAddOrder && (
        <AddOrderModal
          onClose={() => setShowAddOrder(false)}
          onAdded={load}
        />
      )}
    </PageLayout>
  );
}
