'use server';

import { auth } from 'thepopebot/auth';
import fs from 'fs';
import path from 'path';

// ── Auth guard ─────────────────────────────────────────────────────────────
async function requireAuth() {
  const session = await auth();
  if (!session?.user?.id) throw new Error('Unauthorized');
  return session.user;
}

// ── Paths ──────────────────────────────────────────────────────────────────
const PICKLIST_DATA_DIR = path.join(process.cwd(), 'data', 'picklist-ops');
const BATCHES_DIR = path.join(PICKLIST_DATA_DIR, 'batches');
const STATE_FILE = path.join(PICKLIST_DATA_DIR, 'state.json');

function ensureDirs() {
  fs.mkdirSync(BATCHES_DIR, { recursive: true });
}

// ── State helpers ──────────────────────────────────────────────────────────
function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function writeState(updates) {
  ensureDirs();
  const current = readState();
  const next = { ...current, ...updates };
  fs.writeFileSync(STATE_FILE, JSON.stringify(next, null, 2));
  return next;
}

// ── BaseLinker API client ──────────────────────────────────────────────────
async function blRequest(method, params = {}) {
  const token = process.env.BASELINKER_API_TOKEN;
  if (!token) throw new Error('BASELINKER_API_TOKEN not configured');

  const body = new URLSearchParams({
    method,
    parameters: JSON.stringify(params),
  });

  const res = await fetch('https://api.baselinker.com/connector.php', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'X-BLToken': token,
    },
    body: body.toString(),
  });

  if (!res.ok) throw new Error(`BaseLinker HTTP ${res.status}`);
  const data = await res.json();
  if (data.status === 'ERROR') throw new Error(`BaseLinker: ${data.error_message || data.error_code}`);
  return data;
}

// Paginated order fetch
async function fetchAllOrders(since, statusId) {
  const allOrders = [];
  let lastOrderId = 0;
  let page = 0;
  const maxPages = 50;

  while (page < maxPages) {
    const params = { date_from: since, get_unconfirmed_orders: false };
    if (lastOrderId > 0) params.id_from = lastOrderId;
    if (statusId) params.status_id = Number(statusId);

    const data = await blRequest('getOrders', params);
    const orders = data.orders || [];
    if (orders.length === 0) break;

    allOrders.push(...orders);
    page++;
    if (orders.length < 100) break;
    lastOrderId = orders[orders.length - 1].order_id;
  }

  return allOrders;
}

// ── Picklist HTML generator (mirrors bash run.sh logic) ───────────────────
function generatePicklistHtml(orders, batchId, modeLabel) {
  const appUrl = process.env.APP_URL || '';
  const orderCount = orders.length;
  const dateStr = new Date().toLocaleString('en-GB', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });

  // SKU grouping
  const skuMap = new Map();
  for (const order of orders) {
    const oid = String(order.order_id);
    for (const product of order.products || []) {
      const sku = product.sku || product.storage_id || 'N/A';
      const name = product.name || 'Unknown';
      const qty = Number(product.quantity) || 1;
      if (!skuMap.has(sku)) {
        skuMap.set(sku, { sku, name, totalQty: 0, orders: new Set() });
      }
      const entry = skuMap.get(sku);
      entry.totalQty += qty;
      entry.orders.add(oid);
    }
  }

  const skuRows = [...skuMap.values()]
    .sort((a, b) => a.sku.localeCompare(b.sku))
    .map(({ sku, name, totalQty, orders }) => `
    <tr>
      <td class="check"><input type="checkbox" checked></td>
      <td class="sku">${esc(sku)}</td>
      <td class="name">${esc(name)}</td>
      <td class="qty">${totalQty}</td>
      <td class="orders">${esc([...orders].join(', '))}</td>
    </tr>`)
    .join('');

  const orderRows = orders.map((order) => {
    const oid = order.order_id;
    const customer = order.delivery_fullname || order.buyer_login || 'Unknown';
    const items = (order.products || []).reduce((s, p) => s + (Number(p.quantity) || 1), 0);
    return `
    <tr>
      <td class="check"><input type="checkbox" checked></td>
      <td class="oid">#${oid}</td>
      <td>${esc(customer)}</td>
      <td class="qty">${items}</td>
    </tr>`;
  }).join('');

  let qrSection = '';
  if (appUrl) {
    const packUrl = `${appUrl}/picklist/batch/${batchId}`;
    const encoded = encodeURIComponent(packUrl);
    qrSection = `
<div class="qr-section">
  <img class="qr-img"
       src="https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=${encoded}"
       alt="Pack Station QR Code">
  <div class="qr-text">
    <strong>Pack Station — Scan to Print Shipping Labels</strong>
    <p>Scan this QR code at the pack station to open the label printing page for all ${orderCount} orders in this batch.</p>
    <div class="qr-url">${esc(packUrl)}</div>
  </div>
</div>`;
  }

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width">
<title>Pick List — ${dateStr}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Helvetica Neue', Arial, sans-serif; font-size: 12px; color: #111; background: #fff; padding: 12mm 14mm; }
  .header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #111; padding-bottom: 10px; margin-bottom: 16px; }
  .header h1 { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; }
  .header .meta { font-size: 11px; color: #555; margin-top: 4px; }
  .header .meta strong { color: #111; }
  .header-right { text-align: right; font-size: 11px; color: #444; line-height: 1.9; }
  .field-label { display: inline-block; min-width: 90px; }
  .underline { display: inline-block; border-bottom: 1px solid #aaa; min-width: 140px; }
  h2 { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.8px; color: #555; border-bottom: 1px solid #ddd; padding-bottom: 4px; margin: 18px 0 8px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 10px; }
  th { background: #f0f0f0; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; text-align: left; padding: 5px 7px; border: 1px solid #ccc; }
  td { padding: 6px 7px; border: 1px solid #ddd; vertical-align: middle; }
  tr:nth-child(even) td { background: #fafafa; }
  .check { width: 22px; text-align: center; }
  input[type="checkbox"] { width: 14px; height: 14px; }
  .sku { font-family: monospace; font-size: 11px; width: 110px; }
  .oid { font-family: monospace; font-size: 11px; }
  .qty { text-align: center; font-weight: 700; font-size: 15px; width: 52px; }
  .orders { font-size: 10px; color: #555; width: 200px; }
  .qr-section { margin-top: 22px; padding: 12px 14px; border: 1.5px solid #bbb; border-radius: 4px; display: flex; align-items: flex-start; gap: 16px; page-break-inside: avoid; }
  .qr-img { display: block; flex-shrink: 0; }
  .qr-text strong { display: block; font-size: 13px; font-weight: 700; margin-bottom: 5px; }
  .qr-text p { font-size: 11px; color: #444; line-height: 1.4; }
  .qr-url { font-family: monospace; font-size: 9px; color: #777; word-break: break-all; margin-top: 8px; }
  @media print {
    body { padding: 0; }
    input[type="checkbox"] { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    tr:nth-child(even) td { background: #f8f8f8 !important; print-color-adjust: exact; }
    th { background: #e8e8e8 !important; print-color-adjust: exact; }
    @page { margin: 12mm; size: A4 portrait; }
    h2 { page-break-after: avoid; }
    tr { page-break-inside: avoid; }
  }
</style>
</head>
<body>
<div class="header">
  <div class="header-left">
    <h1>ArryBarry Pick List</h1>
    <div class="meta">
      Batch: <strong>${batchId}</strong> &bull;
      Mode: <strong>${modeLabel}</strong> &bull;
      Orders: <strong>${orderCount}</strong> &bull;
      Printed: <strong>${dateStr}</strong>
    </div>
  </div>
  <div class="header-right">
    <div><span class="field-label">Picker:</span><span class="underline">&nbsp;</span></div>
    <div><span class="field-label">Started:</span><span class="underline">&nbsp;</span></div>
    <div><span class="field-label">Finished:</span><span class="underline">&nbsp;</span></div>
    <div><span class="field-label">Checked by:</span><span class="underline">&nbsp;</span></div>
  </div>
</div>

<h2>Items to Pick — Grouped by SKU</h2>
<table>
  <thead>
    <tr>
      <th class="check">&#10003;</th>
      <th class="sku">SKU</th>
      <th class="name">Product Name</th>
      <th class="qty">Qty</th>
      <th class="orders">In Orders</th>
    </tr>
  </thead>
  <tbody>${skuRows}</tbody>
</table>

<h2>Order Summary (${orderCount} orders)</h2>
<table>
  <thead>
    <tr>
      <th class="check">&#10003;</th>
      <th class="oid">Order #</th>
      <th>Customer</th>
      <th class="qty">Items</th>
    </tr>
  </thead>
  <tbody>${orderRows}</tbody>
</table>

${qrSection}
</body>
</html>`;
}

function esc(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ── Save batch ─────────────────────────────────────────────────────────────
function saveBatch(batchId, orders, modeLabel, html) {
  ensureDirs();
  const orderIds = orders.map((o) => String(o.order_id));
  const manifest = {
    batch_id: batchId,
    mode: modeLabel,
    created_at: new Date().toISOString(),
    order_count: orders.length,
    order_ids: orderIds,
  };
  fs.writeFileSync(path.join(BATCHES_DIR, `${batchId}.json`), JSON.stringify(manifest, null, 2));
  fs.writeFileSync(path.join(BATCHES_DIR, `${batchId}.html`), html);
  writeState({ last_batch_epoch: Math.floor(Date.now() / 1000), last_batch_id: batchId, batch_start_epoch: null });
}

// ══════════════════════════════════════════════════════════════════════════════
// PUBLIC SERVER ACTIONS
// ══════════════════════════════════════════════════════════════════════════════

/**
 * Fetch ready orders from BaseLinker.
 * Returns { orders, state, batchSize }
 */
export async function getReadyOrders() {
  await requireAuth();

  const statusId = process.env.BL_PICKLIST_STATUS_ID || '';
  const since = Math.floor(Date.now() / 1000) - 7200; // last 2h
  const orders = await fetchAllOrders(since, statusId || undefined);
  const state = readState();
  const batchSize = Number(process.env.PICKLIST_BATCH_SIZE) || 25;

  return { orders, state, batchSize };
}

/**
 * Generate a picklist for the next N ready orders.
 * Returns { batchId } — caller navigates to /picklist/print/{batchId}
 */
export async function printNext(limit) {
  await requireAuth();

  const statusId = process.env.BL_PICKLIST_STATUS_ID || '';
  const since = Math.floor(Date.now() / 1000) - 86400;
  const n = limit || Number(process.env.PICKLIST_BATCH_SIZE) || 25;

  const all = await fetchAllOrders(since, statusId || undefined);
  const orders = all.slice(0, n);

  const batchId = `batch-${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}`;
  const html = generatePicklistHtml(orders, batchId, 'manual-next');
  saveBatch(batchId, orders, 'manual-next', html);

  return { batchId, orderCount: orders.length };
}

/**
 * Generate a picklist for specific order IDs.
 * Returns { batchId }
 */
export async function printSelected(orderIds) {
  await requireAuth();

  if (!orderIds || orderIds.length === 0) throw new Error('No orders selected');

  const statusId = process.env.BL_PICKLIST_STATUS_ID || '';
  const since = Math.floor(Date.now() / 1000) - 86400;
  const all = await fetchAllOrders(since, statusId || undefined);
  const idSet = new Set(orderIds.map(String));
  const orders = all.filter((o) => idSet.has(String(o.order_id)));

  if (orders.length === 0) throw new Error('None of the selected orders found in BaseLinker');

  const batchId = `batch-${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}`;
  const html = generatePicklistHtml(orders, batchId, 'manual-selected');
  saveBatch(batchId, orders, 'manual-selected', html);

  return { batchId, orderCount: orders.length };
}

/**
 * Get picklist state (batch timer, last batch, etc.)
 */
export async function getPicklistState() {
  await requireAuth();
  return readState();
}

/**
 * Get batch manifest for a given batch ID.
 */
export async function getBatchManifest(batchId) {
  await requireAuth();
  // Sanitise — only allow safe batch ID chars
  const safe = batchId.replace(/[^a-zA-Z0-9_-]/g, '');
  const manifestPath = path.join(BATCHES_DIR, `${safe}.json`);
  if (!fs.existsSync(manifestPath)) return null;
  return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
}

/**
 * Trigger shipping label creation for all orders in a batch via BaseLinker.
 * Returns { labelUrls: string[] }
 */
export async function createShippingLabels(batchId) {
  await requireAuth();

  const safe = batchId.replace(/[^a-zA-Z0-9_-]/g, '');
  const manifestPath = path.join(BATCHES_DIR, `${safe}.json`);
  if (!fs.existsSync(manifestPath)) throw new Error('Batch not found');

  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const orderIds = manifest.order_ids || [];

  const results = [];
  for (const orderId of orderIds) {
    try {
      // Create package for this order
      const pkgData = await blRequest('createPackage', { order_id: Number(orderId) });
      const packageId = pkgData.package_id;
      if (!packageId) {
        results.push({ order_id: orderId, error: 'No package ID returned' });
        continue;
      }

      // Get courier label
      const labelData = await blRequest('getCourierLabel', { package_id: packageId });
      const labelUrl = labelData.label_file_url || labelData.url;
      results.push({ order_id: orderId, package_id: packageId, label_url: labelUrl || null });
    } catch (err) {
      results.push({ order_id: orderId, error: err.message });
    }
  }

  return { results };
}
