"""Stage 6: Score opportunities and classify as Buy/Review/Skip."""
from config import (
    MIN_ROI_PCT, MIN_PROFIT_PER_UNIT, MIN_MONTHLY_SALES,
    MAX_SELLER_COUNT, MIN_CONFIDENCE_SCORE, CATEGORY_THRESHOLDS,
)
from models import (
    AmazonMatch, ComplianceResult, MarginResult, MarketData,
    Product, Recommendation, VolumeResult,
)
from vault import log


def run(
    product: Product,
    match: AmazonMatch | None,
    compliance: ComplianceResult | None,
    market: MarketData | None,
    margin: MarginResult | None,
    volume: VolumeResult | None,
) -> Recommendation:
    """Score and classify the opportunity."""
    rec = Recommendation(
        product=product,
        amazon_match=match,
        compliance=compliance,
        market=market,
        margin=margin,
        volume=volume,
    )

    # No Amazon match = skip
    if not match:
        rec.classification = "skip"
        rec.reasons.append("No Amazon listing match found")
        return rec

    # Get category-specific thresholds
    category = (market.bsr_category or "").lower().replace(" ", "_") if market else ""
    thresholds = CATEGORY_THRESHOLDS.get(category, {})
    min_roi = thresholds.get("min_roi", MIN_ROI_PCT)
    min_profit = thresholds.get("min_profit", MIN_PROFIT_PER_UNIT)

    # Compliance fail = skip
    if compliance and not compliance.eligible:
        rec.classification = "skip"
        rec.reasons.append(f"Compliance fail: {compliance.reason}")
        return rec

    # Compliance review = review
    needs_review = False
    if compliance and (compliance.hazmat == "review" or compliance.ip_risk == "review"):
        needs_review = True
        rec.reasons.append(f"Compliance needs review: hazmat={compliance.hazmat}, ip={compliance.ip_risk}")

    # Confidence too low = review
    if match.confidence < MIN_CONFIDENCE_SCORE:
        needs_review = True
        rec.reasons.append(f"Low match confidence: {match.confidence:.2f}")

    # Margin checks
    if margin:
        if margin.roi_pct < min_roi:
            rec.classification = "skip"
            rec.reasons.append(f"ROI {margin.roi_pct:.1f}% below threshold {min_roi}%")
            return rec
        if margin.profit_per_unit < min_profit:
            rec.classification = "skip"
            rec.reasons.append(f"Profit £{margin.profit_per_unit:.2f} below threshold £{min_profit:.2f}")
            return rec
    else:
        rec.classification = "skip"
        rec.reasons.append("No margin data available")
        return rec

    # Market checks
    if market:
        if market.est_monthly_sales < MIN_MONTHLY_SALES and market.est_monthly_sales > 0:
            rec.reasons.append(f"Low demand: {market.est_monthly_sales}/mo (threshold: {MIN_MONTHLY_SALES})")
            needs_review = True
        if market.seller_count_total > MAX_SELLER_COUNT:
            rec.reasons.append(f"High competition: {market.seller_count_total} sellers (threshold: {MAX_SELLER_COUNT})")
            needs_review = True

    # Score (weighted)
    score = 0.0
    if margin:
        score += min(margin.roi_pct / 100, 0.4)  # ROI component (max 0.4)
    if market and market.est_monthly_sales > 0:
        score += min(market.est_monthly_sales / 1000, 0.3)  # Demand component (max 0.3)
    if match:
        score += match.confidence * 0.2  # Confidence component (max 0.2)
    if compliance and compliance.eligible and compliance.ip_risk == "clear":
        score += 0.1  # Clean compliance bonus

    rec.score = round(score, 3)

    # ── Competitive position adjustment ───────────────────
    if market and market.competitor_prices:
        our_price = margin.sell_price if margin else None
        if our_price:
            cheaper_competitors = [
                c for c in market.competitor_prices
                if c.get("price") and c["price"] < our_price and c.get("marketplace") != "wholesale"
            ]
            if len(cheaper_competitors) >= 3:
                rec.reasons.append("high_competitor_pressure")
                log(f"competitive risk: {len(cheaper_competitors)} competitors cheaper")
            stockout_signals = [
                c for c in market.competitor_prices
                if "stockout" in str(c.get("notes", "")).lower() or "out of stock" in str(c.get("notes", "")).lower()
            ]
            if stockout_signals:
                rec.score = min(rec.score + 0.05, 1.0)
                log(f"opportunity: {len(stockout_signals)} competitor stockout signals")

    if needs_review:
        rec.classification = "review"
        rec.reasons.append("Flagged for manual verification (BuyBotPro)")
    else:
        rec.classification = "buy"
        rec.reasons.append("All checks passed")

    log(f"stage6: {match.asin} — {rec.classification} (score={rec.score}, roi={margin.roi_pct:.1f}%, profit=£{margin.profit_per_unit:.2f})")
    return rec
