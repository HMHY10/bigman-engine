'use server';

import { auth } from '../auth/index.js';
import {
  createOrder,
  getAllOrders,
  getOrderById,
  getPendingOrders,
  deleteOrder,
  updateOrderStatus,
  getAllPicklists,
  getPicklistById,
  getPicklistItems,
  deletePicklist,
  updatePicklistStatus,
  createPicklistFromOrders,
} from '../db/picklists.js';
import { generateOvernightPicklist, generateRealtimePicklist, generateManualPicklist } from './generate.js';

async function requireAuth() {
  const session = await auth();
  if (!session?.user?.id) throw new Error('Unauthorised');
  return session.user;
}

// ─────────────────────────────────────────────────────────────────────────────
// Orders
// ─────────────────────────────────────────────────────────────────────────────

export async function getOrders() {
  await requireAuth();
  return getAllOrders(500);
}

export async function addOrder(data) {
  await requireAuth();
  if (!data.orderNumber || !data.sku || !data.productName) {
    return { error: 'orderNumber, sku and productName are required' };
  }
  const order = createOrder(data);
  return { order };
}

export async function removeOrder(id) {
  await requireAuth();
  const order = getOrderById(id);
  if (!order) return { error: 'Order not found' };
  if (order.status !== 'pending') return { error: 'Only pending orders can be deleted' };
  deleteOrder(id);
  return { success: true };
}

export async function markOrderShipped(id) {
  await requireAuth();
  updateOrderStatus(id, 'shipped');
  return { success: true };
}

// ─────────────────────────────────────────────────────────────────────────────
// Picklists
// ─────────────────────────────────────────────────────────────────────────────

export async function getPicklists() {
  await requireAuth();
  return getAllPicklists(200);
}

export async function getPicklist(id) {
  await requireAuth();
  const picklist = getPicklistById(id);
  if (!picklist) return { error: 'Picklist not found' };
  const items = getPicklistItems(id);
  return { picklist, items };
}

export async function removePicklist(id) {
  await requireAuth();
  deletePicklist(id);
  return { success: true };
}

export async function markPicklistPrinted(id) {
  await requireAuth();
  updatePicklistStatus(id, 'printed');
  return { success: true };
}

export async function markPicklistCompleted(id) {
  await requireAuth();
  updatePicklistStatus(id, 'completed');
  return { success: true };
}

// ─────────────────────────────────────────────────────────────────────────────
// Batch generation
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Generate overnight picklist — all pending orders, grouped by SKU, no cap.
 */
export async function runOvernightBatch() {
  await requireAuth();
  const picklist = generateOvernightPicklist();
  if (!picklist) return { error: 'No pending orders to batch' };
  return { picklist };
}

/**
 * Print next ~25 orders (soft cap, whole-SKU groups).
 */
export async function printNext25() {
  await requireAuth();
  const pending = getPendingOrders();
  if (!pending.length) return { error: 'No pending orders' };
  const picklist = generateRealtimePicklist(true); // force = true skips threshold check
  if (!picklist) return { error: 'Failed to generate picklist' };
  return { picklist };
}

/**
 * Print a specific selection of order IDs.
 */
export async function printSelectedOrders(orderIds) {
  await requireAuth();
  if (!orderIds?.length) return { error: 'No orders selected' };
  const picklist = generateManualPicklist(orderIds);
  if (!picklist) return { error: 'Failed to generate picklist' };
  return { picklist };
}
