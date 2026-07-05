import { randomUUID } from 'crypto';
import { eq, desc, inArray } from 'drizzle-orm';
import { getDb } from './index.js';
import { picklists, picklistOrders, orders } from './schema.js';

/**
 * Create a new picklist and associate the given order IDs.
 * @param {string[]} orderIds
 * @param {string} batchType - 'overnight' | 'auto' | 'manual'
 * @returns {object} The created picklist with its orders
 */
export function createPicklist(orderIds, batchType = 'auto') {
  const db = getDb();
  const now = Date.now();
  const id = randomUUID();

  const picklist = {
    id,
    status: 'pending',
    batchType,
    orderCount: orderIds.length,
    printedAt: null,
    completedAt: null,
    createdAt: now,
    updatedAt: now,
  };

  db.insert(picklists).values(picklist).run();

  if (orderIds.length > 0) {
    const joins = orderIds.map((orderId, idx) => ({
      id: randomUUID(),
      picklistId: id,
      orderId,
      sortOrder: idx,
      createdAt: now,
    }));
    db.insert(picklistOrders).values(joins).run();
  }

  return { ...picklist, orderIds };
}

/**
 * Get a picklist by ID, including its order IDs.
 * @param {string} id
 * @returns {object|null}
 */
export function getPicklistById(id) {
  const db = getDb();
  const row = db.select().from(picklists).where(eq(picklists.id, id)).get();
  if (!row) return null;

  const joins = db
    .select()
    .from(picklistOrders)
    .where(eq(picklistOrders.picklistId, id))
    .orderBy(picklistOrders.sortOrder)
    .all();

  return { ...row, orderIds: joins.map((j) => j.orderId) };
}

/**
 * Get the full orders data for a picklist, grouped by SKU.
 * @param {string} picklistId
 * @returns {{ picklist: object, orderRows: object[], skuGroups: object[] }}
 */
export function getPicklistWithOrders(picklistId) {
  const db = getDb();
  const picklist = db.select().from(picklists).where(eq(picklists.id, picklistId)).get();
  if (!picklist) return null;

  const joins = db
    .select()
    .from(picklistOrders)
    .where(eq(picklistOrders.picklistId, picklistId))
    .orderBy(picklistOrders.sortOrder)
    .all();

  const orderIds = joins.map((j) => j.orderId);
  if (!orderIds.length) return { picklist, orderRows: [], skuGroups: [] };

  const orderRows = db.select().from(orders).where(inArray(orders.id, orderIds)).all().map((row) => ({
    ...row,
    customerAddress: safeParseJson(row.customerAddress, {}),
    lineItems: safeParseJson(row.lineItems, []),
  }));

  // Group line items by SKU
  const skuMap = new Map();
  for (const order of orderRows) {
    for (const item of order.lineItems) {
      const key = item.sku || item.name;
      if (!skuMap.has(key)) {
        skuMap.set(key, {
          sku: item.sku || '',
          name: item.name || '',
          binLocation: item.binLocation || '',
          totalQuantity: 0,
          orderLines: [],
        });
      }
      const group = skuMap.get(key);
      group.totalQuantity += item.quantity || 1;
      group.orderLines.push({ orderId: order.id, externalId: order.externalId, quantity: item.quantity || 1 });
    }
  }

  const skuGroups = Array.from(skuMap.values()).sort((a, b) =>
    (a.binLocation || a.sku).localeCompare(b.binLocation || b.sku)
  );

  return { picklist, orderRows, skuGroups };
}

/**
 * List all picklists, most recent first.
 * @param {object} [opts]
 * @param {number} [opts.limit]
 * @returns {object[]}
 */
export function listPicklists({ limit } = {}) {
  const db = getDb();
  let query = db.select().from(picklists).orderBy(desc(picklists.createdAt));
  if (limit) query = query.limit(limit);
  return query.all();
}

/**
 * Update picklist status.
 * @param {string} id
 * @param {string} status
 * @param {object} [extra] - extra fields to set (e.g. printedAt, completedAt)
 */
export function updatePicklistStatus(id, status, extra = {}) {
  const db = getDb();
  db.update(picklists)
    .set({ status, updatedAt: Date.now(), ...extra })
    .where(eq(picklists.id, id))
    .run();
}

function safeParseJson(str, fallback) {
  try {
    return typeof str === 'string' ? JSON.parse(str) : str;
  } catch {
    return fallback;
  }
}
