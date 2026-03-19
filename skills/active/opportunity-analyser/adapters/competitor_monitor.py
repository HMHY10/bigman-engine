#!/usr/bin/env python3
"""Competitor monitor — weekly competitive scan.

Combines Qogita seller catalog + Amazon pricing + vault-intel data.
Generates weekly trend report to vault.
Triggers re-analysis when competitive landscape shifts significantly.

Cron: 0 4 * * 0 (Sunday 4am)
"""
import json
import os
import sys
from datetime import datetime, date, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import config
from vault import vault_write, log

SKILL = "opportunity-analyser"
SNAPSHOT_DIR = os.path.join(config.INTEL_ROOT, "competitor-snapshots")
COMPETITOR_DIR = os.path.join(config.INTEL_ROOT, "competitor")
REPORT_VAULT_PATH = "07-Marketplace/Buying/Competitor"




def load_previous_snapshot():
    """Load last week's snapshot for comparison."""
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    snapshots = sorted([f for f in os.listdir(SNAPSHOT_DIR) if f.endswith(".json")])
    if not snapshots:
        return {}
    with open(os.path.join(SNAPSHOT_DIR, snapshots[-1])) as f:
        return json.load(f)


def save_snapshot(data):
    """Save current week's snapshot."""
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    filename = f"snapshot-{date.today().isoformat()}.json"
    with open(os.path.join(SNAPSHOT_DIR, filename), "w") as f:
        json.dump(data, f, indent=2)
    log(f"snapshot saved: {filename}")


def prune_old_snapshots():
    """Remove snapshots older than retention period."""
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    cutoff = date.today() - timedelta(days=config.COMPETITOR_SNAPSHOT_RETENTION_DAYS)
    for f in os.listdir(SNAPSHOT_DIR):
        if not f.endswith(".json"):
            continue
        try:
            d = date.fromisoformat(f.replace("snapshot-", "").replace(".json", ""))
            if d < cutoff:
                os.remove(os.path.join(SNAPSHOT_DIR, f))
                log(f"pruned old snapshot: {f}")
        except ValueError:
            continue


def collect_competitor_data():
    """Collect current competitor pricing from vault-intel output."""
    current = {}
    if not os.path.exists(COMPETITOR_DIR):
        return current

    for filename in os.listdir(COMPETITOR_DIR):
        if not filename.endswith(".json") or filename == "processed-notes.json":
            continue
        ean = filename.replace(".json", "")
        try:
            with open(os.path.join(COMPETITOR_DIR, filename)) as f:
                data = json.load(f)
            if data:
                latest = {}
                for entry in data:
                    comp = entry.get("competitor", "unknown")
                    latest[comp] = {
                        "price": entry.get("price"),
                        "marketplace": entry.get("marketplace"),
                        "date": entry.get("date"),
                    }
                current[ean] = latest
        except Exception as e:
            log(f"error reading {filename}: {e}")

    return current


def collect_amazon_prices():
    """Collect current Amazon pricing from SP-API cache."""
    amazon_prices = {}
    sp_cache = os.path.join(config.INTEL_ROOT, "sp-api")
    if not os.path.exists(sp_cache):
        return amazon_prices

    for filename in os.listdir(sp_cache):
        if not filename.endswith(".json"):
            continue
        try:
            with open(os.path.join(sp_cache, filename)) as f:
                data = json.load(f)
            ean = data.get("ean") or filename.replace(".json", "")
            if data.get("buy_box_price"):
                amazon_prices[ean] = {
                    "price": data["buy_box_price"],
                    "seller_count": data.get("seller_count"),
                }
        except Exception:
            continue

    return amazon_prices


def compare_snapshots(current, previous):
    """Compare current vs previous week. Returns trend analysis."""
    trends = {"up": [], "down": [], "stable": [], "new": [], "gone": []}

    all_eans = set(list(current.keys()) + list(previous.keys()))
    for ean in all_eans:
        curr_data = current.get(ean, {})
        prev_data = previous.get(ean, {})

        if not prev_data and curr_data:
            trends["new"].append({"ean": ean, "competitors": curr_data})
            continue
        if prev_data and not curr_data:
            trends["gone"].append({"ean": ean, "competitors": prev_data})
            continue

        for comp in set(list(curr_data.keys()) + list(prev_data.keys())):
            curr_price = curr_data.get(comp, {}).get("price")
            prev_price = prev_data.get(comp, {}).get("price")
            if curr_price and prev_price:
                change = ((curr_price - prev_price) / prev_price) * 100
                entry = {"ean": ean, "competitor": comp, "prev": prev_price, "curr": curr_price, "change_pct": round(change, 1)}
                if change > 2:
                    trends["up"].append(entry)
                elif change < -2:
                    trends["down"].append(entry)
                else:
                    trends["stable"].append(entry)

    return trends


def generate_report(trends, amazon_prices):
    """Generate markdown report for vault."""
    today = date.today().isoformat()
    lines = [
        f"# Weekly Competitor Report — {today}\n",
        f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n",
    ]

    if trends["down"]:
        lines.append("## Price Drops (Action Required)\n")
        for t in trends["down"]:
            lines.append(f"- **{t['ean']}** — {t['competitor']}: £{t['prev']:.2f} → £{t['curr']:.2f} ({t['change_pct']}%)")
        lines.append("")

    if trends["up"]:
        lines.append("## Price Increases (Opportunity)\n")
        for t in trends["up"]:
            lines.append(f"- **{t['ean']}** — {t['competitor']}: £{t['prev']:.2f} → £{t['curr']:.2f} (+{t['change_pct']}%)")
        lines.append("")

    if trends["gone"]:
        lines.append("## Competitor Stockouts / Delistings\n")
        for t in trends["gone"]:
            lines.append(f"- **{t['ean']}** — previously tracked, no longer seen")
        lines.append("")

    if trends["new"]:
        lines.append("## New Competitor Entries\n")
        for t in trends["new"]:
            lines.append(f"- **{t['ean']}** — new competitors detected")
        lines.append("")

    lines.append("## Summary\n")
    lines.append(f"- Price drops: {len(trends['down'])}")
    lines.append(f"- Price increases: {len(trends['up'])}")
    lines.append(f"- Stable: {len(trends['stable'])}")
    lines.append(f"- New entries: {len(trends['new'])}")
    lines.append(f"- Delistings: {len(trends['gone'])}")

    return "\n".join(lines)


def trigger_reanalysis(trends):
    """Drop products with significant competitive changes back into queue."""
    from queue_manager import enqueue

    requeued = 0
    for trend in trends.get("down", []):
        if abs(trend.get("change_pct", 0)) >= 10:
            enqueue({
                "product": {"ean": trend["ean"], "name": "", "buy_price": 0, "currency": "GBP"},
                "source": "competitor-monitor",
                "supplier": "reanalysis",
                "priority": False,
            })
            requeued += 1

    for trend in trends.get("gone", []):
        enqueue({
            "product": {"ean": trend["ean"], "name": "", "buy_price": 0, "currency": "GBP"},
            "source": "competitor-monitor",
            "supplier": "reanalysis",
            "priority": False,
        })
        requeued += 1

    if requeued:
        log(f"triggered re-analysis for {requeued} products")


def run(dry_run=False):
    """Main entry point."""
    log("starting weekly competitor scan")

    previous = load_previous_snapshot()
    competitor_data = collect_competitor_data()
    amazon_prices = collect_amazon_prices()

    current = {}
    for ean, comps in competitor_data.items():
        current[ean] = comps
    for ean, amz in amazon_prices.items():
        if ean not in current:
            current[ean] = {}
        current[ean]["Amazon"] = {"price": amz["price"], "marketplace": "amazon", "date": date.today().isoformat()}

    trends = compare_snapshots(current, previous)

    report = generate_report(trends, amazon_prices)
    log(f"report: {len(trends['down'])} drops, {len(trends['up'])} increases, {len(trends['gone'])} delistings")

    if dry_run:
        print(report)
        return

    save_snapshot(current)
    filename = f"weekly-{date.today().isoformat()}"
    vault_write(f"{REPORT_VAULT_PATH}/{filename}.md", report)
    trigger_reanalysis(trends)
    prune_old_snapshots()

    log("weekly scan complete")


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    run(dry_run=dry)
