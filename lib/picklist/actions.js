'use server';

import { auth } from '../auth/index.js';
import { listOrders, countPendingOrders, createOrder, updateOrderStatus } from '../db/orders.js';
import { listPicklists, getPicklistById, getPicklistWithOrders, updatePicklistStatus } from '../db/picklists.js';
import { runManualBatch, runNextNBatch, runOvernightBatch } from './batcher.js';

async function requireAuth() {
  const session = await auth();
  if (!session?.user?.id) throw new Error('Unauthorized');
  return session.user;
}

/**
 * Get pending order count and recent orders for the warehouse dashboard.
 */
export async function getWarehouseSummary() {
  await requireAuth();
  const pendingCount = countPendingOrders();
  const recentOrders = listOrders({ limit: 50 });
  const recentPicklists = listPicklists({ limit: 20 });
  return { pendingCount, recentOrders, recentPicklists };
}

/**
 * Get all picklists.
 */
export async function getPicklists() {
  await requireAuth();
  return listPicklists({ limit: 50 });
}

/**
 * Get a single picklist with its orders and SKU groups.
 * @param {string} picklistId
 */
export async function getPicklistDetail(picklistId) {
  await requireAuth();
  return getPicklistWithOrders(picklistId);
}

/**
 * Print next N orders (default 25).
 * @param {number} [n=25]
 * @returns {{ picklist: object|null }}
 */
export async function printNextN(n = 25) {
  await requireAuth();
  const picklist = await runNextNBatch(n);
  return { picklist };
}

/**
 * Print selected orders by ID.
 * @param {string[]} orderIds
 * @returns {{ picklist: object|null }}
 */
export async function printSelected(orderIds) {
  await requireAuth();
  if (!Array.isArray(orderIds) || !orderIds.length) {
    return { picklist: null, error: 'No orders selected' };
  }
  const picklist = await runManualBatch(orderIds);
  return { picklist };
}

/**
 * Run the overnight batch (all pending orders, no cap).
 * @returns {{ picklist: object|null }}
 */
export async function runOvernightBatchAction() {
  await requireAuth();
  const picklist = await runOvernightBatch();
  return { picklist };
}

/**
 * Mark a picklist as printed.
 * @param {string} picklistId
 */
export async function markPicklistPrinted(picklistId) {
  await requireAuth();
  updatePicklistStatus(picklistId, 'printed', { printedAt: Date.now() });
  return { ok: true };
}

/**
 * Mark a picklist as completed (all orders picked).
 * Updates order statuses to 'picked'.
 * @param {string} picklistId
 */
export async function completePicklist(picklistId) {
  await requireAuth();
  const { updateOrdersStatus } = await import('../db/orders.js');
  const pl = getPicklistById(picklistId);
  if (!pl) return { ok: false, error: 'Not found' };

  updateOrdersStatus(pl.orderIds, 'picked');
  updatePicklistStatus(picklistId, 'completed', { completedAt: Date.now() });
  return { ok: true };
}

/**
 * Create a manual order from the UI.
 * @param {object} data
 */
export async function createManualOrder(data) {
  await requireAuth();
  const order = createOrder({ ...data, source: 'manual' });
  return { order };
}

/**
 * Cancel a pending order.
 * @param {string} orderId
 */
export async function cancelOrder(orderId) {
  await requireAuth();
  updateOrderStatus(orderId, 'cancelled');
  return { ok: true };
}
