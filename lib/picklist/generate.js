/**
 * Picklist generation logic.
 *
 * Batching strategies:
 *   overnight — all pending orders, no cap, grouped by SKU (run before warehouse opens)
 *   realtime  — soft cap of BATCH_SIZE orders; include all lines for any SKU that straddles the cap
 *   manual    — caller supplies explicit order IDs
 *
 * The realtime strategy is used by the daytime cron (every 30s) which fires when:
 *   - there are >= BATCH_SIZE pending orders, OR
 *   - the oldest pending order is >= BATCH_TIMEOUT_MS old (time-limit fallback)
 */

import {
  getPendingOrders,
  getPendingOrderCount,
  getOldestPendingOrderAge,
  createPicklistFromOrders,
} from '../db/picklists.js';

const BATCH_SIZE = 25;
const BATCH_TIMEOUT_MS = 25 * 1000; // 25 seconds

/**
 * Group orders by SKU, preserving order within each SKU by createdAt.
 * Returns array of { sku, orders[] } sorted by SKU.
 */
function groupBySku(orders) {
  const map = new Map();
  for (const o of orders) {
    if (!map.has(o.sku)) map.set(o.sku, []);
    map.get(o.sku).push(o);
  }
  return Array.from(map.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([sku, skuOrders]) => ({ sku, orders: skuOrders }));
}

/**
 * Generate the overnight picklist from all pending orders.
 * No cap — all overnight orders go into one picklist, sorted by SKU.
 * Returns the created picklist or null if no pending orders.
 */
export function generateOvernightPicklist() {
  const pending = getPendingOrders();
  if (!pending.length) return null;

  const ids = pending.map((o) => o.id);
  return createPicklistFromOrders(ids, 'overnight', `Overnight batch — ${pending.length} orders`);
}

/**
 * Generate a realtime (daytime) picklist batch.
 *
 * Picks the first BATCH_SIZE orders by SKU grouping:
 *   - Takes full SKU groups until the running total reaches BATCH_SIZE.
 *   - If the next SKU group would push us over, include it anyway (no half-groups).
 *   - This means the final count may exceed BATCH_SIZE when a SKU has many lines.
 *
 * Returns null if conditions aren't met (count < BATCH_SIZE and not timed out),
 * or if there are no pending orders.
 *
 * Pass `force = true` to skip the threshold/timeout checks (used by manual "Print next 25").
 */
export function generateRealtimePicklist(force = false) {
  const count = getPendingOrderCount();
  if (!count) return null;

  if (!force) {
    const meetsThreshold = count >= BATCH_SIZE;
    const timedOut = (getOldestPendingOrderAge() || 0) >= BATCH_TIMEOUT_MS;
    if (!meetsThreshold && !timedOut) return null;
  }

  const pending = getPendingOrders(); // already sorted by sku, createdAt
  const groups = groupBySku(pending);

  const selectedIds = [];
  for (const group of groups) {
    selectedIds.push(...group.orders.map((o) => o.id));
    if (selectedIds.length >= BATCH_SIZE) break;
  }

  return createPicklistFromOrders(selectedIds, 'realtime', `Realtime batch — ${selectedIds.length} orders`);
}

/**
 * Generate a picklist from an explicit set of order IDs.
 * Used by the "Print selected orders" manual action.
 */
export function generateManualPicklist(orderIds, notes) {
  if (!orderIds?.length) return null;
  return createPicklistFromOrders(orderIds, 'manual', notes || `Manual batch — ${orderIds.length} orders`);
}

/**
 * Check if daytime auto-batch conditions are met.
 * Used by the 30-second cron to decide whether to fire.
 */
export function shouldAutoBatch() {
  const count = getPendingOrderCount();
  if (!count) return false;
  if (count >= BATCH_SIZE) return true;
  const age = getOldestPendingOrderAge() || 0;
  return age >= BATCH_TIMEOUT_MS;
}
