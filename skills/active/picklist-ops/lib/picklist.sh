#!/usr/bin/env bash
# picklist-ops/lib/picklist.sh — HTML picklist generation
# Requires: core.sh sourced first

# ── picklist_generate_html <batch_id> <mode> <orders_json> <sku_groups_json> ──
# Generate a printable HTML picklist file and save to the prints directory.
# Returns the output file path via stdout.
#
# Args:
#   batch_id     — e.g. PL-20260704-001
#   mode         — "overnight" | "daytime" | "manual"
#   orders_json  — full JSON array of order objects
#   sku_groups   — JSON array from picklist_build_sku_groups
picklist_generate_html() {
  local batch_id="$1"
  local mode="$2"
  local orders_json="$3"
  local sku_groups="$4"

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M')

  local order_count item_count sku_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')
  item_count=$(printf '%s' "$sku_groups" | jq '[.[].quantity] | add // 0')
  sku_count=$(printf '%s' "$sku_groups" | jq 'length')

  local mode_label
  case "$mode" in
    overnight) mode_label="Overnight Batch" ;;
    daytime)   mode_label="Daytime Batch" ;;
    manual)    mode_label="Manual Batch" ;;
    *)         mode_label="Batch" ;;
  esac

  # Build the SKU rows HTML
  local rows_html=""
  while IFS= read -r group; do
    [[ -z "$group" ]] && continue

    local sku name ean location quantity order_ids_str
    sku=$(printf '%s' "$group" | jq -r '.sku // ""')
    name=$(printf '%s' "$group" | jq -r '.name // "Unknown Product"')
    ean=$(printf '%s' "$group" | jq -r '.ean // ""')
    location=$(printf '%s' "$group" | jq -r '.location // ""')
    quantity=$(printf '%s' "$group" | jq -r '.quantity // 0')
    order_ids_str=$(printf '%s' "$group" | jq -r '.order_ids | unique | join(", ")')

    local bin_display="${location:-—}"
    local ean_display=""
    [[ -n "$ean" && "$ean" != "$sku" ]] && ean_display="<br><small style='color:#888'>EAN: ${ean}</small>"

    rows_html="${rows_html}
      <tr>
        <td class=\"bin-cell\">${bin_display}</td>
        <td>${sku}${ean_display}</td>
        <td>${name}</td>
        <td class=\"qty-cell\">${quantity}</td>
        <td class=\"order-list\">${order_ids_str}</td>
      </tr>"
  done < <(printf '%s' "$sku_groups" | jq -c '.[]')

  # Generate the HTML document
  local html
  html=$(cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Picklist ${batch_id}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: Arial, Helvetica, sans-serif;
      font-size: 11pt;
      color: #000;
      background: #fff;
      padding: 12px 16px;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      padding-bottom: 12px;
      border-bottom: 3px solid #1a1a1a;
      margin-bottom: 14px;
      gap: 16px;
    }
    .header-left h1 {
      font-size: 20pt;
      font-weight: bold;
      letter-spacing: -0.5px;
    }
    .header-left .meta {
      margin-top: 6px;
      font-size: 10pt;
      color: #444;
    }
    .stats {
      display: flex;
      gap: 20px;
      margin-top: 10px;
    }
    .stat { text-align: center; }
    .stat .num {
      font-size: 22pt;
      font-weight: bold;
      color: #1a1a1a;
      line-height: 1;
    }
    .stat .lbl {
      font-size: 8pt;
      color: #666;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .header-right { flex-shrink: 0; text-align: center; }
    .header-right .batch-label {
      font-family: monospace;
      font-size: 9pt;
      margin-top: 4px;
      color: #333;
    }
    table {
      width: 100%;
      border-collapse: collapse;
    }
    th {
      background: #1a1a1a;
      color: #fff;
      padding: 7px 10px;
      text-align: left;
      font-size: 10pt;
      font-weight: bold;
    }
    td {
      padding: 6px 10px;
      border-bottom: 1px solid #e0e0e0;
      vertical-align: top;
      font-size: 10pt;
    }
    tr:nth-child(even) td { background: #f9f9f9; }
    tr:hover td { background: #fff3cd; }
    .bin-cell {
      font-family: monospace;
      font-size: 14pt;
      font-weight: bold;
      color: #c00;
      white-space: nowrap;
    }
    .qty-cell {
      font-size: 16pt;
      font-weight: bold;
      text-align: center;
      color: #1a1a1a;
    }
    .order-list {
      font-size: 8.5pt;
      color: #555;
      max-width: 240px;
    }
    .footer {
      margin-top: 16px;
      padding-top: 8px;
      border-top: 1px solid #ccc;
      font-size: 8.5pt;
      color: #777;
      text-align: center;
    }
    .no-bin { color: #aaa; font-style: italic; }
    @media print {
      body { padding: 0; }
      .no-print { display: none !important; }
      tr:hover td { background: inherit; }
      @page {
        size: A4 portrait;
        margin: 10mm 12mm;
      }
    }
  </style>
</head>
<body>

  <div class="header">
    <div class="header-left">
      <h1>Picklist #${batch_id}</h1>
      <div class="meta">
        <strong>${mode_label}</strong> &nbsp;|&nbsp; Generated: ${timestamp}
      </div>
      <div class="stats">
        <div class="stat">
          <div class="num">${order_count}</div>
          <div class="lbl">Orders</div>
        </div>
        <div class="stat">
          <div class="num">${item_count}</div>
          <div class="lbl">Items</div>
        </div>
        <div class="stat">
          <div class="num">${sku_count}</div>
          <div class="lbl">SKUs</div>
        </div>
      </div>
    </div>
    <div class="header-right">
      <div id="qrcode"></div>
      <div class="batch-label">${batch_id}</div>
    </div>
  </div>

  <table>
    <thead>
      <tr>
        <th style="width:90px">Bin / Location</th>
        <th style="width:130px">SKU / EAN</th>
        <th>Product Name</th>
        <th style="width:55px; text-align:center">Qty</th>
        <th>Order IDs</th>
      </tr>
    </thead>
    <tbody>
${rows_html}
    </tbody>
  </table>

  <div class="footer">
    Picklist ${batch_id} &nbsp;&bull;&nbsp; ArryBarry Health &amp; Beauty &nbsp;&bull;&nbsp;
    Scan QR code on return to auto-print shipping labels
    &nbsp;&bull;&nbsp; ${timestamp}
  </div>

  <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"
          integrity="sha512-CNgIRecGo7nphbeZ04Sc13ka07paqdeTu0WR1IM4kNcpmBAUSHSe1V6rkhBGEgsEHQBbwQQFM9eaBT/C5qWMJw=="
          crossorigin="anonymous" referrerpolicy="no-referrer"></script>
  <script>
    try {
      new QRCode(document.getElementById("qrcode"), {
        text: "${batch_id}",
        width: 110,
        height: 110,
        colorDark: "#000000",
        colorLight: "#ffffff",
        correctLevel: QRCode.CorrectLevel.M
      });
    } catch (e) {
      document.getElementById("qrcode").innerHTML =
        '<div style="width:110px;height:110px;border:2px solid #ccc;display:flex;' +
        'align-items:center;justify-content:center;font-size:8pt;color:#999">' +
        'QR offline</div>';
    }
  </script>
</body>
</html>
HTML
)

  local out_file="${PICKLIST_PRINTS_DIR}/${batch_id}.html"
  printf '%s' "$html" > "$out_file"
  log "picklist_generate_html: written to ${out_file}"
  printf '%s' "$out_file"
}

# ── picklist_build_batch_json <batch_id> <mode> <order_ids_newline_sep> ───
# Construct the batch metadata JSON object.
picklist_build_batch_json() {
  local batch_id="$1"
  local mode="$2"
  local order_ids="$3"  # whitespace/newline-separated

  local ids_array
  ids_array=$(printf '%s' "$order_ids" | tr ' \n' '\n' | grep -v '^$' | jq -R . | jq -s .)

  jq -n \
    --arg id "$batch_id" \
    --arg mode "$mode" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson ids "$ids_array" \
    '{
      batch_id: $id,
      mode: $mode,
      created_at: $ts,
      status: "generated",
      order_ids: $ids,
      order_count: ($ids | length)
    }'
}
