import { getDb } from './index.js';
import { orders, orderItems } from './schema.js';
import { eq, inArray, and, desc, asc, count } from 'drizzle-orm';

/**
 * Create an order with its line items.
 * @param {object} data - Order data
 * @param {object[]} items - Array of line item objects
 * @returns {object} Created order
 */
export function createOrder(data, items = []) {
  const db = getDb();
  const id = crypto.randomUUID();
  const now = Date.now();

  db.insert(orders).values({
    id,
    externalId: data.externalId,
    externalRef: data.externalRef || null,
    source: data.source || 'shopify',
    customerName: data.customerName || '',
    customerEmail: data.customerEmail || null,
    shippingAddress: data.shippingAddress ? JSON.stringify(data.shippingAddress) : null,
    status: 'pending',
    notes: data.notes || null,
    createdAt: data.createdAt || now,
    updatedAt: now,
  }).run();

  for (const item of items) {
    db.insert(orderItems).values({
      id: crypto.randomUUID(),
      orderId: id,
      sku: item.sku,
      productName: item.productName || '',
      quantity: item.quantity || 1,
      binLocation: item.binLocation || null,
      createdAt: now,
    }).run();
  }

  return getOrderById(id);
}

/**
 * Get order by ID (with items).
 */
export function getOrderById(id) {
  const db = getDb();
  const order = db.select().from(orders).where(eq(orders.id, id)).get();
  if (!order) return null;
  const items = db.select().from(orderItems).where(eq(orderItems.orderId, order.id)).all();
  return { ...order, items };
}

/**
 * Get order by external ID.
 */
export function getOrderByExternalId(externalId, source) {
  const db = getDb();
  const conditions = [eq(orders.externalId, externalId)];
  if (source) conditions.push(eq(orders.source, source));
  return db.select().from(orders).where(and(...conditions)).get() || null;
}

/**
 * Get all pending orders (not yet in a picklist), ordered by creation time.
 */
export function getPendingOrders() {
  const db = getDb();
  const rows = db.select().from(orders).where(eq(orders.status, 'pending')).orderBy(asc(orders.createdAt)).all();
  return rows.map(order => {
    const items = db.select().from(orderItems).where(eq(orderItems.orderId, order.id)).all();
    return { ...order, items };
  });
}

/**
 * Get orders by IDs (with items).
 */
export function getOrdersByIds(ids) {
  if (!ids.length) return [];
  const db = getDb();
  const rows = db.select().from(orders).where(inArray(orders.id, ids)).orderBy(asc(orders.createdAt)).all();
  return rows.map(order => {
    const items = db.select().from(orderItems).where(eq(orderItems.orderId, order.id)).all();
    return { ...order, items };
  });
}

/**
 * Update order status.
 */
export function updateOrderStatus(id, status) {
  const db = getDb();
  db.update(orders).set({ status, updatedAt: Date.now() }).where(eq(orders.id, id)).run();
}

/**
 * Update bin location for an order item.
 */
export function updateItemBinLocation(itemId, binLocation) {
  const db = getDb();
  db.update(orderItems).set({ binLocation }).where(eq(orderItems.id, itemId)).run();
}

/**
 * Update status for multiple orders at once.
 */
export function bulkUpdateOrderStatus(ids, status) {
  if (!ids.length) return;
  const db = getDb();
  const now = Date.now();
  db.update(orders).set({ status, updatedAt: now }).where(inArray(orders.id, ids)).run();
}

/**
 * Get count of pending orders.
 */
export function getPendingOrderCount() {
  const db = getDb();
  return db.select({ count: count() }).from(orders).where(eq(orders.status, 'pending')).get()?.count || 0;
}

/**
 * Get orders list with status filter and pagination (no items for performance).
 */
export function listOrders(status = null, limit = 100, offset = 0) {
  const db = getDb();
  let query = db.select().from(orders);
  if (status) query = query.where(eq(orders.status, status));
  return query.orderBy(asc(orders.createdAt)).limit(limit).offset(offset).all();
}
