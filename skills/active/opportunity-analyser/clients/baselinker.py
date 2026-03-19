"""BaseLinker data access for opportunity analyser. Reads from marketplace-ops cache."""
import json
import os
import time

from config import REPO_ROOT
from vault import log

CACHE_BASE = f"{REPO_ROOT}/cache/marketplace"


def get_product_sales_velocity(ean: str) -> dict | None:
    """Check BaseLinker order cache for historical sales of this EAN.
    Returns {units_30d, units_90d, avg_price, return_rate} or None.
    """
    orders_cache = f"{CACHE_BASE}/orders/latest.json"
    if not os.path.exists(orders_cache):
        return None

    # Only use if cache is reasonably fresh (< 24h)
    age_hours = (time.time() - os.path.getmtime(orders_cache)) / 3600
    if age_hours > 24:
        return None

    try:
        with open(orders_cache) as f:
            orders = json.load(f)

        # Count orders containing this EAN in product list
        matches = 0
        total_qty = 0
        for order in orders:
            for product in order.get("products", []):
                if product.get("ean") == ean:
                    matches += 1
                    total_qty += int(product.get("quantity", 1))

        if matches == 0:
            return None

        return {
            "orders_in_window": matches,
            "units_in_window": total_qty,
            "window_hours": 48,  # marketplace-ops caches 48h of orders
            "est_monthly_units": int(total_qty * (720 / 48)),  # extrapolate to 30 days
        }
    except Exception as e:
        log(f"baselinker: error reading sales velocity for EAN {ean}: {e}")
        return None
