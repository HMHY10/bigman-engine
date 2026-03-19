#!/usr/bin/env python3
"""Opportunity Analyser — analyse wholesale product opportunities against Amazon.

Usage:
    # Manual single-product analysis
    ./analyse.py --ean 4006000111827 --price 3.50 --supplier "Qogita" --brand "Nivea" --name "Nivea Soft 500ml"

    # Process pending queue
    ./analyse.py --queue

    # Dry run (analyse but don't move files or write to vault)
    ./analyse.py --queue --dry-run
"""
import argparse
import json
import os
import sys
import fcntl
import time
from datetime import datetime, timezone
from pathlib import Path

# Add skill directory to path
sys.path.insert(0, str(Path(__file__).parent))

from config import QUEUE_PENDING, STATE_DIR
from models import Opportunity, Product, Recommendation
from vault import log, vault_write
import queue_manager
from stages import amazon_match, compliance, market_analysis, margin_calc, volume_estimate, scoring
from stages.image_verify import run as image_verify_run
from stages.margin_calc import adjust_for_pack_size as adjust_margin_pack
from stages.volume_estimate import adjust_for_pack_size as adjust_volume_pack

LOCK_FILE = "/tmp/opportunity-analyser.lock"


def analyse_product(product: Product) -> Recommendation:
    """Run the full 6-stage pipeline on a single product."""
    log(f"analysing: {product.ean} ({product.name}) — buy=£{product.buy_price:.2f}")

    # Stage 1: Amazon match (hard fail if no match)
    matches = amazon_match.run(product)
    if not matches:
        rec = scoring.run(product, None, None, None, None, None)
        rec.reasons.append("HARD_FAIL:no_amazon_match")
        return rec
    best_match = matches[0]

    # Stage 2: Compliance (degrades — continues even on review-needed)
    comp = compliance.run(product, best_match)
    if not comp.eligible:
        return scoring.run(product, best_match, comp, None, None, None)

    # Stage 3: Market analysis
    market = market_analysis.run(product, best_match)

    # Stage 4: Margin calculation (hard fail if not calculable)
    margin = margin_calc.run(product, best_match, market)
    if not margin.calculable:
        rec = scoring.run(product, best_match, comp, market, margin, None)
        rec.reasons.append("HARD_FAIL:margin_not_calculable")
        return rec

    # Stage 5: Volume estimation
    vol = volume_estimate.run(product, best_match, market)

    # Stage 6: Scoring
    rec = scoring.run(product, best_match, comp, market, margin, vol)

    # Stage 7: Image & listing verification (Buy/Review only)
    rec = image_verify_run(product, best_match, rec)

    # Pack size recalculation (if detected)
    if rec and rec.pack_size > 1:
        saved_pack_size = rec.pack_size
        saved_flags = rec.image_flags
        margin = adjust_margin_pack(margin, rec.pack_size)
        vol = adjust_volume_pack(vol, rec.pack_size)
        # Re-score with adjusted margins
        rec = scoring.run(product, best_match, comp, market, margin, vol)
        rec.pack_size = saved_pack_size
        rec.image_flags = saved_flags

    # Store raw predictors for algo training
    rec.raw_predictors = _collect_predictors(product, best_match, comp, market, margin, vol)
    rec.analysed_at = datetime.now(timezone.utc).isoformat()

    return rec


def _collect_predictors(product, match, comp, market, margin, vol) -> dict:
    """Collect all raw data points for future algorithm training."""
    return {
        "ean": product.ean,
        "buy_price": product.buy_price,
        "asin": match.asin if match else None,
        "confidence": match.confidence if match else 0,
        "buy_box_price": market.buy_box_price if market else 0,
        "bsr": market.bsr if market else 0,
        "bsr_category": market.bsr_category if market else "",
        "seller_count": market.seller_count_total if market else 0,
        "est_monthly_sales": market.est_monthly_sales if market else 0,
        "review_count": market.review_count if market else 0,
        "review_rating": market.review_rating if market else 0,
        "profit_per_unit": margin.profit_per_unit if margin else 0,
        "roi_pct": margin.roi_pct if margin else 0,
        "recommended_qty": vol.recommended_qty if vol else 0,
        "volume_fallback": vol.fallback_used if vol else "",
        "internal_velocity": market.internal_velocity if market else {},
        "timestamp": time.time(),
    }


def write_recommendation(rec: Recommendation, opportunity_id: str):
    """Write recommendation to vault."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    ts = datetime.now(timezone.utc).strftime("%H%M%S")
    ean = rec.product.ean
    classification = rec.classification.upper()

    vault_path = f"07-Marketplace/Buying/Recommendations/{today}-{ts}-{ean}-{classification}.md"

    match_info = ""
    if rec.amazon_match:
        m = rec.amazon_match
        match_info = f"""## Amazon Match
- **ASIN:** {m.asin}
- **Title:** {m.title}
- **Brand:** {m.brand}
- **Confidence:** {m.confidence:.2f}
- **Variation:** {'Yes' if m.is_variation else 'No'}"""

    compliance_info = ""
    if rec.compliance:
        c = rec.compliance
        compliance_info = f"""## Compliance
- **Eligible:** {'Yes' if c.eligible else 'No'}
- **Hazmat:** {c.hazmat}
- **IP Risk:** {c.ip_risk}
- **Regulatory Flags:** {', '.join(c.regulatory) if c.regulatory else 'None'}
- **Notes:** {c.reason or 'Clean'}"""

    market_info = ""
    if rec.market:
        mk = rec.market
        market_info = f"""## Market Data
- **Buy Box Price:** £{mk.buy_box_price:.2f}
- **Sellers (total):** {mk.seller_count_total}
- **BSR:** {mk.bsr} ({mk.bsr_category})
- **Est. Monthly Sales:** {mk.est_monthly_sales}
- **Reviews:** {mk.review_count} ({mk.review_rating}★)
- **Data Source:** {mk.data_source}"""

    margin_info = ""
    if rec.margin:
        mg = rec.margin
        # Multi-channel comparison table
        channels_table = ""
        if hasattr(mg, '_channels') and mg._channels:
            rows = "\n".join(
                f"| {'**' + c['channel'] + '**' if c['channel'] == getattr(mg, '_best_channel', '') else c['channel']} "
                f"| £{c['marketplace_fee']:.2f} | £{c['fulfilment_cost']:.2f} "
                f"| £{c['profit_per_unit']:.2f} | {c['roi_pct']:.1f}% | {c['margin_pct']:.1f}% |"
                for c in mg._channels
            )
            vat_pct = getattr(mg, '_vat_rate', 0.20) * 100
            channels_table = f"""## Margin Analysis — All Channels
**Sell Price:** £{mg.sell_price:.2f} (inc VAT) | **Buy Price:** £{mg.buy_price:.2f} (ex-VAT) | **VAT:** {vat_pct:.0f}%

| Channel | Fees | Fulfilment | Profit/Unit | ROI | Margin |
|---------|------|------------|-------------|-----|--------|
{rows}"""

        # Promo scenarios
        promo_table = ""
        if hasattr(mg, '_promos') and mg._promos:
            promo_rows = []
            for p in mg._promos:
                units = p.get('units_given', 1)
                profit_key = 'profit_per_unit' if 'profit_per_unit' in p else 'profit_per_sale'
                promo_rows.append(
                    f"| {p['scenario']} | £{p['sell_price']:.2f} | £{p.get('marketplace_fee', 0):.2f} "
                    f"| £{p[profit_key]:.2f} | {p['roi_pct']:.1f}% |"
                )
            promo_table = f"""

## Promo Scenarios (Amazon FBA)
| Scenario | Sell Price | Fees | Profit | ROI |
|----------|-----------|------|--------|-----|
{"".join(chr(10) + r for r in promo_rows)}"""

        # Bundle scenarios
        bundle_table = ""
        if hasattr(mg, '_bundles') and mg._bundles:
            bundle_rows = []
            for b in mg._bundles:
                bundle_rows.append(
                    f"| {b['scenario']} | £{b['bundle_sell_price']:.2f} | £{b['shipping_per_unit']:.2f} "
                    f"| £{b['profit_per_unit']:.2f} | £{b['profit_total']:.2f} | {b['roi_pct']:.1f}% |"
                )
            bundle_table = f"""

## Bundle Analysis (Amazon FBA)
*Shipping spread across units — key margin driver for low-price items*

| Bundle | Sell Price | Ship/Unit | Profit/Unit | Total Profit | ROI |
|--------|-----------|-----------|-------------|-------------|-----|
{"".join(chr(10) + r for r in bundle_rows)}"""

        margin_info = channels_table + promo_table + bundle_table

    volume_info = ""
    if rec.volume:
        v = rec.volume
        volume_info = f"""## Volume Recommendation
- **Recommended Qty:** {v.recommended_qty}
- **Coverage:** {v.coverage_days} days
- **Method:** {v.fallback_used}
- **Reasoning:** {v.reasoning}"""

    content = f"""---
source: opportunity-analyser
type: recommendation
date: {today}
ean: {ean}
classification: {rec.classification}
score: {rec.score}
opportunity_id: {opportunity_id}
---

# [{classification}] {rec.product.name or ean}

**EAN:** {ean} | **Supplier:** {rec.product.supplier or 'N/A'} | **Buy Price:** £{rec.product.buy_price:.2f} | **Score:** {rec.score:.3f}

## Decision: {classification}
{chr(10).join('- ' + r for r in rec.reasons)}

{match_info}

{compliance_info}

{market_info}

{margin_info}

{volume_info}

---
*Auto-generated by opportunity-analyser at {rec.analysed_at}*
"""
    vault_write(vault_path, content)


def save_predictors(rec: Recommendation):
    """Save raw predictor data for algorithm training."""
    from config import INTEL_ROOT
    pred_dir = f"{INTEL_ROOT}/predictors"
    os.makedirs(pred_dir, exist_ok=True)
    filename = f"{pred_dir}/{rec.product.ean}-{int(time.time())}.json"
    with open(filename, "w") as f:
        json.dump(rec.raw_predictors, f, indent=2)


def process_queue(dry_run: bool = False):
    """Process all pending opportunities."""
    queue_manager.recover_stale_processing()
    queue_manager.prune_dedup_index()

    pending = queue_manager.get_pending()
    log(f"queue: {len(pending)} opportunities pending")

    stats = {"buy": 0, "review": 0, "skip": 0, "failed": 0}

    for filepath, opp in pending:
        processing_path = queue_manager.move_to_processing(filepath) if not dry_run else filepath

        try:
            hard_fails = 0
            for product in opp.products:
                product.supplier = opp.supplier  # propagate supplier to product

                # Dedup check
                if queue_manager.is_duplicate(opp.source, product.ean, product.buy_price):
                    log(f"queue: skipping duplicate {product.ean} @ £{product.buy_price:.2f}")
                    continue

                rec = analyse_product(product)

                # Track hard fails for retry logic
                is_hard_fail = any("HARD_FAIL:" in r for r in rec.reasons)
                if is_hard_fail:
                    hard_fails += 1

                stats[rec.classification] += 1

                if not dry_run:
                    write_recommendation(rec, opp.id)
                    save_predictors(rec)
                    queue_manager.record_processed(opp.source, product.ean, product.buy_price)
                    # Post-analysis: price alert evaluation
                    try:
                        from alerts.qogita_alerts import evaluate_for_alert
                        if rec and rec.classification in ('review', 'skip'):
                            evaluate_for_alert(product, rec, rec.margin, rec.market, rec.volume)
                    except ImportError:
                        pass  # alerts module not yet deployed
                    except Exception as e:
                        log(f'alert evaluation failed: {e}')
                else:
                    log(f"dry-run: {product.ean} → {rec.classification} (score={rec.score})")

            if not dry_run:
                # If ALL products hard-failed, retry the opportunity
                if hard_fails > 0 and hard_fails == len(opp.products):
                    queue_manager.move_to_pending_retry(processing_path)
                else:
                    queue_manager.move_to_processed(processing_path)

        except Exception as e:
            log(f"queue: error processing {opp.id}: {e}")
            stats["failed"] += 1
            if not dry_run:
                queue_manager.move_to_pending_retry(processing_path)

    log(f"queue: complete — buy={stats['buy']}, review={stats['review']}, skip={stats['skip']}, failed={stats['failed']}")

    # Write daily summary
    if not dry_run:
        _write_daily_summary(stats)


def _write_daily_summary(stats: dict):
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    content = f"""---
source: opportunity-analyser
type: pipeline-summary
date: {today}
---

# Opportunity Pipeline Summary — {today}

| Classification | Count |
|----------------|-------|
| Buy | {stats['buy']} |
| Review | {stats['review']} |
| Skip | {stats['skip']} |
| Failed | {stats['failed']} |

---
*Auto-generated by opportunity-analyser*
"""
    vault_write(f"07-Marketplace/Buying/Reports/{today}-pipeline-summary.md", content)


def main():
    parser = argparse.ArgumentParser(description="Opportunity Analyser")
    parser.add_argument("--queue", action="store_true", help="Process pending queue")
    parser.add_argument("--dry-run", action="store_true", help="Analyse without writing")
    parser.add_argument("--ean", help="Single product EAN")
    parser.add_argument("--price", type=float, help="Buy price (GBP)")
    parser.add_argument("--supplier", default="manual", help="Supplier name")
    parser.add_argument("--brand", default="", help="Product brand")
    parser.add_argument("--name", default="", help="Product name")

    args = parser.parse_args()

    if args.queue:
        # Lock to prevent concurrent runs
        lock_fd = open(LOCK_FILE, "w")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("ERROR: Another instance is running. Exiting.")
            sys.exit(1)

        try:
            process_queue(dry_run=args.dry_run)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()

    elif args.ean and args.price:
        product = Product(
            ean=args.ean,
            name=args.name,
            brand=args.brand,
            buy_price=args.price,
            supplier=args.supplier,
        )
        rec = analyse_product(product)
        write_recommendation(rec, f"manual-{args.ean}")
        save_predictors(rec)

        # Print summary to stdout
        print(f"\n{'='*60}")
        print(f"  {rec.classification.upper()} — {args.ean} ({args.name or 'unnamed'})")
        print(f"  Score: {rec.score:.3f}")
        if rec.margin:
            print(f"  ROI: {rec.margin.roi_pct:.1f}% | Profit: £{rec.margin.profit_per_unit:.2f}")
        if rec.market:
            print(f"  BSR: {rec.market.bsr} | Sellers: {rec.market.seller_count_total} | Est Sales: {rec.market.est_monthly_sales}/mo")
        if rec.volume:
            print(f"  Recommended Qty: {rec.volume.recommended_qty}")
        for reason in rec.reasons:
            print(f"  → {reason}")
        print(f"{'='*60}\n")

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
