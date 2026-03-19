"""Rainforest API client for Amazon data enrichment. Budget-controlled."""
import json
import os
import time

import requests

from config import RAINFOREST_DAILY_BUDGET, INTEL_ROOT, STATE_DIR
from vault import log

API_KEY = os.getenv("RAINFOREST_API_KEY", "")
BASE_URL = "https://api.rainforestapi.com/request"
_COUNTER_FILE = f"{STATE_DIR}/rainforest-calls-today.json"


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


def budget_remaining() -> int:
    return max(0, RAINFOREST_DAILY_BUDGET - _get_daily_count())


def get_product(asin: str) -> dict | None:
    """Fetch product data from Rainforest API. Returns None if budget exhausted or error."""
    if not API_KEY:
        return None
    if budget_remaining() <= 0:
        log(f"rainforest: daily budget exhausted ({RAINFOREST_DAILY_BUDGET})")
        return None

    # Check cache
    cache_path = f"{INTEL_ROOT}/amazon/rainforest-{asin}.json"
    if os.path.exists(cache_path):
        age_hours = (time.time() - os.path.getmtime(cache_path)) / 3600
        if age_hours < 24:
            with open(cache_path) as f:
                return json.load(f)

    try:
        resp = requests.get(BASE_URL, params={
            "api_key": API_KEY,
            "type": "product",
            "asin": asin,
            "amazon_domain": "amazon.co.uk",
        }, timeout=30)
        _increment_count()

        if resp.status_code != 200:
            log(f"rainforest: HTTP {resp.status_code} for {asin}")
            return None

        data = resp.json().get("product", {})
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w") as f:
            json.dump(data, f)
        log(f"rainforest: fetched {asin} (budget remaining: {budget_remaining()})")
        return data
    except Exception as e:
        log(f"rainforest: error for {asin}: {e}")
        return None
