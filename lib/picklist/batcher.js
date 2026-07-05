/**
 * Picklist batching logic.
 *
 * Two modes:
 * 1. Overnight: collect ALL pending orders received before warehouse-open time. No cap.
 * 2. Daytime auto: batch when >= BATCH_SIZE orders pending, or after BATCH_TIMEOUT_MS
 *    since the oldest pending order arrived (time-limit fallback).
 */

import { getPendingOrdersBefore, updateOrdersStatus } from '../db/orders.js';
import { createPicklist } from '../db/picklists.js';

const BATCH_SIZE = 25;
const BATCH_TIMEOUT_MS = 25 * 1000; // 25 seconds

/**
 * Generate a picklist from all pending orders received before the given time.
 * Used for the overnight batch (no size cap).
 *
 * @param {object} [opts]
 * @param {number} [opts.before] - epoch ms cutoff (default: now)
 * @returns {object|null} The created picklist, or null if no pending orders
 */
export async function runOvernightBatch({ before = Date.now() } = {}) {
  const pending = getPendingOrdersBefore(before);
  if (!pending.length) return null;

  const orderIds = pending.map((o) => o.id);
  updateOrdersStatus(orderIds, 'batched');
  const picklist = createPicklist(orderIds, 'overnight');

  console.log(`[picklist] Overnight batch: ${orderIds.length} orders → picklist ${picklist.id.slice(0, 8)}`);
  return picklist;
}

/**
 * Run the daytime auto-batch check.
 * Generates a picklist if:
 *   - There are >= BATCH_SIZE pending orders, OR
 *   - There is at least one pending order AND the oldest has been waiting >= BATCH_TIMEOUT_MS
 *
 * @returns {object|null} The created picklist, or null if no batch generated
 */
export async function runAutoBatch() {
  const pending = getPendingOrdersBefore();
  if (!pending.length) return null;

  const oldest = pending.reduce((a, b) => (a.receivedAt < b.receivedAt ? a : b));
  const waitMs = Date.now() - oldest.receivedAt;

  const shouldBatch = pending.length >= BATCH_SIZE || waitMs >= BATCH_TIMEOUT_MS;
  if (!shouldBatch) return null;

  const orderIds = pending.map((o) => o.id);
  updateOrdersStatus(orderIds, 'batched');
  const picklist = createPicklist(orderIds, 'auto');

  console.log(`[picklist] Auto batch: ${orderIds.length} orders → picklist ${picklist.id.slice(0, 8)}`);
  return picklist;
}

/**
 * Generate a manual picklist from a specific set of order IDs.
 * Only includes orders that are currently 'pending'.
 *
 * @param {string[]} orderIds
 * @returns {object|null} The created picklist, or null if none were pending
 */
export async function runManualBatch(orderIds) {
  const pending = getPendingOrdersBefore();
  const pendingIds = new Set(pending.map((o) => o.id));
  const eligible = orderIds.filter((id) => pendingIds.has(id));

  if (!eligible.length) return null;

  updateOrdersStatus(eligible, 'batched');
  const picklist = createPicklist(eligible, 'manual');

  console.log(`[picklist] Manual batch: ${eligible.length} orders → picklist ${picklist.id.slice(0, 8)}`);
  return picklist;
}

/**
 * Generate a "next N" manual picklist — takes the oldest N pending orders.
 *
 * @param {number} [n=25]
 * @returns {object|null}
 */
export async function runNextNBatch(n = BATCH_SIZE) {
  const pending = getPendingOrdersBefore();
  if (!pending.length) return null;

  // Sort by receivedAt ascending to get oldest first
  const sorted = [...pending].sort((a, b) => a.receivedAt - b.receivedAt);
  const batch = sorted.slice(0, n);
  const orderIds = batch.map((o) => o.id);

  updateOrdersStatus(orderIds, 'batched');
  const picklist = createPicklist(orderIds, 'manual');

  console.log(`[picklist] Next-${n} batch: ${orderIds.length} orders → picklist ${picklist.id.slice(0, 8)}`);
  return picklist;
}

export { BATCH_SIZE, BATCH_TIMEOUT_MS };
