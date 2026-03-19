import json
import os
"""Stage 3: Market analysis — BSR, sellers, sales estimates, pricing."""
from clients import sp_api, rainforest, baselinker
from clients.ebay import EbayClient
from config import RAINFOREST_PRIORITY
from models import AmazonMatch, MarketData, Product
from vault import log

# BSR to monthly sales rough lookup (Amazon UK, Health & Beauty)
BSR_SALES_TABLE = [
    (100, 3000), (500, 1500), (1000, 900), (2500, 500),
    (5000, 300), (10000, 150), (25000, 60), (50000, 30),
    (100000, 10), (250000, 3), (500000, 1),
]


def run(product: Product, match: AmazonMatch) -> MarketData:
    """Gather market data from all available sources."""
    data = MarketData()

    # 1. SP-API competitive pricing (primary)
    pricing = sp_api.get_competitive_pricing(match.asin)
    _extract_sp_pricing(pricing, data)

    # 2. BaseLinker internal sales data
    velocity = baselinker.get_product_sales_velocity(product.ean)
    if velocity:
        data.internal_velocity = velocity

    # 3. Rainforest API (backup — only if needed and budget allows)
    if RAINFOREST_PRIORITY == "primary" or (data.est_monthly_sales == 0 and rainforest.budget_remaining() > 0):
        rf_data = rainforest.get_product(match.asin)
        if rf_data:
            _extract_rainforest(rf_data, data)

    # 4. BSR-based estimation fallback
    if data.est_monthly_sales == 0 and data.bsr > 0:
        data.est_monthly_sales = _bsr_to_sales(data.bsr)
        data.data_source = "bsr_estimate"

    log(f"stage3: {match.asin} — buybox=£{data.buy_box_price:.2f}, sellers={data.seller_count_total}, bsr={data.bsr}, est_sales={data.est_monthly_sales}/mo")
    return data


def _extract_sp_pricing(pricing: dict, data: MarketData):
    """Extract pricing data from SP-API response."""
    if not pricing:
        return

    # Handle list response (getCompetitivePricing returns a list)
    products = pricing if isinstance(pricing, list) else [pricing]
    for p in products:
        product_data = p.get("Product", p.get("product", {}))
        comp = product_data.get("CompetitivePricing", {})

        # Buy Box price
        prices = comp.get("CompetitivePrices", [])
        for price in prices:
            if price.get("belongsToRequester", False) is False and price.get("CompetitivePriceId") == "1":
                listing_price = price.get("Price", {}).get("ListingPrice", {})
                data.buy_box_price = float(listing_price.get("Amount", 0))

        # Number of offer listings
        offers = comp.get("NumberOfOfferListings", [])
        for offer in offers:
            condition = offer.get("condition", "")
            count = int(offer.get("Count", 0))
            if condition == "New":
                data.seller_count_total = count

        # Sales rank
        ranks = product_data.get("SalesRankings", [])
        for rank in ranks:
            data.bsr = int(rank.get("Rank", 0))
            data.bsr_category = rank.get("ProductCategoryId", "")
            break  # first rank is primary

    data.data_source = "sp_api"


def _extract_rainforest(rf_data: dict, data: MarketData):
    """Extract data from Rainforest API response."""
    if not rf_data:
        return

    if rf_data.get("buybox_winner", {}).get("price", {}).get("value"):
        data.buy_box_price = float(rf_data["buybox_winner"]["price"]["value"])

    data.review_count = int(rf_data.get("ratings_total", 0))
    data.review_rating = float(rf_data.get("rating", 0))

    # Rainforest sales estimate
    if rf_data.get("estimated_monthly_sales"):
        data.est_monthly_sales = int(rf_data["estimated_monthly_sales"])
        data.data_source = "rainforest"

    # BSR from Rainforest
    bestsellers_rank = rf_data.get("bestsellers_rank", [])
    if bestsellers_rank:
        data.bsr = int(bestsellers_rank[0].get("rank", 0))
        data.bsr_category = bestsellers_rank[0].get("category", "")


def _bsr_to_sales(bsr: int) -> int:
    """Rough BSR to monthly sales estimate (Amazon UK Health & Beauty)."""
    for threshold, sales in BSR_SALES_TABLE:
        if bsr <= threshold:
            return sales
    return 0
