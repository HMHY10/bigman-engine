/**
 * Picklist automation core logic.
 *
 * Batching strategies:
 *  - overnight: All pending orders in one picklist, sorted/grouped by SKU. No order cap.
 *  - batch:     Up to N orders (default 25), or any orders waiting > MAX_WAIT_MINUTES.
 *  - manual:    Caller supplies explicit order IDs.
 */

import { getPendingOrders, getOrdersByIds } from '../db/orders.js';
import { createPicklist, hasOvernightPicklistToday } from '../db/picklists.js';

const DEFAULT_BATCH_SIZE = 25;
const MAX_WAIT_MINUTES = 15; // fallback: batch even if < 25 orders after this wait time

// ─────────────────────────────────────────────────────────────────────────────
// Batch creation helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Generate the overnight picklist from all pending orders.
 * Groups all overnight orders together; no order cap.
 * Skips if an overnight picklist has already been created today.
 * @returns {{ picklist: object, skipped: boolean }}
 */
export function generateOvernightPicklist() {
  if (hasOvernightPicklistToday()) {
    return { picklist: null, skipped: true, reason: 'overnight picklist already created today' };
  }

  const pending = getPendingOrders();
  if (!pending.length) {
    return { picklist: null, skipped: true, reason: 'no pending orders' };
  }

  const picklist = createPicklist('overnight', pending.map(o => o.id));
  return { picklist, skipped: false };
}

/**
 * Generate a daytime batch picklist.
 * Creates a batch if:
 *  - There are >= batchSize pending orders, OR
 *  - There are any pending orders AND the oldest has been waiting > MAX_WAIT_MINUTES
 * @param {number} [batchSize=25]
 * @returns {{ picklist: object|null, skipped: boolean, reason?: string }}
 */
export function generateBatchPicklist(batchSize = DEFAULT_BATCH_SIZE) {
  const pending = getPendingOrders();

  if (!pending.length) {
    return { picklist: null, skipped: true, reason: 'no pending orders' };
  }

  const oldestWaitMs = Date.now() - pending[0].createdAt;
  const oldestWaitMin = oldestWaitMs / 60000;
  const hasEnough = pending.length >= batchSize;
  const timedOut = oldestWaitMin >= MAX_WAIT_MINUTES;

  if (!hasEnough && !timedOut) {
    return {
      picklist: null,
      skipped: true,
      reason: `only ${pending.length} orders pending, oldest waiting ${Math.round(oldestWaitMin)}m (need ${batchSize} or ${MAX_WAIT_MINUTES}m timeout)`,
    };
  }

  const batch = pending.slice(0, batchSize);
  const picklist = createPicklist('batch', batch.map(o => o.id));
  return { picklist, skipped: false };
}

/**
 * Generate a manual picklist from a specific set of order IDs.
 * @param {string[]} orderIds
 * @returns {object} Created picklist
 */
export function generateManualPicklist(orderIds) {
  if (!orderIds?.length) throw new Error('No order IDs provided');
  return createPicklist('manual', orderIds);
}

/**
 * Generate a picklist for the next N pending orders (manual "Print next 25" button).
 * @param {number} [n=25]
 * @returns {object|null} Created picklist, or null if no pending orders
 */
export function generateNextNPicklist(n = DEFAULT_BATCH_SIZE) {
  const pending = getPendingOrders();
  if (!pending.length) return null;
  const batch = pending.slice(0, n);
  return createPicklist('batch', batch.map(o => o.id));
}

// ─────────────────────────────────────────────────────────────────────────────
// SKU grouping
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Group order items by SKU across a set of orders.
 * Returns an array sorted by total quantity desc (highest volume SKUs first).
 * @param {object[]} ordersWithItems - Orders with their items array
 * @returns {object[]} SKU groups: { sku, productName, binLocation, totalQty, lines: [{orderId, externalRef, qty}] }
 */
export function groupBySku(ordersWithItems) {
  const skuMap = new Map();

  for (const order of ordersWithItems) {
    for (const item of (order.items || [])) {
      if (!skuMap.has(item.sku)) {
        skuMap.set(item.sku, {
          sku: item.sku,
          productName: item.productName,
          binLocation: item.binLocation || '',
          totalQty: 0,
          lines: [],
        });
      }
      const group = skuMap.get(item.sku);
      group.totalQty += item.quantity;
      group.lines.push({
        orderId: order.id,
        externalRef: order.externalRef || order.externalId,
        customerName: order.customerName,
        qty: item.quantity,
      });
    }
  }

  return Array.from(skuMap.values()).sort((a, b) => b.totalQty - a.totalQty);
}

// ─────────────────────────────────────────────────────────────────────────────
// Print HTML generation
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Generate print-ready HTML for a picklist.
 * Caller must pass the picklist object and the orders (with items) included in it.
 * QR code SVG is passed in as a string (generated externally via qrcode package).
 *
 * @param {object} picklist - Picklist record
 * @param {object[]} ordersWithItems - Orders with their .items arrays
 * @param {string} qrSvg - SVG string for the picklist QR code
 * @param {string} scanUrl - URL encoded in the QR code
 * @returns {string} HTML string
 */
export function generatePicklistHtml(picklist, ordersWithItems, qrSvg, scanUrl) {
  const skuGroups = groupBySku(ordersWithItems);
  const createdDate = new Date(picklist.createdAt).toLocaleString('en-GB');
  const typeLabel = picklist.type === 'overnight' ? 'Overnight Batch'
    : picklist.type === 'batch' ? 'Auto Batch'
    : 'Manual Batch';

  const skuRows = skuGroups.map(group => {
    const orderLines = group.lines.map(line =>
      `<tr class="order-line">
        <td class="ref">${escHtml(line.externalRef)}</td>
        <td class="customer">${escHtml(line.customerName)}</td>
        <td class="qty">${line.qty}</td>
      </tr>`
    ).join('');

    return `
    <div class="sku-group">
      <div class="sku-header">
        <div class="sku-info">
          <span class="sku-code">${escHtml(group.sku)}</span>
          <span class="sku-name">${escHtml(group.productName)}</span>
        </div>
        <div class="sku-meta">
          ${group.binLocation ? `<span class="bin-badge">BIN: ${escHtml(group.binLocation)}</span>` : '<span class="bin-badge bin-unknown">BIN: ?</span>'}
          <span class="qty-badge">x${group.totalQty} total</span>
        </div>
      </div>
      <table class="order-table">
        <thead>
          <tr><th>Order Ref</th><th>Customer</th><th>Qty</th></tr>
        </thead>
        <tbody>${orderLines}</tbody>
      </table>
    </div>`;
  }).join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Picklist ${picklist.id.slice(0, 8).toUpperCase()}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: Arial, sans-serif; font-size: 12px; color: #000; background: #fff; }
    .page { max-width: 210mm; margin: 0 auto; padding: 12mm; }
    .header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #000; padding-bottom: 8px; margin-bottom: 12px; }
    .header-left h1 { font-size: 18px; font-weight: bold; }
    .header-left .meta { font-size: 11px; color: #555; margin-top: 4px; }
    .header-left .meta span { display: inline-block; margin-right: 12px; }
    .type-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 10px; font-weight: bold; text-transform: uppercase; background: #f0f0f0; border: 1px solid #ccc; }
    .qr-block { text-align: center; }
    .qr-block svg { width: 80px; height: 80px; }
    .qr-block .qr-label { font-size: 9px; color: #555; margin-top: 3px; }
    .summary { display: flex; gap: 16px; margin-bottom: 12px; padding: 8px; background: #f8f8f8; border: 1px solid #ddd; border-radius: 4px; }
    .summary-item { text-align: center; }
    .summary-item .value { font-size: 20px; font-weight: bold; }
    .summary-item .label { font-size: 10px; color: #666; }
    .sku-group { margin-bottom: 10px; border: 1px solid #ccc; border-radius: 4px; overflow: hidden; page-break-inside: avoid; }
    .sku-header { display: flex; justify-content: space-between; align-items: center; padding: 6px 10px; background: #222; color: #fff; }
    .sku-info { display: flex; flex-direction: column; }
    .sku-code { font-size: 13px; font-weight: bold; font-family: monospace; }
    .sku-name { font-size: 10px; color: #ccc; margin-top: 1px; }
    .sku-meta { display: flex; gap: 8px; align-items: center; }
    .bin-badge { padding: 3px 8px; background: #ff9900; color: #000; font-weight: bold; font-size: 11px; border-radius: 3px; font-family: monospace; }
    .bin-unknown { background: #aaa; }
    .qty-badge { padding: 3px 8px; background: #fff; color: #000; font-weight: bold; font-size: 11px; border-radius: 3px; }
    .order-table { width: 100%; border-collapse: collapse; }
    .order-table th { font-size: 10px; text-transform: uppercase; color: #666; padding: 4px 10px; text-align: left; border-top: 1px solid #ddd; background: #fafafa; }
    .order-table td { padding: 4px 10px; border-top: 1px solid #eee; }
    .order-table .ref { font-family: monospace; font-weight: bold; }
    .order-table .qty { text-align: right; font-weight: bold; }
    .footer { margin-top: 16px; border-top: 1px solid #ccc; padding-top: 8px; font-size: 10px; color: #888; display: flex; justify-content: space-between; }
    .checkbox-col { width: 24px; }
    .picked-checkbox { width: 16px; height: 16px; border: 2px solid #000; display: inline-block; }
    @media print {
      body { font-size: 11px; }
      .page { padding: 8mm; }
      .no-print { display: none !important; }
    }
  </style>
</head>
<body>
<div class="page">
  <div class="header">
    <div class="header-left">
      <h1>Picklist ${picklist.id.slice(0, 8).toUpperCase()}</h1>
      <div class="meta">
        <span class="type-badge">${typeLabel}</span>
        <span>${createdDate}</span>
        <span>${ordersWithItems.length} orders &bull; ${skuGroups.length} SKUs</span>
      </div>
    </div>
    <div class="qr-block">
      ${qrSvg}
      <div class="qr-label">Scan on return</div>
    </div>
  </div>

  <div class="summary">
    <div class="summary-item">
      <div class="value">${ordersWithItems.length}</div>
      <div class="label">Orders</div>
    </div>
    <div class="summary-item">
      <div class="value">${skuGroups.length}</div>
      <div class="label">SKUs</div>
    </div>
    <div class="summary-item">
      <div class="value">${skuGroups.reduce((s, g) => s + g.totalQty, 0)}</div>
      <div class="label">Total Items</div>
    </div>
  </div>

  ${skuRows}

  <div class="footer">
    <span>Picklist ID: ${picklist.id}</span>
    <span>Scan URL: ${escHtml(scanUrl)}</span>
  </div>
</div>
</body>
</html>`;
}

function escHtml(str) {
  return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
