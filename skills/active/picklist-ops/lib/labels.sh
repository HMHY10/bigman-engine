#!/usr/bin/env bash
# picklist-ops/lib/labels.sh — Shipping label fetch and auto-print from BaseLinker
# Requires: core.sh, marketplace-lib/baselinker.sh sourced first

# ── labels_process_batch <batch_id> ──────────────────────────────────────
# Main entry point called on scan-return.
# For each order in the batch: fetch existing packages → print labels.
# Updates BaseLinker order status and vault on completion.
labels_process_batch() {
  local batch_id="$1"

  log "labels_process_batch: processing ${batch_id}"

  local batch_json
  batch_json=$(picklist_batch_load "$batch_id") || {
    log "labels_process_batch: batch ${batch_id} not found"
    return 1
  }

  local status
  status=$(printf '%s' "$batch_json" | jq -r '.status // ""')
  if [[ "$status" == "picked" ]]; then
    log "labels_process_batch: ${batch_id} already marked as picked — skipping"
    return 0
  fi

  local order_ids
  order_ids=$(printf '%s' "$batch_json" | jq -r '.order_ids[]')
  local order_count
  order_count=$(printf '%s' "$batch_json" | jq '.order_ids | length')

  log "labels_process_batch: ${order_count} orders in batch"

  local printed=0
  local failed=0
  local no_package=0

  while IFS= read -r order_id; do
    [[ -z "$order_id" ]] && continue

    log "labels_process_batch: processing order ${order_id}"

    if labels_print_order_label "$order_id"; then
      printed=$(( printed + 1 ))
    else
      # Check if it failed due to no package vs print error
      local pkg_check
      pkg_check=$(bl_request "getOrderPackages" \
        "$(jq -n --argjson oid "$order_id" '{order_id: $oid}')" 2>/dev/null || echo '{}')
      local pkg_count
      pkg_count=$(printf '%s' "$pkg_check" | jq '.packages // [] | length')

      if (( pkg_count == 0 )); then
        log "labels_process_batch: order ${order_id} has no packages yet — skipping label"
        no_package=$(( no_package + 1 ))
      else
        failed=$(( failed + 1 ))
      fi
    fi

    # Update BaseLinker order status to "packing" (if configured)
    if [[ -n "${PICKLIST_PACKED_STATUS_ID:-}" ]]; then
      bl_request "setOrderStatus" \
        "$(jq -n \
          --argjson oid "$order_id" \
          --argjson sid "$PICKLIST_PACKED_STATUS_ID" \
          '{order_id: $oid, status_id: $sid}')" >/dev/null 2>&1 || \
        log "labels_process_batch: failed to update status for order ${order_id}"
    fi

  done <<< "$order_ids"

  # Mark batch as picked
  picklist_batch_update_status "$batch_id" "picked"

  # Write vault completion note
  labels_vault_completion "$batch_id" "$order_count" "$printed" "$no_package" "$failed"

  log "labels_process_batch: done — printed: ${printed}, no-package: ${no_package}, failed: ${failed}"
}

# ── labels_print_order_label <order_id> ──────────────────────────────────
# Fetch label for a single order and send to the label printer.
# Returns 0 on success, 1 on failure.
labels_print_order_label() {
  local order_id="$1"

  # Get packages for this order
  local packages_resp
  packages_resp=$(bl_request "getOrderPackages" \
    "$(jq -n --argjson oid "$order_id" '{order_id: $oid}')") || {
    log "labels_print_order_label: failed to get packages for ${order_id}"
    return 1
  }

  local pkg_count
  pkg_count=$(printf '%s' "$packages_resp" | jq '.packages // [] | length')

  if (( pkg_count == 0 )); then
    log "labels_print_order_label: no packages for order ${order_id}"
    return 1
  fi

  local success=0

  # Process each package (usually just one per order)
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue

    local courier_code package_id
    courier_code=$(printf '%s' "$pkg" | jq -r '.courier_code // ""')
    package_id=$(printf '%s' "$pkg" | jq -r '.package_id // ""')

    if [[ -z "$courier_code" || -z "$package_id" ]]; then
      log "labels_print_order_label: missing courier_code or package_id for order ${order_id}"
      continue
    fi

    log "labels_print_order_label: fetching label for order ${order_id} (courier: ${courier_code}, pkg: ${package_id})"

    # Fetch the label PDF/ZPL from BaseLinker
    local label_resp
    label_resp=$(bl_request "getLabel" \
      "$(jq -n \
        --arg cc "$courier_code" \
        --arg pid "$package_id" \
        '{courier_code: $cc, package_id: $pid}')") || {
      log "labels_print_order_label: getLabel failed for package ${package_id}"
      continue
    }

    # BaseLinker returns label as base64 in .label field, or a URL in .url
    local label_b64 label_url label_type
    label_b64=$(printf '%s' "$label_resp" | jq -r '.label // ""')
    label_url=$(printf '%s' "$label_resp" | jq -r '.url // ""')
    label_type=$(printf '%s' "$label_resp" | jq -r '.label_content_type // "application/pdf"')

    local label_file="${PICKLIST_PRINTS_DIR}/label-${order_id}-${package_id}"

    if [[ -n "$label_b64" && "$label_b64" != "null" ]]; then
      # Decode base64 label to file
      local ext="pdf"
      [[ "$label_type" == *"zpl"* ]] && ext="zpl"
      label_file="${label_file}.${ext}"
      printf '%s' "$label_b64" | base64 -d > "$label_file" 2>/dev/null || {
        log "labels_print_order_label: base64 decode failed for ${package_id}"
        continue
      }
      log "labels_print_order_label: decoded label to ${label_file}"

    elif [[ -n "$label_url" && "$label_url" != "null" ]]; then
      # Download label from URL
      label_file="${label_file}.pdf"
      curl -sS -o "$label_file" "$label_url" || {
        log "labels_print_order_label: download failed for ${label_url}"
        continue
      }
      log "labels_print_order_label: downloaded label to ${label_file}"

    else
      log "labels_print_order_label: no label data in response for ${package_id}"
      continue
    fi

    # Print the label
    if labels_cups_print_label "$label_file"; then
      success=$(( success + 1 ))
    fi

  done < <(printf '%s' "$packages_resp" | jq -c '.packages[]? // empty')

  (( success > 0 ))
}

# ── labels_cups_print_label <label_file> ─────────────────────────────────
# Send a label file to the configured CUPS label printer.
labels_cups_print_label() {
  local label_file="$1"

  if [[ -z "${LABEL_PRINTER_NAME:-}" ]]; then
    log "labels_cups_print_label: LABEL_PRINTER_NAME not set — label saved to ${label_file}"
    return 0  # Not a failure — label is saved for manual print
  fi

  if ! command -v lp &>/dev/null; then
    log "labels_cups_print_label: lp not available — label saved to ${label_file}"
    return 0
  fi

  local ext="${label_file##*.}"

  if [[ "$ext" == "zpl" ]]; then
    # ZPL: send raw to printer
    if command -v lpr &>/dev/null; then
      lpr -P "$LABEL_PRINTER_NAME" -o raw "$label_file" && \
        log "labels_cups_print_label: ZPL sent to ${LABEL_PRINTER_NAME}" && return 0
    else
      # Direct device write if lpr unavailable
      local printer_dev="/dev/usb/lp0"
      [[ -w "$printer_dev" ]] && cat "$label_file" > "$printer_dev" && \
        log "labels_cups_print_label: ZPL written to ${printer_dev}" && return 0
    fi
  else
    # PDF / other: standard lp
    lp -d "$LABEL_PRINTER_NAME" "$label_file" && \
      log "labels_cups_print_label: sent ${label_file} to ${LABEL_PRINTER_NAME}" && return 0
  fi

  log "labels_cups_print_label: WARN — could not print ${label_file}"
  return 1
}

# ── labels_vault_completion <batch_id> <total> <printed> <no_pkg> <failed> ─
# Write a vault note summarising the scan-return event.
labels_vault_completion() {
  local batch_id="$1"
  local total="$2"
  local printed="$3"
  local no_package="$4"
  local failed="$5"

  local ts date_str
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  date_str=$(date '+%Y-%m-%d')

  local printer_note=""
  if [[ -n "${LABEL_PRINTER_NAME:-}" ]]; then
    printer_note="Labels sent to printer: **${LABEL_PRINTER_NAME}**"
  else
    printer_note="No label printer configured — labels saved to state directory."
  fi

  local content
  content=$(cat <<MDEOF
---
source: picklist-ops
type: scan-return
batch_id: ${batch_id}
date: ${date_str}
scanned_at: ${ts}
total_orders: ${total}
labels_printed: ${printed}
no_package: ${no_package}
failed: ${failed}
---

# Scan Return: ${batch_id}

**Batch picked and scanned at:** ${ts}
**Total orders:** ${total}
**Labels printed:** ${printed}
**Orders without packages:** ${no_package}
**Label errors:** ${failed}

${printer_note}

$(if (( no_package > 0 )); then
  echo "### ⚠️ REVIEW NEEDED"
  echo "${no_package} order(s) had no courier packages yet. Please create packages in BaseLinker and print labels manually."
fi)

$(if (( failed > 0 )); then
  echo "### ⚠️ REVIEW NEEDED"
  echo "${failed} label(s) failed to print. Check printer connection and retry."
fi)

---
*Auto-generated by picklist-ops scan-return*
MDEOF
)

  vault_write "07-Marketplace/Warehouse/Scan-Returns/${date_str}-${batch_id}-return.md" "$content" || \
    log "labels_vault_completion: vault write failed"
}
