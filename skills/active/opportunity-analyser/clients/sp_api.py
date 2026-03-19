"""Amazon SP-API client wrapper. Thin layer over python-amazon-sp-api SDK."""
import json
import os
import time
from pathlib import Path

from sp_api.base import Marketplaces
from sp_api.api.catalog_items.catalog_items import CatalogItemsVersion

from config import INTEL_ROOT, SP_API_DAILY_BUDGET, STATE_DIR
from vault import log

# SP-API credentials from Doppler env
SP_CREDENTIALS = {
    "refresh_token": os.getenv("SP_API_REFRESH_TOKEN", ""),
    "lwa_app_id": os.getenv("SP_API_CLIENT_ID", ""),
    "lwa_client_secret": os.getenv("SP_API_CLIENT_SECRET", ""),
    "aws_access_key": os.getenv("SP_API_AWS_ACCESS_KEY", ""),
    "aws_secret_key": os.getenv("SP_API_AWS_SECRET_KEY", ""),
}
MARKETPLACE = Marketplaces.UK
MARKETPLACE_ID = MARKETPLACE.marketplace_id  # "A1F83G8C2ARO7P"
SELLER_ID = os.getenv("SP_API_SELLER_ID", "")

# Daily call counter
_COUNTER_FILE = f"{STATE_DIR}/sp-api-calls-today.json"


def _get_daily_count() -> int:
    if os.path.exists(_COUNTER_FILE):
        with open(_COUNTER_FILE) as f:
            data = json.load(f)
        if data.get("date") == time.strftime("%Y-%m-%d"):
            return data.get("count", 0)
    return 0


def _increment_count():
    count = _get_daily_count() + 1
    os.makedirs(os.path.dirname(_COUNTER_FILE), exist_ok=True)
    with open(_COUNTER_FILE, "w") as f:
        json.dump({"date": time.strftime("%Y-%m-%d"), "count": count}, f)


def _budget_available() -> bool:
    return _get_daily_count() < SP_API_DAILY_BUDGET


def _cache_path(category: str, key: str) -> str:
    d = f"{INTEL_ROOT}/{category}"
    os.makedirs(d, exist_ok=True)
    return f"{d}/{key}.json"


def _read_cache(category: str, key: str, max_age_hours: int = 24) -> dict | None:
    path = _cache_path(category, key)
    if not os.path.exists(path):
        return None
    age_hours = (time.time() - os.path.getmtime(path)) / 3600
    if age_hours > max_age_hours:
        return None
    with open(path) as f:
        return json.load(f)


def _write_cache(category: str, key: str, data: dict):
    path = _cache_path(category, key)
    with open(path, "w") as f:
        json.dump(data, f)


def search_by_ean(ean: str) -> list[dict]:
    """Search Amazon catalog by EAN. Returns list of matching items."""
    cached = _read_cache("amazon", f"ean-{ean}")
    if cached is not None:
        return cached.get("items", [])

    if not _budget_available():
        log(f"sp_api: daily budget exhausted ({SP_API_DAILY_BUDGET}), skipping EAN {ean}")
        return []

    try:
        from sp_api.api import CatalogItems
        catalog = CatalogItems(credentials=SP_CREDENTIALS, marketplace=MARKETPLACE,
                               version=CatalogItemsVersion.V_2022_04_01)
        response = catalog.search_catalog_items(
            identifiers=ean,
            identifiersType="EAN",
            marketplaceIds=MARKETPLACE_ID,
            includedData="identifiers,summaries,relationships,images",
        )
        _increment_count()
        items = response.payload.get("items", [])
        _write_cache("amazon", f"ean-{ean}", {"items": items})
        log(f"sp_api: EAN {ean} → {len(items)} matches")
        return items
    except Exception as e:
        log(f"sp_api: catalog search failed for EAN {ean}: {e}")
        _increment_count()
        return []


def get_restrictions(asin: str) -> dict:
    """Check selling restrictions for an ASIN."""
    cached = _read_cache("amazon", f"restrictions-{asin}")
    if cached is not None:
        return cached

    if not _budget_available():
        return {"status": "unknown", "reason": "budget_exhausted"}

    try:
        from sp_api.api import ListingsRestrictions
        restrictions = ListingsRestrictions(credentials=SP_CREDENTIALS, marketplace=MARKETPLACE)
        response = restrictions.get_listings_restrictions(
            asin=asin,
            sellerId=SELLER_ID,
            marketplaceIds=[MARKETPLACE_ID],
        )
        _increment_count()
        result = response.payload
        _write_cache("amazon", f"restrictions-{asin}", result)
        return result
    except Exception as e:
        log(f"sp_api: restrictions check failed for {asin}: {e}")
        _increment_count()
        return {"status": "error", "reason": str(e)}


def get_competitive_pricing(asin: str) -> dict:
    """Get Buy Box price, seller count, BSR for an ASIN."""
    cached = _read_cache("amazon", f"pricing-{asin}")
    if cached is not None:
        return cached

    if not _budget_available():
        return {}

    try:
        from sp_api.api import Products
        products = Products(credentials=SP_CREDENTIALS, marketplace=MARKETPLACE)
        response = products.get_competitive_pricing_for_asins([asin])
        _increment_count()
        result = response.payload
        _write_cache("amazon", f"pricing-{asin}", result)
        return result
    except Exception as e:
        log(f"sp_api: pricing failed for {asin}: {e}")
        _increment_count()
        return {}


def search_by_keywords(keywords: str, brand: str = "") -> list[dict]:
    """Fuzzy fallback: search catalog by keywords."""
    if not _budget_available():
        return []

    try:
        from sp_api.api import CatalogItems
        catalog = CatalogItems(credentials=SP_CREDENTIALS, marketplace=MARKETPLACE,
                               version=CatalogItemsVersion.V_2022_04_01)
        response = catalog.search_catalog_items(
            keywords=keywords,
            marketplaceIds=MARKETPLACE_ID,
            includedData="identifiers,summaries",
        )
        _increment_count()
        return response.payload.get("items", [])
    except Exception as e:
        log(f"sp_api: keyword search failed: {e}")
        _increment_count()
        return []


def extract_image_url(item):
    """Extract primary image URL from SP-API item response."""
    images = item.get("images", [])
    if images:
        for img_set in images:
            imgs = img_set.get("images", [])
            if imgs:
                # Prefer MAIN variant
                main = [i for i in imgs if i.get("variant") == "MAIN"]
                if main:
                    return main[0].get("link")
                return imgs[0].get("link")
    return None
