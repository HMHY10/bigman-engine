#!/usr/bin/env bash
# picklist-ops/print.sh — Print helpers for picklist and label output
# Requires: config.sh sourced first

# ── print_picklist <html_file> [printer_name] ─────────────────────────
# Convert HTML to PDF and send to the picklist printer.
# Falls back to direct lp if wkhtmltopdf/chromium are unavailable.
print_picklist() {
  local html_file="$1"
  local printer="${2:-${PICKLIST_PRINTER:-}}"

  if [[ ! -f "$html_file" ]]; then
    log "print: HTML file not found: ${html_file}"
    return 1
  fi

  if [[ -z "$printer" ]]; then
    log "print: PICKLIST_PRINTER not set — saving HTML only (${html_file})"
    return 0
  fi

  local pdf_file="${html_file%.html}.pdf"

  # Try wkhtmltopdf first (best quality for HTML)
  if command -v wkhtmltopdf >/dev/null 2>&1; then
    log "print: converting with wkhtmltopdf"
    wkhtmltopdf \
      --page-size A4 \
      --orientation Portrait \
      --margin-top 5mm \
      --margin-bottom 5mm \
      --margin-left 8mm \
      --margin-right 8mm \
      --quiet \
      "$html_file" "$pdf_file" 2>/dev/null
    if [[ -f "$pdf_file" ]]; then
      _lp_print "$pdf_file" "$printer"
      return $?
    fi
  fi

  # Try chromium headless (second choice)
  local chromium_bin
  chromium_bin=$(command -v chromium-browser || command -v chromium || command -v google-chrome 2>/dev/null || true)
  if [[ -n "$chromium_bin" ]]; then
    log "print: converting with chromium headless"
    "$chromium_bin" \
      --headless \
      --disable-gpu \
      --no-sandbox \
      --print-to-pdf="$pdf_file" \
      --print-to-pdf-no-header \
      "file://${html_file}" 2>/dev/null
    if [[ -f "$pdf_file" ]]; then
      _lp_print "$pdf_file" "$printer"
      return $?
    fi
  fi

  # Last resort: send HTML directly to lp (works for PostScript-capable printers)
  log "print: no PDF converter found — sending HTML directly to lp"
  _lp_print "$html_file" "$printer"
}

# ── _lp_print <file> <printer> ────────────────────────────────────────
# Send a file to a CUPS printer.
_lp_print() {
  local file="$1" printer="$2"

  if ! command -v lp >/dev/null 2>&1; then
    log "print: lp not available — file saved at ${file}"
    return 0
  fi

  log "print: sending ${file} to printer '${printer}'"
  if lp -d "$printer" -o media=A4 "$file" 2>&1 | while IFS= read -r line; do log "  lp: ${line}"; done; then
    log "print: job submitted to ${printer}"
    return 0
  else
    log "print: lp submission failed for ${printer}"
    return 1
  fi
}

# ── print_label_baselinker <order_id> [printer_name] ─────────────────
# Fetch a BaseLinker shipping label for an order and send to label printer.
# Requires: BASELINKER_API_TOKEN in environment.
print_label_baselinker() {
  local order_id="$1"
  local printer="${2:-${LABEL_PRINTER:-${PICKLIST_PRINTER:-}}}"

  log "print_label: fetching label for order ${order_id}"

  # First, get the order to find its package ID
  local order_json
  order_json=$(bl_request "getOrders" "$(jq -n --argjson oid "$order_id" '{order_id: $oid}')") || {
    log "print_label: failed to fetch order ${order_id}"
    return 1
  }

  # Extract existing package IDs if any
  local package_ids
  package_ids=$(printf '%s' "$order_json" | jq -r \
    '.orders // [] | .[0] | .packages // [] | .[].package_id // empty' 2>/dev/null | head -1)

  if [[ -z "$package_ids" ]]; then
    # No package yet — courier integration may be needed. Log and return.
    log "print_label: order ${order_id} has no package yet — label cannot be fetched (book courier first)"
    return 1
  fi

  # Fetch label PDF via BaseLinker
  local label_response
  local params
  params=$(jq -n --argjson pid "$package_ids" '{package_id: $pid}')
  label_response=$(bl_request "getLabel" "$params") || {
    log "print_label: getLabel failed for package ${package_ids}"
    return 1
  }

  # Check for base64-encoded PDF label
  local label_b64
  label_b64=$(printf '%s' "$label_response" | jq -r '.label // empty')

  if [[ -z "$label_b64" ]]; then
    log "print_label: no label data returned for order ${order_id}"
    return 1
  fi

  local tmp_pdf
  tmp_pdf=$(mktemp /tmp/label-XXXXXX.pdf)
  printf '%s' "$label_b64" | base64 -d > "$tmp_pdf" 2>/dev/null

  if [[ ! -s "$tmp_pdf" ]]; then
    log "print_label: label decode failed for order ${order_id}"
    rm -f "$tmp_pdf"
    return 1
  fi

  log "print_label: label PDF ready ($(wc -c < "$tmp_pdf") bytes)"

  if [[ -n "$printer" ]]; then
    _lp_print "$tmp_pdf" "$printer"
  else
    log "print_label: LABEL_PRINTER not set — label saved at ${tmp_pdf}"
    return 0
  fi

  rm -f "$tmp_pdf"
}
