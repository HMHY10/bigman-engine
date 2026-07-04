/**
 * lib/picklist/baselinker.js
 * Minimal BaseLinker API client for picklist server actions.
 * Uses BASELINKER_API_TOKEN from environment.
 */

const BL_API_URL = 'https://api.baselinker.com/connector.php';

async function blRequest(method, params = {}) {
  const token = process.env.BASELINKER_API_TOKEN;
  if (!token) throw new Error('BASELINKER_API_TOKEN not set');

  const body = new URLSearchParams({
    method,
    parameters: JSON.stringify(params),
  });

  const res = await fetch(BL_API_URL, {
    method: 'POST',
    headers: { 'X-BLToken': token },
    body,
  });

  if (!res.ok) {
    throw new Error(`BaseLinker HTTP ${res.status} for ${method}`);
  }

  const data = await res.json();
  if (data.status === 'ERROR') {
    throw new Error(`BaseLinker API error ${data.error_code}: ${data.error_message}`);
  }

  return data;
}

/**
 * Fetch orders by status ID since a given timestamp.
 * Auto-paginates up to maxPages pages.
 */
export async function getOrdersByStatus(statusId, since, maxPages = 20) {
  const allOrders = [];
  let lastOrderId = 0;
  let page = 0;

  while (page < maxPages) {
    const params = {
      date_from: since,
      get_unconfirmed_orders: false,
      status_id: statusId,
    };
    if (lastOrderId > 0) params.id_from = lastOrderId;

    const data = await blRequest('getOrders', params);
    const orders = data.orders ?? [];

    if (orders.length === 0) break;
    allOrders.push(...orders);
    page++;

    if (orders.length < 100) break;
    lastOrderId = orders[orders.length - 1].order_id;
  }

  return allOrders;
}

/**
 * Get full details for a single order.
 */
export async function getOrder(orderId) {
  const data = await blRequest('getOrders', { order_id: orderId });
  return (data.orders ?? [])[0] ?? null;
}

/**
 * Set an order's status in BaseLinker.
 */
export async function setOrderStatus(orderId, statusId) {
  return blRequest('setOrderStatus', { order_id: orderId, status_id: statusId });
}

/**
 * Get courier packages for an order.
 */
export async function getOrderPackages(orderId) {
  const data = await blRequest('getCourierPackagesList', { order_id: orderId });
  return data.packages ?? [];
}

/**
 * Get the first package label URL for an order (if a package exists).
 * Returns null if no package exists.
 */
export async function getOrderLabelUrl(orderId) {
  const packages = await getOrderPackages(orderId);
  if (packages.length === 0) return null;
  const pkg = packages[0];
  // BaseLinker label URL pattern
  return pkg.label_url ?? null;
}
