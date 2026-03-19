"""eBay Marketplace Insights API client.

Fetches sold item data (last 90 days) by GTIN for demand estimation.
Limited Release API — gracefully returns None if credentials not configured.
"""
import base64
import json
import os
import time
from datetime import datetime, date

import requests

import config

SKILL = "opportunity-analyser"
TOKEN_URL = "https://api.ebay.com/identity/v1/oauth2/token"
SEARCH_URL = "https://api.ebay.com/buy/marketplace_insights/v1_beta/item_sales/search"


def log(msg):
    print(f"{datetime.now().isoformat()} [{SKILL}:ebay] {msg}")


class EbayClient:
    def __init__(self, data_dir=None):
        self.app_id = os.getenv("EBAY_APP_ID", "")
        self.cert_id = os.getenv("EBAY_CERT_ID", "")
        self.available = bool(self.app_id and self.cert_id)
        self.data_dir = data_dir or config.INTEL_ROOT
        self.cache_dir = os.path.join(self.data_dir, "ebay")
        os.makedirs(self.cache_dir, exist_ok=True)
        self._token = None
        self._token_expiry = 0
        self._budget_remaining = self._load_budget()
        self.domain = getattr(config, "EBAY_DOMAIN", "EBAY_GB")
        self.cache_ttl = getattr(config, "EBAY_CACHE_TTL_DAYS", 7) * 86400

    # ── Auth ──────────────────────────────────────────

    def _get_token(self):
        """Get OAuth2 application token (client credentials grant)."""
        if self._token and time.time() < self._token_expiry - 60:
            return self._token
        creds = base64.b64encode(f"{self.app_id}:{self.cert_id}".encode()).decode()
        resp = requests.post(
            TOKEN_URL,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": f"Basic {creds}",
            },
            data={
                "grant_type": "client_credentials",
                "scope": "https://api.ebay.com/oauth/api_scope/buy.marketplace.insights",
            },
            timeout=15,
        )
        if resp.status_code != 200:
            log(f"auth failed: {resp.status_code} {resp.text[:200]}")
            return None
        data = resp.json()
        self._token = data["access_token"]
        self._token_expiry = time.time() + data.get("expires_in", 7200)
        return self._token

    # ── Budget ────────────────────────────────────────

    def _budget_file(self):
        return os.path.join(self.data_dir, "ebay-budget.json")

    def _load_budget(self):
        budget = getattr(config, "EBAY_DAILY_BUDGET", 500)
        path = self._budget_file()
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
            if data.get("date") == str(date.today()):
                return max(0, budget - data.get("used", 0))
        return budget

    def _record_call(self):
        self._budget_remaining -= 1
        path = self._budget_file()
        today = str(date.today())
        used = 1
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
            if data.get("date") == today:
                used = data.get("used", 0) + 1
        with open(path, "w") as f:
            json.dump({"date": today, "used": used}, f)

    # ── Cache ─────────────────────────────────────────

    def _cache_path(self, gtin):
        return os.path.join(self.cache_dir, f"{gtin}.json")

    def _read_cache(self, gtin):
        path = self._cache_path(gtin)
        if not os.path.exists(path):
            return None
        with open(path) as f:
            data = json.load(f)
        if time.time() - data.get("cached_at", 0) > self.cache_ttl:
            return None
        return data

    def _write_cache(self, gtin, data):
        data["cached_at"] = time.time()
        with open(self._cache_path(gtin), "w") as f:
            json.dump(data, f, indent=2)

    # ── Search ────────────────────────────────────────

    def get_sold_data(self, gtin, keyword=None):
        """Get sold item data for a GTIN. Returns dict or None."""
        if not self.available:
            return None

        cached = self._read_cache(gtin)
        if cached:
            return cached

        if self._budget_remaining <= 0:
            log(f"budget exhausted, skipping {gtin}")
            return None

        token = self._get_token()
        if not token:
            return None

        query = f"gtin:{gtin}" if gtin else keyword
        if not query:
            return None

        try:
            resp = requests.get(
                SEARCH_URL,
                headers={"Authorization": f"Bearer {token}"},
                params={
                    "q": query,
                    "filter": f"buyingOptions:{{FIXED_PRICE}},conditionIds:{{1000}},marketplace_id:{{{self.domain}}}",
                    "limit": "50",
                },
                timeout=20,
            )
            self._record_call()

            if resp.status_code != 200:
                log(f"search failed for {gtin}: {resp.status_code}")
                return None

            data = resp.json()
            items = data.get("itemSales", [])
            if not items:
                log(f"no sold data for {gtin}")
                result = {"total_sold": 0, "price_range": None, "sell_through": None}
                self._write_cache(gtin, result)
                return result

            prices = []
            total_sold = 0
            for item in items:
                price_val = item.get("lastSoldPrice", {}).get("value")
                if price_val:
                    prices.append(float(price_val))
                total_sold += item.get("totalSoldQuantity", 0)

            result = {
                "total_sold": total_sold,
                "price_range": {
                    "min": min(prices) if prices else None,
                    "max": max(prices) if prices else None,
                    "avg": round(sum(prices) / len(prices), 2) if prices else None,
                },
                "sell_through": round(total_sold / max(len(items), 1), 2),
                "item_count": len(items),
            }
            self._write_cache(gtin, result)
            log(f"{gtin}: {total_sold} sold, £{result['price_range']['min']}-{result['price_range']['max']}")
            return result

        except Exception as e:
            log(f"error fetching {gtin}: {e}")
            return None
