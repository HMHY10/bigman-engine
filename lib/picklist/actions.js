'use server';

import { auth } from '../auth/index.js';

async function requireAuth() {
  const session = await auth();
  if (!session?.user?.id) throw new Error('Unauthorized');
  return session.user;
}

// ─────────────────────────────────────────────────────────────────────────────
// Orders
// ─────────────────────────────────────────────────────────────────────────────

/**
 * List orders with optional status filter.
 * @param {string|null} status - 'pending' | 'in_picklist' | 'picked' | 'shipped' | null (all)
 * @param {number} limit
 */
export async function getOrdersList(status = null, limit = 100) {
  await requireAuth();
  const { listOrders } = await import('../db/orders.js');
  return listOrders(status, limit);
}

/**
 * Get pending order count.
 */
export async function getPendingCount() {
  await requireAuth();
  const { getPendingOrderCount } = await import('../db/orders.js');
  return getPendingOrderCount();
}

/**
 * Create an order manually.
 */
export async function createOrderAction(data, items) {
  await requireAuth();
  try {
    const { createOrder } = await import('../db/orders.js');
    return { success: true, order: createOrder(data, items) };
  } catch (err) {
    console.error('Failed to create order:', err);
    return { error: err.message };
  }
}

/**
 * Update order status.
 */
export async function updateOrderStatusAction(id, status) {
  await requireAuth();
  const { updateOrderStatus } = await import('../db/orders.js');
  updateOrderStatus(id, status);
  return { success: true };
}

/**
 * Update a bin location for an order item.
 */
export async function updateBinLocationAction(itemId, binLocation) {
  await requireAuth();
  const { updateItemBinLocation } = await import('../db/orders.js');
  updateItemBinLocation(itemId, binLocation);
  return { success: true };
}

// ─────────────────────────────────────────────────────────────────────────────
// Picklists
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Get recent picklists.
 */
export async function getPicklistsList(limit = 50) {
  await requireAuth();
  const { listPicklists } = await import('../db/picklists.js');
  return listPicklists(limit);
}

/**
 * Get pending orders for display (with items).
 */
export async function getPendingOrdersForPicklist() {
  await requireAuth();
  const { getPendingOrders } = await import('../db/orders.js');
  return getPendingOrders();
}

/**
 * Print next N orders as a picklist batch.
 * @param {number} [n=25]
 */
export async function printNextBatch(n = 25) {
  await requireAuth();
  try {
    const { generateNextNPicklist } = await import('./index.js');
    const picklist = generateNextNPicklist(n);
    if (!picklist) return { error: 'No pending orders to batch' };
    return { success: true, picklist };
  } catch (err) {
    console.error('printNextBatch failed:', err);
    return { error: err.message };
  }
}

/**
 * Create a picklist from a specific set of selected order IDs.
 * @param {string[]} orderIds
 */
export async function printSelectedOrders(orderIds) {
  await requireAuth();
  if (!orderIds?.length) return { error: 'No orders selected' };
  try {
    const { generateManualPicklist } = await import('./index.js');
    const picklist = generateManualPicklist(orderIds);
    return { success: true, picklist };
  } catch (err) {
    console.error('printSelectedOrders failed:', err);
    return { error: err.message };
  }
}

/**
 * Mark a picklist as printed.
 */
export async function markPrinted(picklistId) {
  await requireAuth();
  const { markPicklistPrinted } = await import('../db/picklists.js');
  markPicklistPrinted(picklistId);
  return { success: true };
}

/**
 * Get picklist detail with full order data (for print view).
 */
export async function getPicklistDetail(picklistId) {
  await requireAuth();
  const { getPicklistById, getPicklistOrderIds } = await import('../db/picklists.js');
  const { getOrdersByIds } = await import('../db/orders.js');
  const picklist = getPicklistById(picklistId);
  if (!picklist) return null;
  const orderIds = getPicklistOrderIds(picklistId);
  const ordersWithItems = getOrdersByIds(orderIds);
  return { picklist, orders: ordersWithItems };
}

// ─────────────────────────────────────────────────────────────────────────────
// Auto-batch (cron-triggered, also callable from UI)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Trigger daytime auto-batch check.
 * Creates a batch if enough orders are pending or oldest order has timed out.
 */
export async function triggerAutoBatch(batchSize = 25) {
  await requireAuth();
  try {
    const { generateBatchPicklist } = await import('./index.js');
    return generateBatchPicklist(batchSize);
  } catch (err) {
    console.error('triggerAutoBatch failed:', err);
    return { error: err.message };
  }
}

/**
 * Trigger overnight batch generation.
 */
export async function triggerOvernightBatch() {
  await requireAuth();
  try {
    const { generateOvernightPicklist } = await import('./index.js');
    return generateOvernightPicklist();
  } catch (err) {
    console.error('triggerOvernightBatch failed:', err);
    return { error: err.message };
  }
}

/**
 * Get picklist settings (webhook URL, batch size, etc.) from DB config.
 */
export async function getPicklistSettings() {
  await requireAuth();
  const { getConfigValue } = await import('../db/config.js');
  return {
    shippingLabelWebhookUrl: getConfigValue('PICKLIST_SHIPPING_WEBHOOK_URL') || '',
    batchSize: parseInt(getConfigValue('PICKLIST_BATCH_SIZE') || '25', 10),
    maxWaitMinutes: parseInt(getConfigValue('PICKLIST_MAX_WAIT_MINUTES') || '15', 10),
  };
}

/**
 * Save picklist settings.
 */
export async function savePicklistSettings(settings) {
  await requireAuth();
  const { setConfigValue } = await import('../db/config.js');
  if (settings.shippingLabelWebhookUrl !== undefined) {
    setConfigValue('PICKLIST_SHIPPING_WEBHOOK_URL', settings.shippingLabelWebhookUrl);
  }
  if (settings.batchSize !== undefined) {
    setConfigValue('PICKLIST_BATCH_SIZE', String(settings.batchSize));
  }
  if (settings.maxWaitMinutes !== undefined) {
    setConfigValue('PICKLIST_MAX_WAIT_MINUTES', String(settings.maxWaitMinutes));
  }
  return { success: true };
}
