#!/usr/bin/env python3
"""Qogita Scan Adapter — scan Qogita buyer catalog for opportunities.

Paginates through all Qogita offers (Health & Beauty wholesale),
normalises to standard opportunity format, writes to pending queue.
Runs daily at 6am via cron.

Note: Qogita's /offers/ API does not support server-side category filtering,
so we fetch all offers and let the analyser handle category-based decisions.

Usage:
    ./qogita_scan.py              # scan all offers
    ./qogita_scan.py --dry-run    # show what would be queued
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from clients import qogita
from config import QUEUE_PENDING, DATA_ROOT
from vault import log
from queue_manager import is_duplicate
import fx

# Max pages (safety limit — at 100/page, covers 1000 offers)
MAX_PAGES = 10


def scan_offers(dry_run: bool = False) -> dict:
    """Scan all Qogita offers. Returns stats dict."""
    stats = {"total": 0, "queued": 0, "skipped_dedup": 0, "skipped_no_ean": 0}
    products = []

    page = 1
    while page <= MAX_PAGES:
        result = qogita.list_offers(page=page, size=100)
        offers = result.get("results", [])
        if not offers:
            break

        for offer in offers:
            stats["total"] += 1
            variant = offer.get("variant", {})
            gtin = variant.get("gtin", "")
            if not gtin or len(gtin) < 8:
                stats["skipped_no_ean"] += 1
                continue

            # Price — Qogita uses EUR
            price = float(offer.get("price", 0))
            currency = offer.get("priceCurrency", "EUR")
            if currency != "GBP":
                gbp_price = fx.convert(price, currency, "GBP")
                if gbp_price is None:
                    log(f"qogita_scan: skipping {gtin} — cannot convert {currency} to GBP")
                    continue
                price = gbp_price

            if price <= 0:
                continue

            # Dedup check
            if is_duplicate("qogita", gtin, price):
                stats["skipped_dedup"] += 1
                continue

            # Extract brand name from nested dict
            brand_data = variant.get("brand", {})
            brand_name = brand_data.get("name", "") if isinstance(brand_data, dict) else str(brand_data)

            products.append({
                "ean": gtin,
                "name": variant.get("name", ""),
                "brand": brand_name,
                "buy_price": price,
                "currency": "GBP",
                "moq": int(offer.get("unit", 1)),
                "volume_prices": [],
                "delivery_days": 0,
                "source_ref": f"qogita:{offer.get('qid', gtin)}",
            })

        # Check if more pages
        if not result.get("next"):
            break
        page += 1
        time.sleep(0.5)  # rate limit courtesy

    # Write opportunity to queue
    if products and not dry_run:
        now = datetime.now(timezone.utc)
        opp_id = f"qogita-scan-{now.strftime('%Y%m%d%H%M')}"
        opp = {
            "id": opp_id,
            "source": "qogita",
            "supplier": "Qogita Wholesale",
            "received_at": now.isoformat(),
            "products": products,
        }
        filepath = os.path.join(QUEUE_PENDING, f"{opp_id}.json")
        os.makedirs(QUEUE_PENDING, exist_ok=True)
        with open(filepath, "w") as f:
            json.dump(opp, f, indent=2)
        stats["queued"] = len(products)
        log(f"qogita_scan: {len(products)} products queued as {opp_id}")
    elif products and dry_run:
        stats["queued"] = len(products)
        for p in products[:5]:
            log(f"  dry-run: {p['ean']} {p['name'][:40]} @ £{p['buy_price']:.2f}")
        if len(products) > 5:
            log(f"  ... and {len(products) - 5} more")

    return stats


def main():
    parser = argparse.ArgumentParser(description="Qogita Catalog Scanner")
    parser.add_argument("--dry-run", action="store_true", help="Preview without queuing")
    args = parser.parse_args()

    log("qogita_scan: starting scan of all offers")
    stats = scan_offers(dry_run=args.dry_run)
    log(f"qogita_scan: complete — scanned={stats['total']}, queued={stats['queued']}, "
        f"dedup={stats['skipped_dedup']}, no_ean={stats['skipped_no_ean']}")


if __name__ == "__main__":
    main()
