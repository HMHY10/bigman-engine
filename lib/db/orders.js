import { randomUUID } from 'crypto';
import { eq, and, lte, inArray, count, desc } from 'drizzle-orm';
import { getDb } from './index.js';
import { orders } from './schema.js';

/**
 * Create a new order.
 * @param {object} data
 * @returns {object}
 */
export function createOrder(data) {
  const db = getDb();
  const now = Date.now();
  const row = {
    id: randomUUID(),
    externalId: data.externalId || null,
    source: data.source || 'manual',
    status: 'pending',
    customerName: data.customerName || '',
    customerAddress: typeof data.customerAddress === 'object'
      ? JSON.stringify(data.customerAddress)
      : (data.customerAddress || '{}'),
    lineItems: Array.isArray(data.lineItems)
      ? JSON.stringify(data.lineItems)
      : (data.lineItems || '[]'),
    notes: data.notes || '',
    receivedAt: data.receivedAt || now,
    createdAt: now,
    updatedAt: now,
  };
  db.insert(orders).values(row).run();
  return parseOrder(row);
}

/**
 * Get order by ID.
 * @param {string} id
 * @returns {object|null}
 */
export function getOrderById(id) {
  const db = getDb();
  const row = db.select().from(orders).where(eq(orders.id, id)).get();
  return row ? parseOrder(row) : null;
}

/**
 * Get order by external ID.
 * @param {string} externalId
 * @returns {object|null}
 */
export function getOrderByExternalId(externalId) {
  const db = getDb();
  const row = db.select().from(orders).where(eq(orders.externalId, externalId)).get();
  return row ? parseOrder(row) : null;
}

/**
 * Get all pending orders received before a cutoff timestamp.
 * @param {number} [before] - epoch ms; defaults to now
 * @returns {object[]}
 */
export function getPendingOrdersBefore(before = Date.now()) {
  const db = getDb();
  return db
    .select()
    .from(orders)
    .where(and(eq(orders.status, 'pending'), lte(orders.receivedAt, before)))
    .all()
    .map(parseOrder);
}

/**
 * Count pending orders.
 * @returns {number}
 */
export function countPendingOrders() {
  const db = getDb();
  const result = db.select({ count: count() }).from(orders).where(eq(orders.status, 'pending')).get();
  return result?.count ?? 0;
}

/**
 * Update order status.
 * @param {string} id
 * @param {string} status
 */
export function updateOrderStatus(id, status) {
  const db = getDb();
  db.update(orders).set({ status, updatedAt: Date.now() }).where(eq(orders.id, id)).run();
}

/**
 * Update multiple orders' status in one transaction.
 * @param {string[]} ids
 * @param {string} status
 */
export function updateOrdersStatus(ids, status) {
  const db = getDb();
  if (!ids.length) return;
  db.update(orders).set({ status, updatedAt: Date.now() }).where(inArray(orders.id, ids)).run();
}

/**
 * Get all orders (for listing in UI).
 * @param {object} [opts]
 * @param {number} [opts.limit]
 * @param {string} [opts.status]
 * @returns {object[]}
 */
export function listOrders({ limit, status } = {}) {
  const db = getDb();
  let query = db.select().from(orders).orderBy(desc(orders.receivedAt));
  if (status) {
    query = query.where(eq(orders.status, status));
  }
  if (limit) {
    query = query.limit(limit);
  }
  return query.all().map(parseOrder);
}

function parseOrder(row) {
  return {
    ...row,
    customerAddress: safeParseJson(row.customerAddress, {}),
    lineItems: safeParseJson(row.lineItems, []),
  };
}

function safeParseJson(str, fallback) {
  try {
    return typeof str === 'string' ? JSON.parse(str) : str;
  } catch {
    return fallback;
  }
}
