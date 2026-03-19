"""Stage 4: Multi-marketplace margin calculation.

Calculates margins across Amazon FBA, Amazon MFN, eBay, TikTok Shop, and Shopify.
Uses real fee schedules from official marketplace rate cards (see fees.py).
All calculations ex-VAT (standard VAT registered seller, input VAT reclaimable).
"""
from config import (
    SHIPPING_TO_FBA_PER_UNIT, DEFAULT_VAT_RATE,
    VAT_RATES_BY_CATEGORY, VAT_RATE_KEYWORDS,
)
from models import AmazonMatch, MarginResult, MarketData, Product
from vault import log
import fees


def _get_vat_rate(product: Product, match: AmazonMatch, market: MarketData) -> float:
    """Determine the correct VAT rate for this product."""
    name_lower = (product.name + " " + (match.title if match else "")).lower()

    for rate, keywords in VAT_RATE_KEYWORDS.items():
        if any(kw in name_lower for kw in keywords):
            return rate

    category = (market.bsr_category or "").lower().replace(" ", "_") if market else ""
    if category in VAT_RATES_BY_CATEGORY:
        return VAT_RATES_BY_CATEGORY[category]

    return DEFAULT_VAT_RATE


def _calc_channel_margin(
    sell_price: float, buy_price: float, vat_rate: float,
    marketplace_fee: float, fulfilment_cost: float, channel_name: str,
) -> dict:
    """Calculate margin for a single channel."""
    net_revenue = sell_price / (1 + vat_rate)
    profit = net_revenue - buy_price - marketplace_fee - fulfilment_cost
    roi = (profit / buy_price * 100) if buy_price > 0 else 0
    margin = (profit / net_revenue * 100) if net_revenue > 0 else 0

    return {
        "channel": channel_name,
        "sell_price": round(sell_price, 2),
        "net_revenue": round(net_revenue, 2),
        "buy_price": round(buy_price, 2),
        "marketplace_fee": round(marketplace_fee, 2),
        "fulfilment_cost": round(fulfilment_cost, 2),
        "profit_per_unit": round(profit, 2),
        "roi_pct": round(roi, 1),
        "margin_pct": round(margin, 1),
        "vat_rate": vat_rate,
    }


def run(product: Product, match: AmazonMatch, market: MarketData) -> MarginResult:
    """Calculate margins across all marketplaces. Returns MarginResult for best channel."""
    sell_price = market.buy_box_price  # inc VAT
    buy_price = product.buy_price      # ex-VAT

    if sell_price <= 0 or buy_price <= 0:
        log(f"stage4: cannot calculate margin — sell={sell_price}, buy={buy_price}")
        return MarginResult(sell_price=sell_price, buy_price=buy_price, calculable=False)

    vat_rate = _get_vat_rate(product, match, market)
    bsr_cat = market.bsr_category or ""

    # ── Amazon FBA ──────────────────────────────────────────────
    amz_category = fees.resolve_amazon_category(bsr_cat)
    amz_referral = fees.calc_amazon_referral_fee(sell_price, amz_category)
    amz_fba = fees.calc_amazon_fba_fee()  # default tier (no dimensions yet)
    amazon_fba = _calc_channel_margin(
        sell_price, buy_price, vat_rate,
        amz_referral, amz_fba + SHIPPING_TO_FBA_PER_UNIT, "Amazon FBA",
    )

    # ── Amazon MFN (Amazon Shipping, 2-day) ─────────────────────
    amz_mnf_shipping = fees.calc_mnf_shipping(carrier="amazon_shipping", speed="2_day")
    amazon_mfn = _calc_channel_margin(
        sell_price, buy_price, vat_rate,
        amz_referral, amz_mnf_shipping, "Amazon MFN",
    )

    # ── eBay ────────────────────────────────────────────────────
    ebay_cat = fees.resolve_ebay_category(bsr_cat)
    ebay_fee = fees.calc_ebay_fee(sell_price, ebay_cat)
    ebay_shipping = fees.calc_mnf_shipping(carrier="amazon_shipping", speed="2_day")
    ebay = _calc_channel_margin(
        sell_price, buy_price, vat_rate,
        ebay_fee, ebay_shipping, "eBay",
    )

    # ── TikTok Shop ─────────────────────────────────────────────
    tiktok_cat = fees.resolve_tiktok_category(bsr_cat)
    tiktok_fee = fees.calc_tiktok_fee(sell_price, tiktok_cat)
    tiktok_shipping = fees.calc_mnf_shipping(carrier="amazon_shipping", speed="2_day")
    tiktok = _calc_channel_margin(
        sell_price, buy_price, vat_rate,
        tiktok_fee, tiktok_shipping, "TikTok Shop",
    )

    # ── Shopify ─────────────────────────────────────────────────
    shopify_fee = fees.calc_shopify_fee(sell_price)
    shopify_shipping = fees.calc_mnf_shipping(carrier="amazon_shipping", speed="2_day")
    shopify = _calc_channel_margin(
        sell_price, buy_price, vat_rate,
        shopify_fee, shopify_shipping, "Shopify",
    )

    # ── Collect all channels ────────────────────────────────────
    channels = [amazon_fba, amazon_mfn, ebay, tiktok, shopify]

    # ── Promo scenarios (on best channel) ───────────────────────
    promos = []
    # Voucher scenarios
    for voucher_pct in [0.10, 0.20]:
        amz_fee_fn = lambda p, cat=amz_category: fees.calc_amazon_referral_fee(p, cat)
        promo = fees.calc_voucher_margin(
            sell_price, buy_price, voucher_pct,
            amz_fee_fn, amz_fba + SHIPPING_TO_FBA_PER_UNIT, vat_rate,
        )
        promos.append(promo)

    # BOGOF
    amz_fee_fn = lambda p, cat=amz_category: fees.calc_amazon_referral_fee(p, cat)
    bogof = fees.calc_bogof_margin(
        sell_price, buy_price,
        amz_fee_fn, amz_fba + SHIPPING_TO_FBA_PER_UNIT, vat_rate,
    )
    promos.append(bogof)

    # ── Bundle scenarios ────────────────────────────────────────
    bundles = []
    for pack_qty in [2, 3, 5]:
        # Estimate bundle sell price: slight discount per unit (5% off per extra unit)
        discount = 1 - (0.05 * (pack_qty - 1))
        bundle_price = sell_price * pack_qty * discount
        amz_fee_fn = lambda p, cat=amz_category: fees.calc_amazon_referral_fee(p, cat)
        bundle = fees.calc_bundle_margin(
            sell_price, buy_price, pack_qty, bundle_price,
            amz_fee_fn, amz_fba + SHIPPING_TO_FBA_PER_UNIT, vat_rate,
        )
        bundles.append(bundle)

    # ── Best channel (highest profit) ───────────────────────────
    best = max(channels, key=lambda c: c["profit_per_unit"])

    result = MarginResult(
        sell_price=round(sell_price, 2),
        buy_price=round(buy_price, 2),
        referral_fee=round(amz_referral, 2),
        fba_fee=round(amz_fba, 2),
        shipping_fba=round(SHIPPING_TO_FBA_PER_UNIT, 2),
        vat=round(sell_price - sell_price / (1 + vat_rate), 2),
        profit_per_unit=round(best["profit_per_unit"], 2),
        roi_pct=round(best["roi_pct"], 1),
        margin_pct=round(best["margin_pct"], 1),
        break_even_units=int(buy_price / best["profit_per_unit"]) + 1 if best["profit_per_unit"] > 0 else 0,
        calculable=True,
    )

    # Attach multi-channel and promo data for recommendation output
    result._channels = channels
    result._promos = promos
    result._bundles = bundles
    result._best_channel = best["channel"]
    result._vat_rate = vat_rate

    log(f"stage4: {match.asin} — best={best['channel']} profit=£{best['profit_per_unit']:.2f} ROI={best['roi_pct']:.1f}% | "
        f"FBA=£{amazon_fba['profit_per_unit']:.2f} MFN=£{amazon_mfn['profit_per_unit']:.2f} "
        f"eBay=£{ebay['profit_per_unit']:.2f} TikTok=£{tiktok['profit_per_unit']:.2f} "
        f"Shopify=£{shopify['profit_per_unit']:.2f} (VAT {vat_rate*100:.0f}%)")
    return result


def calculate_at_volume(product: Product, match: AmazonMatch, market: MarketData) -> list[tuple[int, MarginResult]]:
    """Calculate margins at each volume price tier."""
    results = []
    for vp in product.volume_prices:
        temp_product = Product(
            ean=product.ean, name=product.name, brand=product.brand,
            buy_price=vp.price, currency=product.currency,
        )
        result = run(temp_product, match, market)
        results.append((vp.qty, result))
    return results
