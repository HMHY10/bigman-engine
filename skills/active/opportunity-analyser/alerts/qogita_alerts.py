"""Qogita price alert management.

Sets price alerts for near-profitable or high-demand products.
Two paths:
- API: if Qogita has alert management endpoints (probe at runtime)
- CSV: fallback — generate prioritised CSV for manual entry

Called post-analysis from analyse.py.
"""
import csv as csv_mod
import json
import os
from datetime import datetime, timedelta

import config

from vault import log

HIGH_DEMAND_THRESHOLD = 200  # est_monthly_sales above this = high demand




def _active_file(data_dir=None):
    data_dir = data_dir or config.INTEL_ROOT
    return os.path.join(data_dir, "price-alerts", "active.json")


def load_active_alerts(data_dir=None):
    path = _active_file(data_dir)
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return []


def save_active_alerts(alerts, data_dir=None):
    path = _active_file(data_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(alerts, f, indent=2)


# ── Target Price Calculation ──────────────────────────

def calculate_target_price(current_buy_price, sell_price, fees, fulfilment, min_roi=20.0):
    """Calculate the buy price at which the product becomes profitable.

    Returns target price (float) or None if already profitable.
    """
    # Net revenue (ex-VAT, assuming 20% standard)
    net_revenue = sell_price / 1.20
    # target_buy: profit / target_buy >= min_roi/100
    # profit = net_revenue - target_buy - fees - fulfilment
    # (net_revenue - target_buy - fees - fulfilment) / target_buy >= min_roi/100
    # net_revenue - fees - fulfilment >= target_buy * (1 + min_roi/100)
    available = net_revenue - fees - fulfilment
    if available <= 0:
        return None  # Can't be profitable at any buy price
    target = available / (1 + min_roi / 100)

    if target >= current_buy_price:
        return None  # Already profitable

    return round(target, 2)


# ── Eligibility ───────────────────────────────────────

def is_alert_eligible(classification, target_price, current_price, margin_gap_threshold,
                      est_monthly_sales, moq):
    """Determine if a product should get a price alert."""
    if target_price is None or current_price <= 0:
        return False

    gap = (current_price - target_price) / current_price
    is_high_demand = est_monthly_sales >= HIGH_DEMAND_THRESHOLD

    if classification == "review":
        return gap <= margin_gap_threshold
    elif classification == "skip":
        return is_high_demand
    elif classification == "buy":
        return False  # Already profitable, no alert needed

    return False


# ── Expiry ────────────────────────────────────────────

def calculate_expiry(est_monthly_sales, moq):
    """Calculate alert expiry date. Returns ISO date string or None (no expiry).

    30-day expiry for:
    - Low sales volume
    - High MOQ relative to sales (MOQ > threshold * monthly sales)
    """
    moq_ratio = config.ALERT_MOQ_VOLUME_RATIO_THRESHOLD
    expiry_days = config.ALERT_LOW_VOLUME_EXPIRY_DAYS
    is_high_demand = est_monthly_sales >= HIGH_DEMAND_THRESHOLD

    if is_high_demand:
        return None  # No expiry for high-demand products

    if moq > moq_ratio * max(est_monthly_sales, 1):
        return (datetime.now() + timedelta(days=expiry_days)).strftime("%Y-%m-%d")

    if est_monthly_sales < 50:
        return (datetime.now() + timedelta(days=expiry_days)).strftime("%Y-%m-%d")

    return None


# ── Alert Management ──────────────────────────────────

def evaluate_for_alert(product, recommendation, margin_result, market_data, volume_result):
    """Evaluate a product for price alert setting. Called post-analysis."""
    if not margin_result or not product.ean:
        return

    active = load_active_alerts()

    # Check cap
    if len(active) >= config.ALERT_MAX_ACTIVE:
        log(f"alert cap reached ({config.ALERT_MAX_ACTIVE}), skipping {product.ean}")
        return

    # Check if already alerted
    if any(a["ean"] == product.ean for a in active):
        return

    total_fees = margin_result.referral_fee + margin_result.fba_fee
    total_fulfilment = margin_result.shipping_fba
    target = calculate_target_price(
        current_buy_price=product.buy_price,
        sell_price=margin_result.sell_price,
        fees=total_fees,
        fulfilment=total_fulfilment,
        min_roi=config.MIN_ROI_PCT,
    )

    est_sales = market_data.est_monthly_sales if market_data else 0
    moq = getattr(product, "moq", 1) or 1

    eligible = is_alert_eligible(
        classification=recommendation.classification,
        target_price=target,
        current_price=product.buy_price,
        margin_gap_threshold=config.ALERT_MARGIN_GAP_THRESHOLD,
        est_monthly_sales=est_sales,
        moq=moq,
    )

    if not eligible:
        return

    expiry = calculate_expiry(est_sales, moq)
    reason = "high-demand" if est_sales >= HIGH_DEMAND_THRESHOLD else "margin-gap"

    alert = {
        "ean": product.ean,
        "product_name": product.name,
        "current_price": product.buy_price,
        "target_price": target,
        "date_set": datetime.now().strftime("%Y-%m-%d"),
        "expiry_date": expiry,
        "reason": reason,
        "source": getattr(product, "supplier", "unknown"),
        "est_monthly_sales": est_sales,
    }

    active.append(alert)
    save_active_alerts(active)
    log(f"alert set: {product.ean} ({product.name}) target £{target} [reason: {reason}]")

    _append_to_csv(alert)


def _append_to_csv(alert):
    """Append alert to CSV for manual setting if API unavailable."""
    csv_path = os.path.join(config.REPO_ROOT, "outputs", "price-alerts-to-set.csv")
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    write_header = not os.path.exists(csv_path)
    with open(csv_path, "a", newline="") as f:
        writer = csv_mod.writer(f)
        if write_header:
            writer.writerow(["ean", "product_name", "current_price", "target_price", "reason", "date_set"])
        writer.writerow([alert["ean"], alert["product_name"], alert["current_price"],
                         alert["target_price"], alert["reason"], alert["date_set"]])
