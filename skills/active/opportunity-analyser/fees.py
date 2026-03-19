"""Marketplace fee structures for UK selling — Amazon, eBay, TikTok Shop, Shopify.

All referral/commission fees from official marketplace rate cards (Feb 2026).
All shipping rates from ArryBarry's contracted rates.
"""

# ═══════════════════════════════════════════════════════════════════
# AMAZON UK — Referral Fees (from official FBA Rate Card, Feb 2026)
# Tiered by category AND price. Based on offer price (inc VAT).
# Minimum referral fee: £0.25 per item.
# ═══════════════════════════════════════════════════════════════════

AMAZON_MIN_REFERRAL_FEE = 0.25
AMAZON_MEDIA_CLOSING_FEE = 0.50  # per media item (books, music, DVD, video games, software)
AMAZON_MEDIA_CATEGORIES = {"books", "music_video_dvd", "software", "video_games"}

# Format: category -> list of (price_threshold, rate) tuples, applied in order.
# For tiered rates: rate applies to portion of price up to threshold.
# For flat rates: single entry with threshold=None.
# "portion" means the rate applies to the PORTION up to that price (like tax brackets).
# "flat" means the rate applies to the ENTIRE price if price is in that range.
AMAZON_REFERRAL_FEES = {
    # Flat rate categories
    "amazon_device_accessories": {"type": "flat", "tiers": [(None, 0.45)]},
    "rucksacks_handbags": {"type": "flat", "tiers": [(None, 0.15)]},
    "beer_wine_spirits": {"type": "flat", "tiers": [(None, 0.10)]},
    "books": {"type": "flat", "tiers": [(None, 0.15)]},
    "business_industrial_scientific": {"type": "flat", "tiers": [(None, 0.15)]},
    "compact_appliances": {"type": "flat", "tiers": [(None, 0.15)]},
    "commercial_electrical": {"type": "flat", "tiers": [(None, 0.12)]},
    "computers": {"type": "flat", "tiers": [(None, 0.07)]},
    "lawn_garden": {"type": "flat", "tiers": [(None, 0.15)]},
    "luggage": {"type": "flat", "tiers": [(None, 0.15)]},
    "mattresses": {"type": "flat", "tiers": [(None, 0.15)]},
    "music_video_dvd": {"type": "flat", "tiers": [(None, 0.15)]},
    "musical_instruments": {"type": "flat", "tiers": [(None, 0.12)]},
    "office_products": {"type": "flat", "tiers": [(None, 0.15)]},
    "packing_materials": {"type": "flat", "tiers": [(None, 0.15)]},
    "pet_supplies": {"type": "flat", "tiers": [(None, 0.15)]},
    "software": {"type": "flat", "tiers": [(None, 0.15)]},
    "sports_outdoors": {"type": "flat", "tiers": [(None, 0.15)]},
    "tyres": {"type": "flat", "tiers": [(None, 0.07)]},
    "tools_home_improvement": {"type": "flat", "tiers": [(None, 0.13)]},
    "toys_games": {"type": "flat", "tiers": [(None, 0.15)]},
    "video_games": {"type": "flat", "tiers": [(None, 0.15)]},
    "video_game_consoles": {"type": "flat", "tiers": [(None, 0.08)]},
    "everything_else": {"type": "flat", "tiers": [(None, 0.15)]},

    # Tiered rate categories (rate changes based on price)
    "automotive_powersports": {
        "type": "portion",  # rate applies to PORTION of price in each bracket
        "tiers": [(45.00, 0.15), (None, 0.09)],
    },
    "baby_products": {
        "type": "threshold",  # rate applies to WHOLE price based on which bracket it falls in
        "tiers": [(10.00, 0.08), (None, 0.15)],
    },
    "baby_pushchairs_safety": {
        "type": "threshold",
        "tiers": [(10.00, 0.08), (None, 0.15)],
    },
    "beauty_health_personal_care": {
        "type": "threshold",
        "tiers": [(10.00, 0.08), (None, 0.15)],
    },
    "reusable_work_safety_gloves": {
        "type": "threshold",
        "tiers": [(10.00, 0.08), (None, 0.15)],
    },
    "clothing_accessories": {
        "type": "threshold",
        "tiers": [(15.00, 0.05), (20.00, 0.10), (None, 0.15)],
    },
    "pet_clothing_food": {
        "type": "threshold",
        "tiers": [(10.00, 0.05), (None, 0.15)],
    },
    "vitamins_minerals_supplements": {
        "type": "threshold",
        "tiers": [(10.00, 0.05), (None, 0.15)],
    },
    "watches": {
        "type": "portion",
        "tiers": [(225.00, 0.15), (None, 0.05)],
    },
    "grocery_gourmet": {
        "type": "threshold",
        "tiers": [(10.00, 0.05), (None, 0.15)],
    },
    "home_products": {
        "type": "threshold",
        "tiers": [(20.00, 0.08), (None, 0.15)],
    },
}


def calc_amazon_referral_fee(sell_price: float, category: str) -> float:
    """Calculate Amazon UK referral fee for a given sell price and category."""
    cat_data = AMAZON_REFERRAL_FEES.get(category, AMAZON_REFERRAL_FEES["everything_else"])
    fee_type = cat_data["type"]
    tiers = cat_data["tiers"]

    if fee_type == "flat":
        fee = sell_price * tiers[0][1]
    elif fee_type == "threshold":
        # Whole price charged at the rate of the bracket it falls in
        rate = tiers[-1][1]  # default to last tier
        for threshold, tier_rate in tiers:
            if threshold is not None and sell_price <= threshold:
                rate = tier_rate
                break
        fee = sell_price * rate
    elif fee_type == "portion":
        # Rate applies to PORTION of price in each bracket (like tax brackets)
        fee = 0.0
        remaining = sell_price
        prev_threshold = 0.0
        for threshold, rate in tiers:
            if threshold is None:
                fee += remaining * rate
                break
            bracket_amount = min(remaining, threshold - prev_threshold)
            fee += bracket_amount * rate
            remaining -= bracket_amount
            prev_threshold = threshold
            if remaining <= 0:
                break
    else:
        fee = sell_price * 0.15

    # Apply minimum
    is_media = category in AMAZON_MEDIA_CATEGORIES
    closing_fee = AMAZON_MEDIA_CLOSING_FEE if is_media else 0
    return max(fee, AMAZON_MIN_REFERRAL_FEE) + closing_fee


# ═══════════════════════════════════════════════════════════════════
# AMAZON UK — FBA Fulfilment Fees (from official Rate Card, Feb 2026)
# Per unit, based on size tier and weight. UK domestic.
# ═══════════════════════════════════════════════════════════════════

# Format: list of (max_weight_g, fee_gbp) — pick first matching
AMAZON_FBA_FEES = {
    # Light envelope: ≤ 33 x 23 x 2.5cm
    "light_envelope": [(20, 1.83), (40, 1.87), (60, 1.89), (80, 2.07), (100, 2.08), (210, 2.10)],
    # Extra-large envelope: ≤ 33 x 23 x 6cm
    "extra_large_envelope": [(960, 2.94)],
    # Small parcel: ≤ 35 x 25 x 12cm
    "small_parcel": [
        (150, 2.91), (400, 3.00), (900, 3.04), (1400, 3.05), (1900, 3.25), (3900, 3.27),
    ],
    # Standard parcel: ≤ 45 x 34 x 26cm
    "standard_parcel": [
        (150, 2.94), (400, 3.01), (900, 3.06), (1400, 3.26), (1900, 3.48),
        (2900, 3.49), (3900, 3.54), (5900, 3.56), (8900, 3.57), (11900, 3.58),
    ],
    # Small oversize: ≤ 61 x 46 x 46cm
    "small_oversize": [(760, 3.49), (100000, 4.35)],
    # Standard oversize: ≤ 120 x 60 x 60cm
    "standard_oversize": [(760, 6.58), (100000, 5.67)],
    # Large oversize: ≤ 175 x 120 x 60cm
    "large_oversize": [(15760, 10.20), (100000, 13.04)],
    # Special oversize: > 175cm longest side
    "special_oversize": [(31500, 16.22), (100000, 17.24)],
}

# Default FBA fee when product dimensions unknown
AMAZON_FBA_DEFAULT = 3.06  # standard parcel ≤ 900g (typical for health & beauty)


def calc_amazon_fba_fee(weight_g: int = 0, size_tier: str = "") -> float:
    """Calculate Amazon FBA fulfilment fee. Returns default if no weight/size info."""
    if not size_tier or size_tier not in AMAZON_FBA_FEES:
        return AMAZON_FBA_DEFAULT
    tiers = AMAZON_FBA_FEES[size_tier]
    for max_weight, fee in tiers:
        if weight_g <= max_weight:
            return fee
    return tiers[-1][1]  # last tier


# ═══════════════════════════════════════════════════════════════════
# AMAZON SHIPPING — MFN rates (ArryBarry contracted, primary carrier)
# ═══════════════════════════════════════════════════════════════════

AMAZON_SHIPPING_RATES = {
    "next_day": {
        "large_letter": {"max_weight_g": 750, "max_dims_cm": (35.3, 25, 2.5), "fee": 2.25},
        "small_parcel": {"max_weight_g": 2000, "max_dims_cm": (45, 35, 16), "fee": 2.31},
        "standard_parcel": {"max_weight_g": 7000, "max_dims_cm": (50, 40, 30), "fee": 2.71},
        "medium_parcel": {"max_weight_g": 15000, "max_dims_cm": (61, 46, 46), "fee": 4.60},
        "large_parcel": {"max_weight_g": 20000, "max_dims_cm": (67, 51, 51), "fee": 7.70},
    },
    "2_day": {
        "large_letter": {"max_weight_g": 750, "max_dims_cm": (35.3, 25, 2.5), "fee": 2.05},
        "small_parcel": {"max_weight_g": 2000, "max_dims_cm": (45, 35, 16), "fee": 2.20},
        "standard_parcel": {"max_weight_g": 7000, "max_dims_cm": (50, 40, 30), "fee": 2.50},
        "medium_parcel": {"max_weight_g": 15000, "max_dims_cm": (61, 46, 46), "fee": 3.91},
        "large_parcel": {"max_weight_g": 20000, "max_dims_cm": (67, 51, 51), "fee": 7.16},
    },
}

# Default MFN shipping (small parcel, 2-day — most health & beauty)
AMAZON_SHIPPING_DEFAULT = 2.20


# ═══════════════════════════════════════════════════════════════════
# ROYAL MAIL — ArryBarry contracted rates (secondary carrier)
# ═══════════════════════════════════════════════════════════════════

ROYAL_MAIL_RATES = {
    "tracked_24": {"code": "TPN", "fee": 2.64, "max_weight_g": 1000, "max_volume_l": 20},
    "tracked_48": {"code": "TPS", "fee": 2.15, "max_weight_g": 1000, "max_volume_l": 20},
    "tracked_24_lbt": {"code": "TRN", "fee": 1.99, "max_weight_g": 1000, "max_volume_l": 2},
    "tracked_48_lbt": {"code": "TRS", "fee": 1.70, "max_weight_g": 1000, "max_volume_l": 2},
    "tracked_returns_48": {"code": "TSS", "fee": 2.50, "max_weight_g": 1000, "max_volume_l": 3},
}


def calc_mnf_shipping(weight_g: int = 0, carrier: str = "amazon_shipping", speed: str = "2_day") -> float:
    """Calculate MFN shipping cost. Defaults to Amazon Shipping 2-day small parcel."""
    if carrier == "royal_mail":
        # Default to tracked 48 (cheapest)
        return ROYAL_MAIL_RATES["tracked_48"]["fee"]

    # Amazon Shipping
    rates = AMAZON_SHIPPING_RATES.get(speed, AMAZON_SHIPPING_RATES["2_day"])
    for tier_name, tier_data in rates.items():
        if weight_g <= tier_data["max_weight_g"]:
            return tier_data["fee"]
    # Fallback to largest tier
    return list(rates.values())[-1]["fee"]


# ═══════════════════════════════════════════════════════════════════
# EBAY UK — Business Seller Final Value Fees (from ebay.co.uk, 2026)
# Top Rated Seller: 10% discount on variable portion.
# Regulatory operating fee: 0.35% of total sale.
# ═══════════════════════════════════════════════════════════════════

EBAY_REGULATORY_FEE_PCT = 0.0035
EBAY_TRS_DISCOUNT = 0.10  # 10% off variable FVF for Top Rated Seller
EBAY_IS_TOP_RATED = True  # ArryBarry is Top Rated Seller

# Per-order fixed fee
EBAY_PER_ORDER_FEE_LOW = 0.30   # orders ≤ £10
EBAY_PER_ORDER_FEE_HIGH = 0.40  # orders > £10

# Format: category -> list of (price_threshold, rate) — threshold type for tiered
EBAY_FEES = {
    "health_beauty": {"rate": 0.109},
    "baby": {"rate": 0.109},
    "toys_games": {"rate": 0.109},
    "sporting_goods": {"rate": 0.109},
    "garden_patio": {"rate": 0.109},
    "pet_supplies": {"rate": 0.129},
    "clothing_shoes_accessories": {"rate": 0.119},
    "home_furniture_diy": {"tiers": [(500, 0.119), (None, 0.079)]},
    "computers_tablets": {"tiers": [(1000, 0.069), (None, 0.03)]},
    "books_comics_magazines": {"rate": 0.099},
    "business_office_industrial": {"rate": 0.125},
    "crafts": {"rate": 0.129},
    "jewellery_watches": {"tiers": [(1000, 0.149), (None, 0.04)]},
    "wholesale_job_lots": {"rate": 0.129},
    "everything_else": {"rate": 0.129},
}


def calc_ebay_fee(sell_price: float, category: str = "health_beauty") -> float:
    """Calculate eBay UK total fee (FVF + per-order + regulatory). Applies TRS discount."""
    cat_data = EBAY_FEES.get(category, EBAY_FEES["everything_else"])

    # Calculate variable FVF
    if "rate" in cat_data:
        variable_fee = sell_price * cat_data["rate"]
    else:
        # Tiered
        tiers = cat_data["tiers"]
        rate = tiers[-1][1]
        for threshold, tier_rate in tiers:
            if threshold is not None and sell_price <= threshold:
                rate = tier_rate
                break
        variable_fee = sell_price * rate

    # TRS discount on variable portion
    if EBAY_IS_TOP_RATED:
        variable_fee *= (1 - EBAY_TRS_DISCOUNT)

    # Per-order fixed fee
    per_order = EBAY_PER_ORDER_FEE_LOW if sell_price <= 10 else EBAY_PER_ORDER_FEE_HIGH

    # Regulatory operating fee
    regulatory = sell_price * EBAY_REGULATORY_FEE_PCT

    return variable_fee + per_order + regulatory


# ═══════════════════════════════════════════════════════════════════
# TIKTOK SHOP UK — Commission Fees (from seller-uk.tiktok.com, 2026)
# Standard: 9%. Some Beauty & Electronics: 5%.
# Per-order platform fee: £0.50 (self-ship).
# ═══════════════════════════════════════════════════════════════════

TIKTOK_PER_ORDER_FEE = 0.50  # per order (self-ship)

TIKTOK_FEES = {
    "beauty_personal_care": 0.05,  # reduced rate
    "electronics": 0.05,           # reduced rate
    "default": 0.09,               # standard rate
}


def calc_tiktok_fee(sell_price: float, category: str = "default") -> float:
    """Calculate TikTok Shop UK total fee (commission + per-order)."""
    rate = TIKTOK_FEES.get(category, TIKTOK_FEES["default"])
    return sell_price * rate + TIKTOK_PER_ORDER_FEE


# ═══════════════════════════════════════════════════════════════════
# SHOPIFY — Payment Processing Only (no marketplace commission)
# Shopify Payments UK: 2.2% + 20p per transaction.
# ═══════════════════════════════════════════════════════════════════

SHOPIFY_PAYMENT_RATE = 0.022
SHOPIFY_PAYMENT_FIXED = 0.20


def calc_shopify_fee(sell_price: float) -> float:
    """Calculate Shopify fee (payment processing only, no marketplace commission)."""
    return sell_price * SHOPIFY_PAYMENT_RATE + SHOPIFY_PAYMENT_FIXED


# ═══════════════════════════════════════════════════════════════════
# PROMO / BUNDLE SCENARIOS
# ═══════════════════════════════════════════════════════════════════

def calc_voucher_margin(sell_price: float, buy_price: float, voucher_pct: float,
                        marketplace_fee_fn, shipping: float, vat_rate: float) -> dict:
    """Calculate margin with a percentage voucher applied.

    voucher_pct: e.g. 0.10 for 10% off voucher.
    The seller funds the voucher (Amazon deducts from payout).
    Referral fee is on the DISCOUNTED price.
    """
    discounted_price = sell_price * (1 - voucher_pct)
    net_revenue = discounted_price / (1 + vat_rate)
    marketplace_fee = marketplace_fee_fn(discounted_price)
    profit = net_revenue - buy_price - marketplace_fee - shipping
    roi = (profit / buy_price * 100) if buy_price > 0 else 0
    return {
        "scenario": f"{int(voucher_pct*100)}% voucher",
        "sell_price": round(discounted_price, 2),
        "net_revenue": round(net_revenue, 2),
        "marketplace_fee": round(marketplace_fee, 2),
        "shipping": round(shipping, 2),
        "profit_per_unit": round(profit, 2),
        "roi_pct": round(roi, 1),
    }


def calc_bogof_margin(sell_price: float, buy_price: float,
                      marketplace_fee_fn, shipping: float, vat_rate: float) -> dict:
    """Calculate margin for Buy One Get One Free.

    Customer pays for 1 unit, gets 2. Seller pays buy_price x2, shipping x1.
    Marketplace fee on the price of 1 unit (what customer actually pays).
    """
    net_revenue = sell_price / (1 + vat_rate)
    marketplace_fee = marketplace_fee_fn(sell_price)
    total_cost = (buy_price * 2) + marketplace_fee + shipping
    profit = net_revenue - total_cost
    roi = (profit / (buy_price * 2) * 100) if buy_price > 0 else 0
    return {
        "scenario": "BOGOF (buy 1 get 1 free)",
        "sell_price": round(sell_price, 2),
        "units_given": 2,
        "net_revenue": round(net_revenue, 2),
        "marketplace_fee": round(marketplace_fee, 2),
        "shipping": round(shipping, 2),
        "buy_cost_total": round(buy_price * 2, 2),
        "profit_per_sale": round(profit, 2),
        "profit_per_unit": round(profit / 2, 2),
        "roi_pct": round(roi, 1),
    }


def calc_bundle_margin(sell_price_per_unit: float, buy_price: float, pack_qty: int,
                       bundle_sell_price: float, marketplace_fee_fn,
                       shipping: float, vat_rate: float) -> dict:
    """Calculate margin for a multi-pack/bundle listing.

    pack_qty: number of units in the bundle (e.g. 3 for a 3-pack).
    bundle_sell_price: total sell price for the bundle.
    shipping: ONE shipping cost (spread across pack_qty units).

    Key insight: postage is spread across multiple units, improving per-unit margin.
    """
    net_revenue = bundle_sell_price / (1 + vat_rate)
    total_buy_cost = buy_price * pack_qty
    marketplace_fee = marketplace_fee_fn(bundle_sell_price)

    profit = net_revenue - total_buy_cost - marketplace_fee - shipping
    profit_per_unit = profit / pack_qty
    roi = (profit / total_buy_cost * 100) if total_buy_cost > 0 else 0

    return {
        "scenario": f"{pack_qty}-pack bundle @ £{bundle_sell_price:.2f}",
        "bundle_sell_price": round(bundle_sell_price, 2),
        "pack_qty": pack_qty,
        "net_revenue": round(net_revenue, 2),
        "buy_cost_total": round(total_buy_cost, 2),
        "marketplace_fee": round(marketplace_fee, 2),
        "shipping": round(shipping, 2),
        "shipping_per_unit": round(shipping / pack_qty, 2),
        "profit_total": round(profit, 2),
        "profit_per_unit": round(profit_per_unit, 2),
        "roi_pct": round(roi, 1),
    }


# ═══════════════════════════════════════════════════════════════════
# CATEGORY MAPPING — map Amazon BSR categories to fee category keys
# ═══════════════════════════════════════════════════════════════════

AMAZON_CATEGORY_MAP = {
    # BSR category IDs/names → fee category key
    "beauty": "beauty_health_personal_care",
    "health_personal_care": "beauty_health_personal_care",
    "health_beauty": "beauty_health_personal_care",
    "health & beauty": "beauty_health_personal_care",
    "health & personal care": "beauty_health_personal_care",
    "beauty & personal care": "beauty_health_personal_care",
    "baby": "baby_products",
    "baby products": "baby_products",
    "grocery": "grocery_gourmet",
    "grocery & gourmet food": "grocery_gourmet",
    "home": "home_products",
    "home & kitchen": "home_products",
    "kitchen": "home_products",
    "kitchen & home": "home_products",
    "clothing": "clothing_accessories",
    "sports": "sports_outdoors",
    "sports & outdoors": "sports_outdoors",
    "toys": "toys_games",
    "toys & games": "toys_games",
    "pet supplies": "pet_supplies",
    "pet products": "pet_supplies",
    "electronics": "computers",
    "computers & accessories": "computers",
    "diy & tools": "tools_home_improvement",
    "automotive": "automotive_powersports",
    "garden": "lawn_garden",
    "garden & outdoors": "lawn_garden",
    "watches": "watches",
    "jewellery": "watches",
    "musical instruments": "musical_instruments",
    "musical instruments & dj": "musical_instruments",
    "office products": "office_products",
    "stationery & office supplies": "office_products",
    "books": "books",
    "software": "software",
    "dvd & blu-ray": "music_video_dvd",
    "music": "music_video_dvd",
    "video games": "video_games",
}

EBAY_CATEGORY_MAP = {
    "beauty": "health_beauty",
    "health_personal_care": "health_beauty",
    "health_beauty": "health_beauty",
    "health & beauty": "health_beauty",
    "health & personal care": "health_beauty",
    "baby": "baby",
    "toys": "toys_games",
    "toys & games": "toys_games",
    "sports": "sporting_goods",
    "sports & outdoors": "sporting_goods",
    "pet supplies": "pet_supplies",
    "clothing": "clothing_shoes_accessories",
    "home": "home_furniture_diy",
    "garden": "garden_patio",
    "electronics": "computers_tablets",
    "books": "books_comics_magazines",
}

TIKTOK_CATEGORY_MAP = {
    "beauty": "beauty_personal_care",
    "health_personal_care": "beauty_personal_care",
    "health_beauty": "beauty_personal_care",
    "health & beauty": "beauty_personal_care",
    "electronics": "electronics",
    "computers": "electronics",
}


def resolve_amazon_category(bsr_category: str) -> str:
    """Map a BSR category string to our fee category key."""
    if not bsr_category:
        return "everything_else"
    key = bsr_category.lower().strip()
    return AMAZON_CATEGORY_MAP.get(key, "everything_else")


def resolve_ebay_category(bsr_category: str) -> str:
    key = bsr_category.lower().strip() if bsr_category else ""
    return EBAY_CATEGORY_MAP.get(key, "everything_else")


def resolve_tiktok_category(bsr_category: str) -> str:
    key = bsr_category.lower().strip() if bsr_category else ""
    return TIKTOK_CATEGORY_MAP.get(key, "default")
