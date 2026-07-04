'use server';

import { auth } from '../auth/index.js';
import { getOrdersByStatus, getOrder, setOrderStatus, getOrderLabelUrl } from './baselinker.js';
import { createBatch } from './generate.js';
import { loadBatch, listBatches, getPrintedOrders, getBatchTimer } from './state.js';

async function requireAuth() {
  const session = await auth();
  if (!session?.user?.id) throw new Error('Unauthorized');
  return session.user;
}

const READY_STATUS_ID = () => {
  const id = process.env.PICKLIST_READY_STATUS_ID;
  if (!id) throw new Error('PICKLIST_READY_STATUS_ID env var not set');
  return Number(id);
};

const BATCH_SIZE = () => Number(process.env.PICKLIST_BATCH_SIZE ?? 25);

/**
 * Get the current picklist queue status.
 * Returns ready order count, printed count, timer info, and recent batches.
 */
export async function getPicklistStatus() {
  await requireAuth();

  const since = Math.floor(Date.now() / 1000) - 86400; // last 24h
  const [allReady, printed, timer, recentBatches] = await Promise.all([
    getOrdersByStatus(READY_STATUS_ID(), since).catch(() => []),
    Promise.resolve(getPrintedOrders()),
    Promise.resolve(getBatchTimer()),
    Promise.resolve(listBatches(10)),
  ]);

  const printedSet = new Set(printed);
  const unprintedOrders = allReady.filter((o) => !printedSet.has(o.order_id));

  return {
    ready_count: unprintedOrders.length,
    printed_count: printed.length,
    batch_size: BATCH_SIZE(),
    timer,
    recent_batches: recentBatches,
    orders: unprintedOrders.map((o) => ({
      order_id: o.order_id,
      platform: o.order_source ?? 'unknown',
      customer: o.delivery_fullname || o.invoice_fullname || 'N/A',
      date_add: o.date_add ?? 0,
      product_count: (o.products ?? []).length,
    })),
  };
}

/**
 * Generate a picklist for the next N orders (default: BATCH_SIZE).
 * Returns the batch_id for the print route.
 */
export async function printNextBatch(limit) {
  await requireAuth();

  const batchSize = limit ?? BATCH_SIZE();
  const since = Math.floor(Date.now() / 1000) - 86400;
  const printed = getPrintedOrders();
  const printedSet = new Set(printed);

  const allReady = await getOrdersByStatus(READY_STATUS_ID(), since);
  const unprinted = allReady.filter((o) => !printedSet.has(o.order_id)).slice(0, batchSize);

  if (unprinted.length === 0) {
    return { error: 'No ready orders to print' };
  }

  const batch = createBatch(unprinted, 'manual');
  return { batch_id: batch.batch_id, order_count: batch.order_count };
}

/**
 * Generate a picklist for a specific set of order IDs.
 * Returns the batch_id for the print route.
 */
export async function printSelectedOrders(orderIds) {
  await requireAuth();

  if (!Array.isArray(orderIds) || orderIds.length === 0) {
    return { error: 'No orders selected' };
  }

  // Fetch full order details for the selected IDs
  const orders = await Promise.all(
    orderIds.map((id) => getOrder(id).catch(() => null))
  );
  const valid = orders.filter(Boolean);

  if (valid.length === 0) {
    return { error: 'Could not fetch order details' };
  }

  const batch = createBatch(valid, 'manual');
  return { batch_id: batch.batch_id, order_count: batch.order_count };
}

/**
 * Load a batch by ID for the print view.
 */
export async function getPicklistBatch(batchId) {
  await requireAuth();
  const batch = loadBatch(batchId);
  if (!batch) return { error: 'Batch not found' };
  return batch;
}

/**
 * Handle a QR scan: update order status to "packing" and return label URL.
 * Called by the /api/picklist/scan endpoint (not a server action — exposed via API).
 */
export async function handleScan(orderId) {
  const packingStatusId = Number(process.env.PICKLIST_PACKING_STATUS_ID ?? 0);

  const [order, labelUrl] = await Promise.all([
    getOrder(orderId).catch(() => null),
    getOrderLabelUrl(orderId).catch(() => null),
  ]);

  if (!order) {
    return { error: 'Order not found', order_id: orderId };
  }

  // Advance status to "packing" if configured
  if (packingStatusId > 0) {
    await setOrderStatus(orderId, packingStatusId).catch(() => {});
  }

  return {
    order_id: orderId,
    label_url: labelUrl,
    customer: order.delivery_fullname || order.invoice_fullname || 'N/A',
    platform: order.order_source ?? 'unknown',
    status_updated: packingStatusId > 0,
  };
}
