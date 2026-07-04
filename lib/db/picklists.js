import { getDb } from './index.js';
import { picklists, picklistOrders, orders } from './schema.js';
import { eq, desc, inArray } from 'drizzle-orm';

/**
 * Create a picklist and associate orders with it.
 * Also sets those orders' status to 'in_picklist'.
 * @param {'overnight'|'batch'|'manual'} type
 * @param {string[]} orderIds
 * @returns {object} Created picklist
 */
export function createPicklist(type, orderIds) {
  const db = getDb();
  const id = crypto.randomUUID();
  const now = Date.now();

  db.insert(picklists).values({
    id,
    type,
    status: 'pending',
    orderCount: orderIds.length,
    createdAt: now,
    printedAt: null,
    completedAt: null,
  }).run();

  for (const orderId of orderIds) {
    db.insert(picklistOrders).values({
      id: crypto.randomUUID(),
      picklistId: id,
      orderId,
    }).run();
  }

  // Mark orders as in_picklist
  if (orderIds.length) {
    const now2 = Date.now();
    db.update(orders).set({ status: 'in_picklist', updatedAt: now2 }).where(inArray(orders.id, orderIds)).run();
  }

  return getPicklistById(id);
}

/**
 * Get picklist by ID.
 */
export function getPicklistById(id) {
  const db = getDb();
  return db.select().from(picklists).where(eq(picklists.id, id)).get() || null;
}

/**
 * Get order IDs for a picklist.
 */
export function getPicklistOrderIds(picklistId) {
  const db = getDb();
  return db.select({ orderId: picklistOrders.orderId })
    .from(picklistOrders)
    .where(eq(picklistOrders.picklistId, picklistId))
    .all()
    .map(r => r.orderId);
}

/**
 * Get all picklists, newest first.
 */
export function listPicklists(limit = 50, offset = 0) {
  const db = getDb();
  return db.select().from(picklists).orderBy(desc(picklists.createdAt)).limit(limit).offset(offset).all();
}

/**
 * Mark picklist as printed (set printedAt timestamp).
 */
export function markPicklistPrinted(id) {
  const db = getDb();
  db.update(picklists).set({ status: 'printed', printedAt: Date.now() }).where(eq(picklists.id, id)).run();
}

/**
 * Mark picklist as completed (set completedAt timestamp, mark orders as picked).
 */
export function markPicklistCompleted(id) {
  const db = getDb();
  const now = Date.now();
  db.update(picklists).set({ status: 'completed', completedAt: now }).where(eq(picklists.id, id)).run();

  // Get order IDs in this picklist
  const orderIds = getPicklistOrderIds(id);
  if (orderIds.length) {
    db.update(orders).set({ status: 'picked', updatedAt: now }).where(inArray(orders.id, orderIds)).run();
  }

  return orderIds;
}

/**
 * Check if there is already a pending/printed picklist of type 'overnight' today.
 */
export function hasOvernightPicklistToday() {
  const db = getDb();
  const startOfDay = new Date();
  startOfDay.setHours(0, 0, 0, 0);
  const all = db.select().from(picklists).where(eq(picklists.type, 'overnight')).all();
  return all.some(p => p.createdAt >= startOfDay.getTime() && p.status !== 'completed');
}
