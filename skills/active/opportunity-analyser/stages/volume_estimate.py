"""Stage 5: Volume estimation — recommended purchase quantity."""
from clients import baselinker
from config import DEFAULT_COVERAGE_DAYS
from models import AmazonMatch, MarketData, Product, VolumeResult
from vault import log


def run(product: Product, match: AmazonMatch, market: MarketData) -> VolumeResult:
    """Estimate optimal purchase quantity."""
    result = VolumeResult(coverage_days=DEFAULT_COVERAGE_DAYS)

    # Fallback chain
    daily_demand = 0

    # 1. BaseLinker historical velocity (uses cached data from market analysis stage)
    velocity = market.internal_velocity if market else None
    if not velocity:
        velocity = baselinker.get_product_sales_velocity(product.ean)
    if velocity and velocity.get("est_monthly_units", 0) > 0:
        daily_demand = velocity["est_monthly_units"] / 30
        result.fallback_used = "baselinker_history"
        result.reasoning = f"Based on internal sales: ~{velocity['est_monthly_units']} units/month"

    # 2. Amazon/BSR estimated monthly sales (may come from SP-API, Rainforest, or BSR table)
    elif market and market.est_monthly_sales > 0:
        share = market.est_monthly_sales / max(market.seller_count_total, 1)
        daily_demand = share / 30
        result.fallback_used = f"{market.data_source}_share"
        result.reasoning = f"Est. {market.est_monthly_sales}/mo ({market.data_source}) ÷ {max(market.seller_count_total, 1)} sellers = ~{share:.0f}/mo share"

    # 3. MOQ as last resort
    else:
        result.recommended_qty = product.moq
        result.fallback_used = "moq_minimum"
        result.reasoning = f"No demand signal available. Using MOQ ({product.moq})"
        log(f"stage5: {match.asin} — no demand signal, using MOQ={product.moq}")
        return result

    # Calculate base quantity
    base_qty = int(daily_demand * DEFAULT_COVERAGE_DAYS)
    base_qty = max(base_qty, product.moq)  # at least MOQ

    # Optimise against volume price tiers
    best_qty = base_qty
    if product.volume_prices:
        for vp in product.volume_prices:
            if vp.qty <= base_qty * 1.5:  # don't over-buy more than 150% of demand
                best_qty = max(best_qty, vp.qty)

    result.recommended_qty = best_qty
    if best_qty > base_qty:
        result.reasoning += f" → bumped to {best_qty} for volume discount"

    log(f"stage5: {match.asin} — daily_demand={daily_demand:.1f}, base={base_qty}, recommended={best_qty} ({result.fallback_used})")
    return result
