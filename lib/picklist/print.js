/**
 * Picklist print template generator.
 *
 * generatePicklistHtml(picklist, items) → HTML string
 *
 * The HTML is designed for A4 print. It includes:
 *   - Picklist header with ID, date, batch type, order count
 *   - QR code (rendered client-side via qrcodejs loaded from CDN)
 *   - Orders grouped and sorted by SKU
 *   - Bin/location references per line
 *
 * The print page is a self-contained HTML document that auto-focuses
 * window.print() on load so the browser print dialog opens immediately.
 */

/**
 * Group picklist items by SKU, sorting by bin location within each group.
 */
function groupItemsBySku(items) {
  const map = new Map();
  for (const item of items) {
    if (!map.has(item.sku)) map.set(item.sku, []);
    map.get(item.sku).push(item);
  }
  return Array.from(map.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([sku, skuItems]) => ({
      sku,
      productName: skuItems[0].productName,
      binLocation: skuItems[0].binLocation,
      items: skuItems.sort((a, b) => (a.binLocation || '').localeCompare(b.binLocation || '')),
      totalQty: skuItems.reduce((sum, i) => sum + i.quantity, 0),
    }));
}

function batchTypeLabel(type) {
  switch (type) {
    case 'overnight': return 'Overnight Batch';
    case 'realtime': return 'Realtime Batch';
    default: return 'Manual Batch';
  }
}

function formatDate(ts) {
  return new Date(ts).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

/**
 * Generate a self-contained HTML print page for a picklist.
 *
 * @param {object} picklist - Picklist record from DB
 * @param {object[]} items  - Picklist items from DB
 * @param {string} baseUrl  - Base URL of the application (for QR code payload)
 * @returns {string} HTML string
 */
export function generatePicklistHtml(picklist, items, baseUrl = '') {
  const groups = groupItemsBySku(items);
  const scanUrl = `${baseUrl}/webhook/picklist-scan?id=${picklist.id}`;
  const shortId = picklist.id.slice(0, 8).toUpperCase();

  const skuRows = groups.map((group) => {
    const binCell = group.binLocation
      ? `<td class="bin">${group.binLocation}</td>`
      : `<td class="bin muted">—</td>`;

    // If multiple orders share a SKU, show qty per order in sub-rows
    const qtyBreakdown = group.items.length > 1
      ? group.items.map((i) => `<span class="order-ref">${i.quantity} × ${i.orderId ? '' : ''}order</span>`).join(' ')
      : '';

    return `
      <tr>
        <td class="sku">${group.sku}</td>
        <td class="product">${group.productName}</td>
        ${binCell}
        <td class="qty">${group.totalQty}</td>
        <td class="orders">${group.items.length}</td>
        <td class="tick"></td>
      </tr>`;
  }).join('');

  const orderDetails = items.map((item) => `
    <tr>
      <td>${item.sku}</td>
      <td>${item.productName}</td>
      <td>${item.binLocation || '—'}</td>
      <td>${item.quantity}</td>
      <td class="order-num">${item.orderId || '—'}</td>
    </tr>`).join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Picklist ${shortId}</title>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: Arial, sans-serif; font-size: 12px; color: #000; background: #fff; }
  .page { padding: 16mm 14mm; max-width: 210mm; margin: 0 auto; }

  /* Header */
  .header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #000; padding-bottom: 8px; margin-bottom: 12px; }
  .header-left h1 { font-size: 20px; font-weight: 700; letter-spacing: 0.5px; }
  .header-left .meta { margin-top: 4px; font-size: 11px; color: #444; }
  .header-left .badge { display: inline-block; background: #000; color: #fff; font-size: 10px; font-weight: 700; padding: 2px 6px; border-radius: 3px; margin-left: 6px; text-transform: uppercase; }
  .header-right { text-align: right; }
  .header-right #qrcode { margin-bottom: 4px; }
  .header-right .qr-label { font-size: 9px; color: #666; }
  .scan-url { font-size: 8px; color: #888; word-break: break-all; max-width: 120px; }

  /* Summary bar */
  .summary { display: flex; gap: 24px; background: #f4f4f4; border: 1px solid #ddd; border-radius: 4px; padding: 8px 12px; margin-bottom: 14px; }
  .summary-item { display: flex; flex-direction: column; }
  .summary-item .label { font-size: 9px; text-transform: uppercase; color: #666; font-weight: 600; }
  .summary-item .value { font-size: 16px; font-weight: 700; }

  /* Pick table */
  h2 { font-size: 13px; font-weight: 700; margin-bottom: 6px; text-transform: uppercase; letter-spacing: 0.5px; border-bottom: 1px solid #000; padding-bottom: 3px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
  th { background: #000; color: #fff; font-size: 10px; font-weight: 700; text-transform: uppercase; padding: 5px 6px; text-align: left; }
  td { padding: 5px 6px; border-bottom: 1px solid #e0e0e0; vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:nth-child(even) td { background: #fafafa; }

  .sku { font-family: monospace; font-size: 11px; font-weight: 600; white-space: nowrap; }
  .product { max-width: 200px; }
  .bin { font-family: monospace; font-weight: 700; font-size: 13px; color: #1a1a8c; white-space: nowrap; }
  .bin.muted { color: #aaa; font-weight: normal; }
  .qty { font-size: 16px; font-weight: 700; text-align: center; }
  .orders { text-align: center; color: #666; }
  .tick { width: 32px; border: 2px solid #999; border-radius: 3px; height: 20px; }

  /* Order detail table */
  .order-detail { font-size: 10px; }
  .order-num { font-family: monospace; font-size: 10px; }

  /* Signature line */
  .footer { margin-top: 12px; border-top: 1px solid #000; padding-top: 8px; display: flex; justify-content: space-between; font-size: 10px; color: #555; }
  .sig-box { display: flex; align-items: center; gap: 20px; }
  .sig-line { width: 160px; border-bottom: 1px solid #000; margin-bottom: 12px; }

  @media print {
    .no-print { display: none; }
    .page { padding: 10mm; }
    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  }

  /* Screen-only print button */
  .print-btn { position: fixed; top: 16px; right: 16px; background: #000; color: #fff; border: none; padding: 8px 16px; font-size: 14px; cursor: pointer; border-radius: 4px; z-index: 100; }
  .print-btn:hover { background: #333; }
</style>
</head>
<body>
<button class="print-btn no-print" onclick="window.print()">Print</button>
<div class="page">
  <!-- Header -->
  <div class="header">
    <div class="header-left">
      <h1>PICKLIST <span style="color:#555">#${shortId}</span></h1>
      <div class="meta">
        Generated: ${formatDate(picklist.createdAt)}
        <span class="badge">${batchTypeLabel(picklist.batchType)}</span>
      </div>
    </div>
    <div class="header-right">
      <div id="qrcode"></div>
      <div class="qr-label">Scan on return</div>
    </div>
  </div>

  <!-- Summary -->
  <div class="summary">
    <div class="summary-item"><span class="label">SKUs</span><span class="value">${groups.length}</span></div>
    <div class="summary-item"><span class="label">Order Lines</span><span class="value">${items.length}</span></div>
    <div class="summary-item"><span class="label">Total Units</span><span class="value">${items.reduce((s, i) => s + i.quantity, 0)}</span></div>
    <div class="summary-item"><span class="label">Picklist ID</span><span class="value" style="font-size:12px;font-family:monospace">${picklist.id}</span></div>
  </div>

  <!-- Pick by SKU -->
  <h2>Pick List — By SKU</h2>
  <table>
    <thead>
      <tr>
        <th style="width:120px">SKU</th>
        <th>Product</th>
        <th style="width:90px">Bin / Location</th>
        <th style="width:60px;text-align:center">Total Qty</th>
        <th style="width:50px;text-align:center">Orders</th>
        <th style="width:40px;text-align:center">Pick ✓</th>
      </tr>
    </thead>
    <tbody>
      ${skuRows}
    </tbody>
  </table>

  <!-- Order detail -->
  <h2>Order Detail</h2>
  <table class="order-detail">
    <thead>
      <tr>
        <th>SKU</th>
        <th>Product</th>
        <th>Bin</th>
        <th style="width:50px;text-align:center">Qty</th>
        <th>Order ID</th>
      </tr>
    </thead>
    <tbody>
      ${orderDetails}
    </tbody>
  </table>

  <!-- Footer -->
  <div class="footer">
    <div class="sig-box">
      <div>
        <div class="sig-line"></div>
        <span>Picker signature</span>
      </div>
      <div>
        <div class="sig-line"></div>
        <span>Checked by</span>
      </div>
    </div>
    <div>ArryBarry Health &amp; Beauty — Picklist #${shortId}</div>
  </div>
</div>

<script>
  var qr = new QRCode(document.getElementById('qrcode'), {
    text: ${JSON.stringify(scanUrl)},
    width: 96,
    height: 96,
    correctLevel: QRCode.CorrectLevel.M,
  });
</script>
</body>
</html>`;
}
