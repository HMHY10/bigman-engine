import { getDb } from './index.js';
import { orders, picklists, picklistItems } from './schema.js';
import { eq, inArray, and, sql } from 'drizzle-orm';

// ─────────────────────────────────────────────────────────────────────────────
// Orders
// ─────────────────────────────────────────────────────────────────────────────

export function createOrder(data) {
  const db = getDb();
  const now = Date.now();
  const id = crypto.randomUUID();
  db.insert(orders).values({
    id,
    orderNumber: data.orderNumber,
    customerName: data.customerName || null,
    sku: data.sku,
    productName: data.productName,
    quantity: data.quantity || 1,
    binLocation: data.binLocation || null,
    status: 'pending',
    picklistId: null,
    source: data.source || 'manual',
    notes: data.notes || null,
    createdAt: now,
    updatedAt: now,
  }).run();
  return getOrderById(id);
}

export function getOrderById(id) {
  const db = getDb();
  return db.select().from(orders).where(eq(orders.id, id)).get();
}

export function getPendingOrders() {
  const db = getDb();
  return db.select().from(orders)
    .where(eq(orders.status, 'pending'))
    .orderBy(orders.sku, orders.createdAt)
    .all();
}

export function getOrdersByPicklist(picklistId) {
  const db = getDb();
  return db.select().from(orders)
    .where(eq(orders.picklistId, picklistId))
    .orderBy(orders.sku, orders.createdAt)
    .all();
}

export function getAllOrders(limit = 200) {
  const db = getDb();
  return db.select().from(orders)
    .orderBy(sql`${orders.createdAt} desc`)
    .limit(limit)
    .all();
}

export function updateOrderStatus(id, status, picklistId = undefined) {
  const db = getDb();
  const update = { status, updatedAt: Date.now() };
  if (picklistId !== undefined) update.picklistId = picklistId;
  db.update(orders).set(update).where(eq(orders.id, id)).run();
}

export function updateOrdersBatchStatus(ids, status, picklistId) {
  if (!ids.length) return;
  const db = getDb();
  db.update(orders)
    .set({ status, picklistId, updatedAt: Date.now() })
    .where(inArray(orders.id, ids))
    .run();
}

export function deleteOrder(id) {
  const db = getDb();
  db.delete(orders).where(eq(orders.id, id)).run();
}

export function getPendingOrderCount() {
  const db = getDb();
  const result = db.select({ count: sql`count(*)` })
    .from(orders)
    .where(eq(orders.status, 'pending'))
    .get();
  return result?.count || 0;
}

export function getOldestPendingOrderAge() {
  const db = getDb();
  const result = db.select({ oldest: sql`min(${orders.createdAt})` })
    .from(orders)
    .where(eq(orders.status, 'pending'))
    .get();
  if (!result?.oldest) return null;
  return Date.now() - result.oldest;
}

// ─────────────────────────────────────────────────────────────────────────────
// Picklists
// ─────────────────────────────────────────────────────────────────────────────

export function createPicklist(data = {}) {
  const db = getDb();
  const now = Date.now();
  const id = crypto.randomUUID();
  db.insert(picklists).values({
    id,
    status: 'pending',
    batchType: data.batchType || 'manual',
    orderCount: data.orderCount || 0,
    notes: data.notes || null,
    printedAt: null,
    completedAt: null,
    createdAt: now,
    updatedAt: now,
  }).run();
  return getPicklistById(id);
}

export function getPicklistById(id) {
  const db = getDb();
  return db.select().from(picklists).where(eq(picklists.id, id)).get();
}

export function getAllPicklists(limit = 100) {
  const db = getDb();
  return db.select().from(picklists)
    .orderBy(sql`${picklists.createdAt} desc`)
    .limit(limit)
    .all();
}

export function updatePicklistStatus(id, status) {
  const db = getDb();
  const update = { status, updatedAt: Date.now() };
  if (status === 'printed') update.printedAt = Date.now();
  if (status === 'completed') update.completedAt = Date.now();
  db.update(picklists).set(update).where(eq(picklists.id, id)).run();
}

export function deletePicklist(id) {
  const db = getDb();
  // Revert batched orders back to pending
  db.update(orders)
    .set({ status: 'pending', picklistId: null, updatedAt: Date.now() })
    .where(and(eq(orders.picklistId, id), eq(orders.status, 'batched')))
    .run();
  db.delete(picklistItems).where(eq(picklistItems.picklistId, id)).run();
  db.delete(picklists).where(eq(picklists.id, id)).run();
}

// ─────────────────────────────────────────────────────────────────────────────
// Picklist Items
// ─────────────────────────────────────────────────────────────────────────────

export function addPicklistItems(picklistId, orderIds) {
  if (!orderIds.length) return;
  const db = getDb();
  const now = Date.now();

  const orderRows = db.select().from(orders)
    .where(inArray(orders.id, orderIds))
    .all();

  const items = orderRows.map((o) => ({
    id: crypto.randomUUID(),
    picklistId,
    orderId: o.id,
    sku: o.sku,
    productName: o.productName,
    quantity: o.quantity,
    binLocation: o.binLocation,
    createdAt: now,
  }));

  for (const item of items) {
    db.insert(picklistItems).values(item).run();
  }

  // Update order count on picklist
  db.update(picklists)
    .set({ orderCount: items.length, updatedAt: now })
    .where(eq(picklists.id, picklistId))
    .run();
}

export function getPicklistItems(picklistId) {
  const db = getDb();
  return db.select().from(picklistItems)
    .where(eq(picklistItems.picklistId, picklistId))
    .orderBy(picklistItems.sku, picklistItems.binLocation)
    .all();
}

// ─────────────────────────────────────────────────────────────────────────────
// High-level batch creation
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Create a picklist from a list of order IDs.
 * Groups by SKU, marks orders as batched.
 * @param {string[]} orderIds
 * @param {'overnight'|'realtime'|'manual'} batchType
 * @param {string} [notes]
 * @returns {object} picklist
 */
export function createPicklistFromOrders(orderIds, batchType = 'manual', notes) {
  if (!orderIds.length) return null;

  const picklist = createPicklist({ batchType, notes });
  addPicklistItems(picklist.id, orderIds);
  updateOrdersBatchStatus(orderIds, 'batched', picklist.id);
  return getPicklistById(picklist.id);
}
