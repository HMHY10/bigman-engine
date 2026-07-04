/**
 * lib/picklist/generate.js
 * Picklist batch generation logic — groups orders by SKU and saves state.
 */

import { saveBatch, markOrdersPrinted } from './state.js';

/**
 * Generate a batch ID string.
 * Format: PICKLIST-YYYYMMDD-HHmmss-{type}
 */
export function generateBatchId(type = 'manual') {
  const now = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const datePart = [
    now.getUTCFullYear(),
    pad(now.getUTCMonth() + 1),
    pad(now.getUTCDate()),
  ].join('');
  const timePart = [
    pad(now.getUTCHours()),
    pad(now.getUTCMinutes()),
    pad(now.getUTCSeconds()),
  ].join('');
  return `PICKLIST-${datePart}-${timePart}-${type}`;
}

/**
 * Group an array of BaseLinker order objects by SKU/product.
 * Returns an array of SKU groups, sorted by product name.
 *
 * @param {object[]} orders
 * @returns {object[]} skuGroups
 */
export function groupOrdersBySku(orders) {
  const groups = new Map();

  for (const order of orders) {
    const products = order.products ?? [];
    for (const product of products) {
      const productId = String(product.product_id ?? product.storage_product_id ?? 'unknown');
      const sku = product.sku || product.product_id || 'N/A';
      const name = product.name || 'Unknown product';
      const qty = Number(product.quantity ?? 1);

      if (!groups.has(productId)) {
        groups.set(productId, {
          product_id: productId,
          sku,
          name,
          total_qty: 0,
          lines: [],
        });
      }

      const group = groups.get(productId);
      group.total_qty += qty;
      group.lines.push({
        order_id: order.order_id,
        order_date: order.date_add ?? 0,
        platform: order.order_source ?? 'unknown',
        customer: order.delivery_fullname || order.invoice_fullname || 'N/A',
        quantity: qty,
      });
    }
  }

  return [...groups.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Create a picklist batch from a list of BaseLinker orders.
 * Saves batch to state and marks orders as printed.
 *
 * @param {object[]} orders - Full order objects from BaseLinker
 * @param {string} type - 'auto' | 'morning' | 'manual'
 * @param {string} [batchId] - optional override
 * @returns {object} batch data
 */
export function createBatch(orders, type = 'manual', batchId) {
  const id = batchId ?? generateBatchId(type);
  const skuGroups = groupOrdersBySku(orders);
  const orderIds = orders.map((o) => o.order_id);

  const batch = {
    batch_id: id,
    type,
    created_at: Math.floor(Date.now() / 1000),
    order_count: orders.length,
    order_ids: orderIds,
    sku_groups: skuGroups,
  };

  saveBatch(batch);
  markOrdersPrinted(orderIds);

  return batch;
}
