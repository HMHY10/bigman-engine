import { notFound } from 'next/navigation';
import QRCode from 'qrcode';

/**
 * GET /print/picklist/[id]
 *
 * Returns a print-optimised HTML document for a picklist.
 * No auth required — the picklist ID itself is the access token,
 * and it's only shared with warehouse staff via printed QR code.
 *
 * Auto-marks the picklist as 'printed' on first view.
 */
export async function GET(request, { params }) {
  const { id } = await params;

  const { getPicklistById, getPicklistOrderIds, markPicklistPrinted } = await import('thepopebot/db/picklists');
  const { getOrdersByIds } = await import('thepopebot/db/orders');
  const { generatePicklistHtml } = await import('thepopebot/picklist');

  const picklist = getPicklistById(id);
  if (!picklist) {
    return new Response('Picklist not found', { status: 404 });
  }

  // Mark as printed on first view
  if (picklist.status === 'pending') {
    markPicklistPrinted(id);
  }

  const orderIds = getPicklistOrderIds(id);
  const ordersWithItems = getOrdersByIds(orderIds);

  const appUrl = process.env.APP_URL || 'http://localhost:3000';
  const scanUrl = `${appUrl}/api/picklist/scan`;

  // Generate QR code as inline SVG (encodes the picklist ID for scanner)
  let qrSvg = '';
  try {
    const qrData = JSON.stringify({ picklist_id: id });
    qrSvg = await QRCode.toString(qrData, { type: 'svg', width: 80, margin: 1 });
  } catch {
    qrSvg = `<div style="width:80px;height:80px;border:2px dashed #ccc;display:flex;align-items:center;justify-content:center;font-size:10px;color:#999;">QR ERROR</div>`;
  }

  const bodyHtml = generatePicklistHtml(picklist, ordersWithItems, qrSvg, scanUrl);

  // Wrap in a full document with print button
  const fullHtml = bodyHtml.replace(
    '<body>',
    `<body>
<div class="no-print" style="position:fixed;top:12px;right:12px;z-index:999;display:flex;gap:8px;background:white;padding:8px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,.15);">
  <button onclick="window.print()" style="padding:6px 14px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:600;border:none;background:#111;color:#fff;">Print</button>
  <button onclick="window.close()" style="padding:6px 14px;border-radius:6px;cursor:pointer;font-size:13px;font-weight:600;border:1px solid #ccc;background:transparent;color:#111;">Close</button>
</div>`
  );

  return new Response(fullHtml, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}
