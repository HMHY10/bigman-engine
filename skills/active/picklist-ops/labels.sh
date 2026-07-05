#!/usr/bin/env bash
# picklist-ops/labels.sh — Shipping label auto-print via BaseLinker
# Requires: config.sh, baselinker.sh, state.sh sourced first
#
# Functions:
#   labels_get_package_ids <order_ids_json>  — resolve BaseLinker package IDs for orders
#   labels_print_for_picklist <pl_id>        — auto-print all labels for a completed picklist

# ── labels_get_package_ids <order_ids_json> ───────────────────────────
# Given a JSON array of order_ids, return a JSON array of package_ids by
# fetching order details from BaseLinker and extracting linked packages.
# Falls back to creating packages if none exist (only if PICKLIST_COURIER_ID set).
labels_get_package_ids() {
  local order_ids="$1"
  local all_package_ids="[]"
  local orders_needing_packages="[]"

  log "labels_get_package_ids: resolving packages for $(printf '%s' "$order_ids" | jq 'length') orders"

  while IFS= read -r oid; do
    [[ -z "$oid" ]] && continue

    local params
    params=$(jq -n --argjson oid "$oid" '{order_id: $oid}')
    local result
    result=$(bl_request "getOrderPackages" "$params" 2>/dev/null || printf '%s' '{"packages":[]}')
    [[ -z "$result" ]] && result='{"packages":[]}'

    local packages package_count
    packages=$(printf '%s' "$result" | jq -c '.packages // []')
    package_count=$(printf '%s' "$packages" | jq 'length')

    if (( package_count > 0 )); then
      local pkg_ids
      pkg_ids=$(printf '%s' "$packages" | jq '[.[].package_id]')
      all_package_ids=$(printf '%s\n%s' "$all_package_ids" "$pkg_ids" | jq -s 'add')
      log "labels_get_package_ids: order ${oid} has ${package_count} package(s)"
    else
      log "labels_get_package_ids: order ${oid} has no packages — flagging for creation"
      orders_needing_packages=$(printf '%s' "$orders_needing_packages" | jq --argjson oid "$oid" '. + [$oid]')
    fi
  done < <(printf '%s' "$order_ids" | jq -r '.[]')

  # Create packages for orders that have none, if courier is configured
  if [[ -n "${PICKLIST_COURIER_ID:-}" ]]; then
    local needs_count
    needs_count=$(printf '%s' "$orders_needing_packages" | jq 'length')
    if (( needs_count > 0 )); then
      log "labels_get_package_ids: creating packages for ${needs_count} orders via courier ${PICKLIST_COURIER_ID}"
      while IFS= read -r oid; do
        [[ -z "$oid" ]] && continue

        local create_params
        create_params=$(jq -n \
          --argjson oid "$oid" \
          --arg courier "${PICKLIST_COURIER_ID}" \
          '{order_id: $oid, courier_code: $courier}')

        local create_result
        create_result=$(bl_request "createPackage" "$create_params" 2>/dev/null || printf '{}')
        local new_pkg_id
        new_pkg_id=$(printf '%s' "$create_result" | jq -r '.package_id // empty')

        if [[ -n "$new_pkg_id" ]]; then
          all_package_ids=$(printf '%s' "$all_package_ids" | jq --argjson pid "$new_pkg_id" '. + [$pid]')
          log "labels_get_package_ids: created package ${new_pkg_id} for order ${oid}"
        else
          log "labels_get_package_ids: failed to create package for order ${oid}"
        fi
      done < <(printf '%s' "$orders_needing_packages" | jq -r '.[]')
    fi
  else
    local needs_count
    needs_count=$(printf '%s' "$orders_needing_packages" | jq 'length')
    if (( needs_count > 0 )); then
      log "labels_get_package_ids: ${needs_count} orders have no packages — set PICKLIST_COURIER_ID to auto-create"
    fi
  fi

  local total
  total=$(printf '%s' "$all_package_ids" | jq 'length')
  log "labels_get_package_ids: resolved ${total} package IDs total"
  printf '%s' "$all_package_ids"
}

# ── labels_print_for_picklist <pl_id> ────────────────────────────────
# Called when a picker returns and scans the picklist QR code.
# 1. Looks up all order IDs for the picklist
# 2. Resolves BaseLinker package IDs for those orders
# 3. Calls printCourierLabel for all packages
# 4. Marks picklist as completed in state
labels_print_for_picklist() {
  local pl_id="$1"

  log "labels_print_for_picklist: processing ${pl_id}"

  # Get picklist state
  local pl_state
  pl_state=$(state_get_picklist "$pl_id") || {
    log "labels_print_for_picklist: picklist ${pl_id} not found in state"
    return 1
  }

  local pl_status
  pl_status=$(printf '%s' "$pl_state" | jq -r '.status')

  if [[ "$pl_status" == "completed" ]]; then
    log "labels_print_for_picklist: ${pl_id} already completed — skipping"
    return 0
  fi

  # Get order IDs
  local order_ids
  order_ids=$(state_get_order_ids_for_picklist "$pl_id") || return 1
  local order_count
  order_count=$(printf '%s' "$order_ids" | jq 'length')
  log "labels_print_for_picklist: ${pl_id} has ${order_count} orders"

  if (( order_count == 0 )); then
    log "labels_print_for_picklist: no orders in ${pl_id}"
    return 1
  fi

  # Resolve package IDs
  local package_ids
  package_ids=$(labels_get_package_ids "$order_ids")
  local pkg_count
  pkg_count=$(printf '%s' "$package_ids" | jq 'length')

  if (( pkg_count == 0 )); then
    log "labels_print_for_picklist: no packages found for ${pl_id} — labels cannot be printed"
    return 1
  fi

  log "labels_print_for_picklist: printing ${pkg_count} labels for ${pl_id}"

  # Build print params
  local print_params
  print_params=$(jq -n --argjson ids "$package_ids" '{package_ids: $ids}')

  # Include printer ID if configured (BaseLinker printer_id for label printer)
  if [[ -n "${PICKLIST_LABEL_PRINTER_ID:-}" ]]; then
    print_params=$(printf '%s' "$print_params" | jq \
      --argjson printer_id "${PICKLIST_LABEL_PRINTER_ID}" \
      '. + {printer_id: $printer_id}')
  fi

  local print_result
  print_result=$(bl_request "printCourierLabel" "$print_params") || {
    log "labels_print_for_picklist: BaseLinker printCourierLabel failed for ${pl_id}"
    return 1
  }

  log "labels_print_for_picklist: labels sent to printer for ${pl_id} (${pkg_count} packages)"

  # Mark picklist completed
  state_mark_completed "$pl_id"

  # Write vault note for audit trail
  local order_count_real
  order_count_real=$(printf '%s' "$order_ids" | jq 'length')
  local completed_at
  completed_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  local date_str
  date_str=$(date '+%Y-%m-%d')

  vault_write "07-Marketplace/Warehouse/Picklists/${date_str}-${pl_id}-completed.md" \
"---
source: picklist-ops
type: picklist-completed
picklist_id: ${pl_id}
date: ${date_str}
status: completed
orders: ${order_count_real}
packages_printed: ${pkg_count}
---

# Picklist Completed — ${pl_id}

**Picklist ID:** ${pl_id}
**Orders:** ${order_count_real}
**Labels printed:** ${pkg_count}
**Completed at:** ${completed_at}

Picker scanned picklist QR on return. Shipping labels auto-printed via BaseLinker.
" || log "labels_print_for_picklist: vault write failed (non-fatal)"

  return 0
}
