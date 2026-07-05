/**
 * Generate a print-ready HTML page for a picklist.
 * Called server-side from the Next.js print route.
 *
 * Includes:
 * - QR code (SVG, client-side generated via a minimal inline script)
 * - SKU groups with bin/location references
 * - Order list
 * - Auto-print on page load
 */

/**
 * Render the full HTML string for a picklist print page.
 * @param {object} data - result of getPicklistWithOrders()
 * @param {string} baseUrl - base URL for the QR code target
 * @returns {string} Full HTML
 */
export function renderPicklistHtml(data, baseUrl) {
  const { picklist, orderRows, skuGroups } = data;
  const picklistRef = picklist.id.slice(0, 8).toUpperCase();
  const scanUrl = `${baseUrl}/api/picklists/scan`;
  const qrData = JSON.stringify({ picklistId: picklist.id, action: 'complete' });
  const createdAt = new Date(picklist.createdAt).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  });

  // SKU rows HTML
  const skuRows = skuGroups
    .map(
      (grp) => `
    <tr>
      <td class="sku">${esc(grp.sku || '—')}</td>
      <td>${esc(grp.name)}</td>
      <td class="bin">${esc(grp.binLocation || '—')}</td>
      <td class="qty">${grp.totalQuantity}</td>
    </tr>`
    )
    .join('');

  // Order rows HTML
  const orderRows2 = orderRows
    .map(
      (o) => `
    <tr>
      <td class="mono">${esc(o.externalId || o.id.slice(0, 8))}</td>
      <td>${esc(o.customerName || '—')}</td>
      <td>${esc(
        [
          o.customerAddress?.line1,
          o.customerAddress?.city,
          o.customerAddress?.postcode,
        ]
          .filter(Boolean)
          .join(', ')
      )}</td>
      <td>${o.lineItems.map((i) => `${esc(i.sku || i.name)} ×${i.quantity}`).join(', ')}</td>
    </tr>`
    )
    .join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Picklist ${picklistRef}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; font-size: 12px; color: #111; background: #fff; padding: 16px; }
  .header { display: flex; align-items: flex-start; justify-content: space-between; margin-bottom: 16px; border-bottom: 2px solid #111; padding-bottom: 12px; }
  .header-left h1 { font-size: 20px; font-weight: 700; letter-spacing: -0.5px; }
  .header-left .meta { color: #555; margin-top: 4px; font-size: 11px; }
  .qr-block { text-align: center; }
  .qr-block canvas, .qr-block svg { width: 90px; height: 90px; }
  .qr-block .qr-label { font-size: 10px; color: #555; margin-top: 2px; }
  h2 { font-size: 13px; font-weight: 600; margin: 14px 0 6px; }
  table { width: 100%; border-collapse: collapse; font-size: 11px; }
  thead tr { background: #f5f5f5; }
  th { text-align: left; padding: 5px 6px; font-weight: 600; border-bottom: 1px solid #ddd; }
  td { padding: 4px 6px; border-bottom: 1px solid #eee; vertical-align: top; }
  .sku { font-family: monospace; font-size: 11px; }
  .bin { font-weight: 600; color: #1a6fbf; }
  .qty { text-align: right; font-weight: 700; font-size: 13px; }
  .mono { font-family: monospace; font-size: 10px; }
  .footer { margin-top: 20px; padding-top: 10px; border-top: 1px solid #ddd; font-size: 10px; color: #888; display: flex; justify-content: space-between; }
  @media print {
    body { padding: 8px; }
    .no-print { display: none; }
  }
</style>
</head>
<body>
<div class="header">
  <div class="header-left">
    <h1>Picklist ${picklistRef}</h1>
    <div class="meta">
      <div>${esc(createdAt)} &nbsp;·&nbsp; ${esc(picklist.batchType)} batch &nbsp;·&nbsp; ${orderRows.length} order${orderRows.length !== 1 ? 's' : ''}</div>
      <div style="margin-top:2px;">${skuGroups.length} SKU line${skuGroups.length !== 1 ? 's' : ''}</div>
    </div>
  </div>
  <div class="qr-block">
    <canvas id="qrcanvas"></canvas>
    <div class="qr-label">Scan to complete</div>
  </div>
</div>

<h2>Items to Pick — by SKU</h2>
<table>
  <thead><tr><th>SKU</th><th>Product Name</th><th>Bin / Location</th><th style="text-align:right">Qty</th></tr></thead>
  <tbody>${skuRows}</tbody>
</table>

<h2 style="margin-top:18px;">Orders in this Batch</h2>
<table>
  <thead><tr><th>Ref</th><th>Customer</th><th>Address</th><th>Items</th></tr></thead>
  <tbody>${orderRows2}</tbody>
</table>

<div class="footer">
  <span>ArryBarry Warehouse · Picklist ${picklistRef}</span>
  <span>Printed: <span id="printtime"></span></span>
</div>

<script>
// ── Inline QR code generator (minimal, no external deps) ──────────────────────
// Uses a tiny QR library loaded from jsDelivr for print pages (offline = degraded gracefully).
(function() {
  var data = ${JSON.stringify(qrData)};
  var canvas = document.getElementById('qrcanvas');
  // Print time
  document.getElementById('printtime').textContent = new Date().toLocaleString('en-GB');

  // Load QRCode library
  var s = document.createElement('script');
  s.src = 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js';
  s.onload = function() {
    new QRCode(canvas, { text: data, width: 90, height: 90, correctLevel: QRCode.CorrectLevel.M });
  };
  s.onerror = function() {
    // Fallback: show picklist ID as text
    canvas.style.display = 'none';
    var div = document.createElement('div');
    div.style = 'width:90px;height:90px;border:1px solid #ddd;display:flex;align-items:center;justify-content:center;font-size:9px;word-break:break-all;text-align:center;padding:4px;';
    div.textContent = ${JSON.stringify(picklist.id)};
    canvas.parentNode.insertBefore(div, canvas);
  };
  document.head.appendChild(s);
})();
</script>
</body>
</html>`;
}

function esc(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
