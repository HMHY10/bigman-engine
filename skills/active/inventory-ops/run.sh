#!/usr/bin/env bash
set -euo pipefail

# inventory-ops/run.sh — Inventory intelligence for marketplace operations
# Runs as: doppler run -p shared-services -c prd -- ./run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

# Source shared libraries
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

STATE_DIR="${STATE_BASE}/inventory-ops"
mkdir -p "$STATE_DIR"

log "=== inventory-ops: starting run ==="

# ══════════════════════════════════════════════════════════════════════
# PHASE 1: FETCH
# ══════════════════════════════════════════════════════════════════════

# ── 1a: Inventories ──────────────────────────────────────────────────
log "Fetching inventories..."
INVENTORIES_RAW=$(bl_request "getInventories" "{}" || printf '%s' '{"inventories":[]}')
[[ -z "$INVENTORIES_RAW" ]] && INVENTORIES_RAW='{"inventories":[]}'
INVENTORIES=$(printf '%s' "$INVENTORIES_RAW" | jq -c '.inventories // []')
INV_COUNT=$(printf '%s' "$INVENTORIES" | jq 'length')
log "Inventories found: ${INV_COUNT}"

# ── 1b: Stock & prices per inventory (paginated-safe) ────────────────
# Process one inventory at a time to avoid loading all 1000 products at once
STOCK_DATA="{}"
PRICE_DATA="{}"
PRODUCTS_WITH_STOCK=0
PRODUCTS_WITH_PRICES=0

while IFS= read -r inv; do
  [[ -z "$inv" ]] && continue

  inv_id=$(printf '%s' "$inv" | jq -r '.inventory_id')
  inv_name=$(printf '%s' "$inv" | jq -r '.name // "unnamed"')
  log "Fetching stock for inventory ${inv_id} (${inv_name})..."

  inv_stock_raw=$(bl_get_product_stock "$inv_id" || printf '%s' '{"products":{}}')
  [[ -z "$inv_stock_raw" ]] && inv_stock_raw='{"products":{}}'
  inv_stock=$(printf '%s' "$inv_stock_raw" | jq -c '.products // {}')
  inv_stock_count=$(printf '%s' "$inv_stock" | jq 'keys | length')
  PRODUCTS_WITH_STOCK=$((PRODUCTS_WITH_STOCK + inv_stock_count))
  log "  Stock entries: ${inv_stock_count}"

  # Merge into aggregate (keyed by inventory_id)
  STOCK_DATA=$(printf '%s' "$STOCK_DATA" | jq --arg id "$inv_id" --argjson data "$inv_stock" \
    '. + {($id): $data}')

  log "Fetching prices for inventory ${inv_id} (${inv_name})..."
  inv_prices_raw=$(bl_get_product_prices "$inv_id" || printf '%s' '{"products":{}}')
  [[ -z "$inv_prices_raw" ]] && inv_prices_raw='{"products":{}}'
  inv_prices=$(printf '%s' "$inv_prices_raw" | jq -c '.products // {}')
  inv_price_count=$(printf '%s' "$inv_prices" | jq 'keys | length')
  PRODUCTS_WITH_PRICES=$((PRODUCTS_WITH_PRICES + inv_price_count))
  log "  Price entries: ${inv_price_count}"

  PRICE_DATA=$(printf '%s' "$PRICE_DATA" | jq --arg id "$inv_id" --argjson data "$inv_prices" \
    '. + {($id): $data}')

  # Cache per-inventory data for other skills
  cache_write "inventory-stock" "$inv_id" "$inv_stock"
  cache_write "inventory-prices" "$inv_id" "$inv_prices"

done < <(printf '%s' "$INVENTORIES" | jq -c '.[]')

log "Total products with stock: ${PRODUCTS_WITH_STOCK}"
log "Total products with prices: ${PRODUCTS_WITH_PRICES}"

# ── 1c: External storages ───────────────────────────────────────────
log "Fetching external storages..."
EXT_RAW=$(bl_get_external_storages || printf '%s' '{"storages":[]}')
[[ -z "$EXT_RAW" ]] && EXT_RAW='{"storages":[]}'
EXT_STORAGES=$(printf '%s' "$EXT_RAW" | jq -c '.storages // []')
EXT_COUNT=$(printf '%s' "$EXT_STORAGES" | jq 'length')
log "External storages: ${EXT_COUNT}"

# ── 1d: Purchase orders ─────────────────────────────────────────────
log "Fetching purchase orders..."
POS_RAW=$(bl_get_purchase_orders || printf '%s' '{"purchase_orders":[]}')
[[ -z "$POS_RAW" ]] && POS_RAW='{"purchase_orders":[]}'
POS=$(printf '%s' "$POS_RAW" | jq -c '.purchase_orders // .orders // []')
PO_COUNT=$(printf '%s' "$POS" | jq 'length')
log "Purchase orders: ${PO_COUNT}"

# ── 1e: Inventory documents (goods-in) ──────────────────────────────
log "Fetching inventory documents..."
DOCS_RAW=$(bl_get_inventory_documents || printf '%s' '{"documents":[]}')
[[ -z "$DOCS_RAW" ]] && DOCS_RAW='{"documents":[]}'
DOCS=$(printf '%s' "$DOCS_RAW" | jq -c '.documents // []')
DOC_COUNT=$(printf '%s' "$DOCS" | jq 'length')
log "Inventory documents: ${DOC_COUNT}"

# ══════════════════════════════════════════════════════════════════════
# PHASE 2: ANALYSE
# ══════════════════════════════════════════════════════════════════════

log "Starting analysis..."

# ── 2a: Booking-in Reconciliation ────────────────────────────────────
# For each non-draft/non-cancelled PO, find matching goods-in documents.
# Fetch PO items individually. Flag: short delivery, late delivery, unmatched receipt.
log "Analysing booking-in reconciliation..."

BOOKING_UNMATCHED=0

read -r BOOKING_ALERT_COUNT BOOKING_SHORT BOOKING_LATE <<< "$(bl_check_po_delivery "$POS" "$DOCS" "Inventory/Alerts")"

# Case 3: Unmatched receipt — goods-in doc with no matching PO
while IFS= read -r doc; do
  [[ -z "$doc" ]] && continue

  doc_id=$(printf '%s' "$doc" | jq -r '.document_id // .id')
  doc_po_id=$(printf '%s' "$doc" | jq -r '.purchase_order_id // "null"')

  # Skip documents that reference a PO (they were handled above)
  if [[ "$doc_po_id" != "null" && "$doc_po_id" != "0" && -n "$doc_po_id" ]]; then
    # Check the PO actually exists in our list
    po_exists=$(printf '%s' "$POS" | jq --arg poid "$doc_po_id" \
      '[.[] | select((.purchase_order_id // .id | tostring) == $poid)] | length')
    if (( po_exists > 0 )); then
      continue
    fi
  fi

  # This goods-in document has no matching PO
  doc_date=$(printf '%s' "$doc" | jq -r '.date // .date_add // "unknown"')

  alert_create "info" "baselinker" "Inventory/Alerts" \
    "Unmatched Receipt Doc ${doc_id}" \
    "**Document ID:** ${doc_id}
**Date:** ${doc_date}
**Referenced PO:** ${doc_po_id}

Goods-in document found with no matching purchase order. Stock received without PO trail — verify supplier delivery."

  BOOKING_UNMATCHED=$((BOOKING_UNMATCHED + 1))
  BOOKING_ALERT_COUNT=$((BOOKING_ALERT_COUNT + 1))

done < <(printf '%s' "$DOCS" | jq -c '.[]')

log "Booking-in reconciliation complete: ${BOOKING_ALERT_COUNT} alerts (short: ${BOOKING_SHORT}, late: ${BOOKING_LATE}, unmatched: ${BOOKING_UNMATCHED})"

# ── 2b: Cross-channel Pricing Report ────────────────────────────────
log "Generating cross-channel pricing report..."
DATE_STR=$(date '+%Y-%m-%d')

# Build inventory summary table rows
INV_TABLE_ROWS=""
while IFS= read -r inv; do
  [[ -z "$inv" ]] && continue
  inv_id=$(printf '%s' "$inv" | jq -r '.inventory_id')
  inv_name=$(printf '%s' "$inv" | jq -r '.name // "unnamed"')
  inv_stock_count=$(printf '%s' "$STOCK_DATA" | jq --arg id "$inv_id" '.[$id] // {} | keys | length')
  inv_price_count=$(printf '%s' "$PRICE_DATA" | jq --arg id "$inv_id" '.[$id] // {} | keys | length')
  INV_TABLE_ROWS="${INV_TABLE_ROWS}| ${inv_name} | ${inv_id} | ${inv_stock_count} | ${inv_price_count} |
"
done < <(printf '%s' "$INVENTORIES" | jq -c '.[]')

# Build external storage summary
EXT_TABLE_ROWS=""
while IFS= read -r ext; do
  [[ -z "$ext" ]] && continue
  ext_id=$(printf '%s' "$ext" | jq -r '.storage_id')
  ext_name=$(printf '%s' "$ext" | jq -r '.name // "unnamed"')
  ext_type=$(printf '%s' "$ext" | jq -r '.type // "unknown"')
  EXT_TABLE_ROWS="${EXT_TABLE_ROWS}| ${ext_name} | ${ext_id} | ${ext_type} |
"
done < <(printf '%s' "$EXT_STORAGES" | jq -c '.[]')

PRICING_CONTENT="---
source: inventory-ops
type: pricing-report
date: ${DATE_STR}
severity: info
status: report
inventories: ${INV_COUNT}
products_with_stock: ${PRODUCTS_WITH_STOCK}
products_with_prices: ${PRODUCTS_WITH_PRICES}
external_storages: ${EXT_COUNT}
---

# Pricing & Inventory Overview - ${DATE_STR}

## Summary

- **Inventories:** ${INV_COUNT}
- **Products with stock data:** ${PRODUCTS_WITH_STOCK}
- **Products with price data:** ${PRODUCTS_WITH_PRICES}
- **External storages:** ${EXT_COUNT}

## Inventory Breakdown

| Inventory | ID | Products (Stock) | Products (Prices) |
|-----------|-----|-----------------|-------------------|
${INV_TABLE_ROWS}
## External Storages

| Storage | ID | Type |
|---------|-----|------|
${EXT_TABLE_ROWS}
---
*Auto-generated by inventory-ops at $(date -u '+%Y-%m-%d %H:%M:%S UTC')*"

PRICING_PATH="07-Marketplace/Inventory/Reports/${DATE_STR}-pricing.md"
vault_write "$PRICING_PATH" "$PRICING_CONTENT" || log "Pricing report write failed"

# ── 2c: Listing Health ────────────────────────────────────────────────
# Check which inventory products are linked to at least one external storage
# via the "links" field in product data (not by comparing IDs directly).
log "Analysing listing health..."

LISTING_ALERT_COUNT=0
UNLISTED_COUNT=0
BL_PRODUCT_TOTAL=0
LISTED_TOTAL=0

while IFS= read -r inv; do
  [[ -z "$inv" ]] && continue

  inv_id=$(printf '%s' "$inv" | jq -r '.inventory_id')
  inv_name=$(printf '%s' "$inv" | jq -r '.name // "unnamed"')

  # Get all product IDs for this inventory from stock data
  product_ids=$(printf '%s' "$STOCK_DATA" | jq -r --arg id "$inv_id" '.[$id] // {} | keys[]')
  pid_count=$(printf '%s' "$product_ids" | grep -c . || echo 0)
  BL_PRODUCT_TOTAL=$((BL_PRODUCT_TOTAL + pid_count))

  if (( pid_count == 0 )); then
    log "  ${inv_name}: no products, skipping"
    continue
  fi

  log "  ${inv_name}: checking links for ${pid_count} products..."

  # Batch product IDs into groups of 100 for getInventoryProductsData
  inv_unlisted=0
  inv_listed=0
  batch_ids=""
  batch_count=0

  _flush_batch() {
    local batch_result
    batch_result=$(bl_request "getInventoryProductsData" \
      "{\"inventory_id\": ${inv_id}, \"products\": [${batch_ids}]}" 2>/dev/null || printf '%s' '{"products":{}}')
    [[ -z "$batch_result" ]] && batch_result='{"products":{}}'
    inv_listed=$((inv_listed + $(printf '%s' "$batch_result" | jq '[.products // {} | to_entries[] | select(.value.links // {} | length > 0)] | length')))
    inv_unlisted=$((inv_unlisted + $(printf '%s' "$batch_result" | jq '[.products // {} | to_entries[] | select(.value.links // {} | length == 0)] | length')))
    batch_ids=""
    batch_count=0
  }

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if [[ -n "$batch_ids" ]]; then
      batch_ids="${batch_ids},${pid}"
    else
      batch_ids="${pid}"
    fi
    batch_count=$((batch_count + 1))
    (( batch_count >= 100 )) && _flush_batch
  done <<< "$product_ids"

  # Process remaining batch
  (( batch_count > 0 )) && _flush_batch

  LISTED_TOTAL=$((LISTED_TOTAL + inv_listed))
  UNLISTED_COUNT=$((UNLISTED_COUNT + inv_unlisted))
  log "  ${inv_name}: ${inv_listed} listed, ${inv_unlisted} unlisted"

done < <(printf '%s' "$INVENTORIES" | jq -c '.[]')

log "Listing health totals: ${LISTED_TOTAL} listed, ${UNLISTED_COUNT} unlisted out of ${BL_PRODUCT_TOTAL}"

if (( UNLISTED_COUNT > 0 )); then
  alert_create "info" "baselinker" "Inventory/Alerts" \
    "Unlisted Products Detected" \
    "**Products in BaseLinker inventory:** ${BL_PRODUCT_TOTAL}
**Products linked to storefront:** ${LISTED_TOTAL}
**Products with no storefront link:** ${UNLISTED_COUNT}

${UNLISTED_COUNT} product(s) exist in BaseLinker inventory but have no links to any external storefront. Review for potential missing listings or delisted products."

  LISTING_ALERT_COUNT=$((LISTING_ALERT_COUNT + 1))
fi

log "Listing health complete: ${UNLISTED_COUNT} unlisted products, ${LISTING_ALERT_COUNT} alerts"

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════

TOTAL_ALERTS=$((BOOKING_ALERT_COUNT + LISTING_ALERT_COUNT))

log "=== inventory-ops: run complete ==="
log "  Inventories: ${INV_COUNT} | Products (stock): ${PRODUCTS_WITH_STOCK} | Products (prices): ${PRODUCTS_WITH_PRICES}"
log "  External storages: ${EXT_COUNT} | POs: ${PO_COUNT} | Goods-in docs: ${DOC_COUNT}"
log "  Booking-in alerts: ${BOOKING_ALERT_COUNT} (short: ${BOOKING_SHORT}, late: ${BOOKING_LATE}, unmatched: ${BOOKING_UNMATCHED})"
log "  Listing health: ${UNLISTED_COUNT} unlisted products"
log "  Total alerts: ${TOTAL_ALERTS}"
