#!/usr/bin/env python3
"""
generate-picklist.py — Generate SKU-grouped, print-ready HTML picklist for ArryBarry

Called by run.sh via environment variables:
  PICKLIST_ORDERS       JSON array of BaseLinker order objects
  PICKLIST_BATCH_ID     Batch number string
  PICKLIST_BATCH_TYPE   one of: auto, time-limit, morning, manual, manual-selected
  PICKLIST_HOST         Base URL for QR/webhook links
  PICKLIST_OUTPUT_DIR   Directory to save HTML files
  PICKLIST_PRINT_CMD    Optional: shell command to send file to printer
  VAULT_URL             Obsidian REST API base URL
  OBSIDIAN_API_KEY      Obsidian REST API key

Outputs the saved HTML file path to stdout on success.
"""

import json
import os
import sys
import subprocess
import datetime
import urllib.request
import urllib.error


def log(msg):
    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f'[{ts}] generate-picklist: {msg}', file=sys.stderr)


def get_qr_svg(data):
    """
    Generate a QR code as an inline SVG string using the qrencode CLI.
    Returns the SVG string (with XML declaration stripped) or None if
    qrencode is not installed.
    """
    try:
        result = subprocess.run(
            ['qrencode', '-t', 'SVG', '-o', '-', '-s', '4', '--margin=1', '--', data],
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0:
            lines = result.stdout.decode('utf-8').splitlines()
            # Strip XML declaration so the SVG can be inlined in HTML
            svg_lines = [l for l in lines if not l.startswith('<?xml')]
            return '\n'.join(svg_lines)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def build_sku_groups(orders):
    """
    Group every product line across all orders by SKU.
    Returns an OrderedDict (sorted by SKU) of:
      {sku: {name, sku, total_qty, location, orders: [{order_id, qty, location}]}}
    """
    groups = {}
    for order in orders:
        order_id = order.get('order_id', '?')
        for product in order.get('products', []):
            raw_sku = (product.get('sku') or '').strip()
            sku = raw_sku if raw_sku else f"PROD-{product.get('product_id', 'UNKNOWN')}"
            name = (product.get('name') or 'Unknown Product').strip()
            try:
                qty = int(float(product.get('quantity', 1)))
            except (ValueError, TypeError):
                qty = 1
            location = (product.get('location') or '').strip() or '—'

            if sku not in groups:
                groups[sku] = {
                    'name': name,
                    'sku': sku,
                    'total_qty': 0,
                    'location': location,
                    'orders': [],
                }
            groups[sku]['total_qty'] += qty
            groups[sku]['orders'].append({
                'order_id': order_id,
                'qty': qty,
                'location': location,
            })

    return dict(sorted(groups.items()))


def render_sku_section(sku, group):
    """Render one SKU block for the pick-list section."""
    rows = ''
    for entry in group['orders']:
        rows += f"""
            <tr>
              <td class="col-order">#{entry['order_id']}</td>
              <td class="col-qty">{entry['qty']}</td>
              <td class="col-loc">{entry['location']}</td>
              <td class="col-tick">&#9744;</td>
            </tr>"""

    total = group['total_qty']
    unit_label = 'unit' if total == 1 else 'units'

    return f"""
  <div class="sku-block" data-sku="{sku}">
    <div class="sku-header">
      <span class="sku-name">{group['name']}</span>
      <span class="sku-badges">
        <span class="badge-sku">SKU: {sku}</span>
        <span class="badge-qty">Pick: {total} {unit_label}</span>
        <span class="badge-loc">&#128205; {group['location']}</span>
      </span>
    </div>
    <table class="pick-table">
      <thead>
        <tr><th>Order</th><th>Qty</th><th>Location</th><th>Picked &#10003;</th></tr>
      </thead>
      <tbody>{rows}
      </tbody>
    </table>
  </div>"""


def render_order_card(order, host):
    """
    Render a single order card for the pack-station QR section.
    The QR code encodes the BaseLinker order URL so scanning opens it directly.
    """
    order_id = order.get('order_id', '?')
    products = order.get('products', [])
    total_units = sum(int(float(p.get('quantity', 1))) for p in products)
    delivery_name = (
        order.get('delivery_fullname')
        or order.get('customer_login')
        or '—'
    ).strip()
    source = (order.get('order_source') or '').strip()

    # QR encodes the BaseLinker panel URL — works with any barcode scanner
    bl_url = f"https://panel.baselinker.com/orders/order?order_id={order_id}"
    qr_svg = get_qr_svg(bl_url)
    if qr_svg:
        qr_html = f'<div class="qr-wrap">{qr_svg}</div>'
    else:
        qr_html = f'<div class="qr-fallback">{bl_url}</div>'

    product_lines = ''
    for p in products:
        raw_sku = (p.get('sku') or '').strip()
        p_sku = raw_sku if raw_sku else f"PROD-{p.get('product_id', '?')}"
        p_name = (p.get('name') or '?').strip()
        p_qty = int(float(p.get('quantity', 1)))
        product_lines += f'<li>{p_name} &times; {p_qty} <em class="p-sku">[{p_sku}]</em></li>'

    unit_label = 'unit' if total_units == 1 else 'units'
    source_html = f'<span class="card-source">{source}</span>' if source else ''

    return f"""
    <div class="order-card" data-order="{order_id}">
      <div class="card-info">
        <div class="card-id">#{order_id}{source_html}</div>
        <div class="card-name">{delivery_name}</div>
        <div class="card-total">{total_units} {unit_label}</div>
        <ul class="card-products">{product_lines}</ul>
      </div>
      <div class="card-qr">
        {qr_html}
        <div class="qr-caption">Scan &#8594; BaseLinker</div>
      </div>
    </div>"""


CSS = """
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: Arial, Helvetica, sans-serif;
      font-size: 11pt;
      color: #111;
      background: #fff;
      padding: 12mm 14mm;
    }

    /* ── Page header ─────────────────────────────────── */
    .page-hdr {
      border-bottom: 3px solid #111;
      padding-bottom: 10px;
      margin-bottom: 18px;
    }
    .page-hdr h1 {
      font-size: 20pt;
      font-weight: 900;
      letter-spacing: -0.5px;
    }
    .hdr-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 20px;
      margin-top: 5px;
      font-size: 9pt;
      color: #444;
    }
    .hdr-meta strong { color: #111; }

    /* ── Section heading ─────────────────────────────── */
    h2 {
      font-size: 13pt;
      font-weight: 700;
      border-bottom: 2px solid #111;
      padding-bottom: 4px;
      margin: 22px 0 14px;
    }
    h2 .section-sub {
      font-size: 9pt;
      font-weight: 400;
      color: #666;
      margin-left: 8px;
    }

    /* ── SKU blocks ──────────────────────────────────── */
    .sku-block {
      border: 1px solid #bbb;
      border-radius: 4px;
      margin-bottom: 18px;
      page-break-inside: avoid;
      overflow: hidden;
    }
    .sku-header {
      background: #f2f2f2;
      padding: 7px 12px;
      border-bottom: 1px solid #bbb;
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px;
    }
    .sku-name {
      font-size: 12pt;
      font-weight: 700;
      flex: 1 1 auto;
    }
    .sku-badges {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }
    .badge-sku, .badge-qty, .badge-loc {
      font-size: 8.5pt;
      padding: 2px 7px;
      border-radius: 3px;
      white-space: nowrap;
    }
    .badge-sku  { background: #dde8ff; color: #1a3a80; }
    .badge-qty  { background: #ffe0e0; color: #900; font-weight: 700; }
    .badge-loc  { background: #e6f4e6; color: #1a5c1a; }

    .pick-table {
      width: 100%;
      border-collapse: collapse;
    }
    .pick-table th {
      background: #e8e8e8;
      text-align: left;
      padding: 4px 10px;
      font-size: 8.5pt;
      font-weight: 600;
      border-bottom: 1px solid #bbb;
    }
    .pick-table td {
      padding: 5px 10px;
      border-bottom: 1px solid #eee;
      font-size: 10pt;
    }
    .pick-table tr:last-child td { border-bottom: none; }
    .col-order { font-family: monospace; font-weight: 700; }
    .col-qty   { font-weight: 700; color: #c00; text-align: center; width: 60px; }
    .col-loc   { color: #555; }
    .col-tick  { text-align: center; font-size: 15pt; width: 60px; }

    /* ── Order cards (pack station) ──────────────────── */
    .cards-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 12px;
    }
    .order-card {
      border: 2px solid #111;
      border-radius: 4px;
      padding: 10px 12px;
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      page-break-inside: avoid;
    }
    .card-info { flex: 1 1 auto; }
    .card-id {
      font-size: 15pt;
      font-weight: 900;
      font-family: monospace;
      line-height: 1.2;
    }
    .card-source {
      font-size: 7.5pt;
      font-weight: 400;
      font-family: Arial, sans-serif;
      color: #777;
      margin-left: 6px;
    }
    .card-name  { font-size: 8.5pt; color: #555; margin-top: 3px; }
    .card-total { font-size: 11pt; font-weight: 700; margin-top: 6px; }
    .card-products {
      list-style: disc;
      padding-left: 16px;
      margin-top: 5px;
      font-size: 7.5pt;
      color: #444;
    }
    .p-sku { color: #888; }
    .card-qr { text-align: center; margin-left: 10px; flex-shrink: 0; }
    .qr-wrap svg { width: 90px !important; height: 90px !important; }
    .qr-caption {
      font-size: 6.5pt;
      color: #666;
      margin-top: 3px;
      text-align: center;
    }
    .qr-fallback {
      font-family: monospace;
      font-size: 5.5pt;
      color: #777;
      word-break: break-all;
      max-width: 90px;
      text-align: left;
    }

    /* ── Page break ──────────────────────────────────── */
    .page-break { page-break-before: always; }

    /* ── Footer ──────────────────────────────────────── */
    .page-footer {
      margin-top: 24px;
      border-top: 1px solid #ccc;
      padding-top: 6px;
      font-size: 7.5pt;
      color: #999;
    }

    /* ── Print ───────────────────────────────────────── */
    @media print {
      body { padding: 8mm; }
      .cards-grid { grid-template-columns: repeat(2, 1fr); }
      @page { margin: 10mm; size: A4; }
    }
"""


def render_html(orders, sku_groups, batch_id, batch_type, host):
    """Assemble the full print-ready HTML document."""
    now = datetime.datetime.now()
    date_str = now.strftime('%d %B %Y')
    time_str = now.strftime('%H:%M')
    total_orders = len(orders)
    total_skus = len(sku_groups)
    total_units = sum(g['total_qty'] for g in sku_groups.values())

    type_labels = {
        'auto':            'Auto-batch',
        'time-limit':      'Time-limit batch',
        'morning':         'Morning batch',
        'manual':          'Manual — Next 25',
        'manual-selected': 'Manual — Selected orders',
    }
    type_label = type_labels.get(batch_type, batch_type.title())

    # ── Picklist section ──
    pick_html = ''
    for sku, group in sku_groups.items():
        pick_html += render_sku_section(sku, group)

    # ── QR / pack-station section ──
    cards_html = ''
    for order in orders:
        cards_html += render_order_card(order, host)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ArryBarry Pick List — Batch #{batch_id}</title>
  <style>{CSS}</style>
</head>
<body>

  <div class="page-hdr">
    <h1>ArryBarry Health &amp; Beauty &mdash; Pick List #{batch_id}</h1>
    <div class="hdr-meta">
      <span><strong>{date_str}</strong> &nbsp;{time_str}</span>
      <span>Type: <strong>{type_label}</strong></span>
      <span>Orders: <strong>{total_orders}</strong></span>
      <span>SKUs: <strong>{total_skus}</strong></span>
      <span>Units: <strong>{total_units}</strong></span>
    </div>
  </div>

  <h2>&#128230; Pick List <span class="section-sub">grouped by product &mdash; work top to bottom</span></h2>
  {pick_html}

  <div class="page-break"></div>

  <h2>&#127991; Pack Station <span class="section-sub">scan QR to open order in BaseLinker, then print label</span></h2>
  <div class="cards-grid">
    {cards_html}
  </div>

  <div class="page-footer">
    Batch #{batch_id} &bull; {type_label} &bull; Generated {now.strftime('%Y-%m-%d %H:%M:%S')} &bull; ArryBarry Health &amp; Beauty
  </div>

</body>
</html>"""


def vault_write(vault_url, api_key, path, content):
    """Write a markdown note to the Obsidian vault via REST API."""
    if not vault_url or not api_key:
        log('vault_write: VAULT_URL or OBSIDIAN_API_KEY not set — skipping vault write')
        return False
    url = f"{vault_url.rstrip('/')}/vault/{path}"
    req = urllib.request.Request(
        url,
        data=content.encode('utf-8'),
        method='PUT',
        headers={
            'Authorization': f'Bearer {api_key}',
            'Content-Type': 'text/markdown',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status in (200, 204):
                log(f'vault_write: {path} — OK')
                return True
    except urllib.error.HTTPError as e:
        log(f'vault_write: {path} — HTTP {e.code}')
    except Exception as e:
        log(f'vault_write: {path} — error: {e}')
    return False


def write_vault_summary(orders, sku_groups, batch_id, batch_type, html_path, vault_url, api_key):
    """Write a markdown batch-summary note to the Obsidian vault."""
    now = datetime.datetime.now()
    date_str = now.strftime('%Y-%m-%d')
    time_str = now.strftime('%H:%M')
    total_orders = len(orders)
    total_units = sum(g['total_qty'] for g in sku_groups.values())

    type_labels = {
        'auto':            'Auto-batch (25 orders)',
        'time-limit':      'Time-limit batch (1-hour fallback)',
        'morning':         'Morning batch (all overnight)',
        'manual':          'Manual — Next 25',
        'manual-selected': 'Manual — Selected orders',
    }
    type_label = type_labels.get(batch_type, batch_type)

    sku_rows = ''
    for sku, g in sku_groups.items():
        order_refs = ', '.join(f"#{e['order_id']}" for e in g['orders'])
        sku_rows += f'| `{sku}` | {g["name"]} | {g["total_qty"]} | {order_refs} |\n'

    order_list = '\n'.join(f'- Order #{o.get("order_id", "?")}' for o in orders)

    content = f"""---
source: picklist-ops
type: picklist-batch
batch_id: {batch_id}
batch_type: {batch_type}
date: {date_str}
time: {time_str}
orders: {total_orders}
units: {total_units}
html_path: {html_path}
status: printed
---

# Pick List Batch #{batch_id} — {date_str} {time_str}

**Type:** {type_label}
**Orders:** {total_orders}
**Total units:** {total_units}
**HTML file:** `{html_path}`

## Products Picked

| SKU | Product | Qty | Orders |
|-----|---------|-----|--------|
{sku_rows}
## Orders in Batch

{order_list}

---
*Auto-generated by picklist-ops at {now.strftime('%Y-%m-%dT%H:%M:%SZ')}*
"""

    filename = f"{now.strftime('%Y%m%d-%H%M%S')}-batch-{batch_id}.md"
    vault_path = f'07-Marketplace/Picklists/{filename}'
    vault_write(vault_url, api_key, vault_path, content)


def send_to_printer(html_path, print_cmd):
    """Send the HTML file to the configured printer command."""
    if not print_cmd:
        return
    # Construct the command safely — print_cmd is operator-configured, not user input
    full_cmd = f"{print_cmd} {html_path}"
    log(f'Sending to printer: {full_cmd}')
    try:
        result = subprocess.run(full_cmd, shell=True, capture_output=True, timeout=30)
        if result.returncode == 0:
            log('Picklist sent to printer successfully')
        else:
            log(f'Print command failed (exit {result.returncode}): {result.stderr.decode().strip()}')
    except subprocess.TimeoutExpired:
        log('Print command timed out after 30s')


def main():
    orders_json   = os.environ.get('PICKLIST_ORDERS', '[]')
    batch_id      = os.environ.get('PICKLIST_BATCH_ID', '0')
    batch_type    = os.environ.get('PICKLIST_BATCH_TYPE', 'auto')
    host          = os.environ.get('PICKLIST_HOST', 'http://localhost:3000')
    output_dir    = os.environ.get('PICKLIST_OUTPUT_DIR', '/opt/bigman-engine/picklists')
    print_cmd     = os.environ.get('PICKLIST_PRINT_CMD', '').strip()
    vault_url     = os.environ.get('VAULT_URL', '')
    api_key       = os.environ.get('OBSIDIAN_API_KEY', '')

    try:
        orders = json.loads(orders_json)
    except json.JSONDecodeError as e:
        log(f'Failed to parse PICKLIST_ORDERS JSON: {e}')
        sys.exit(1)

    if not orders:
        log('No orders supplied — nothing to generate')
        sys.exit(0)

    log(f'Batch #{batch_id}: {len(orders)} orders, type={batch_type}')

    sku_groups = build_sku_groups(orders)
    log(f'Grouped into {len(sku_groups)} unique SKUs')

    html = render_html(orders, sku_groups, batch_id, batch_type, host)

    os.makedirs(output_dir, exist_ok=True)
    now_str = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    filename = f'batch-{batch_id}-{now_str}.html'
    html_path = os.path.join(output_dir, filename)

    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html)

    log(f'Picklist saved: {html_path}')
    # Output path to stdout so run.sh can log it
    print(html_path)

    write_vault_summary(orders, sku_groups, batch_id, batch_type, html_path, vault_url, api_key)

    send_to_printer(html_path, print_cmd)


if __name__ == '__main__':
    main()
