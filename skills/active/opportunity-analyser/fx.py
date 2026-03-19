"""Currency conversion with daily rate caching. Uses free exchangerate-api."""
import json
import os
import time

import requests

from config import STATE_DIR
from vault import log

_CACHE_FILE = f"{STATE_DIR}/fx-rates.json"
_API_URL = "https://open.er-api.com/v6/latest/EUR"

# In-process cache to avoid disk reads on every convert() call
_rates_mem: dict = {}
_rates_mem_at: float = 0.0


def _load_cache() -> dict:
    if os.path.exists(_CACHE_FILE):
        with open(_CACHE_FILE) as f:
            data = json.load(f)
        # Cache valid for 24h
        if time.time() - data.get("fetched_at", 0) < 86400:
            return data.get("rates", {})
    return {}


def _fetch_rates() -> dict:
    try:
        resp = requests.get(_API_URL, timeout=10)
        if resp.status_code != 200:
            log(f"fx: HTTP {resp.status_code} fetching rates")
            return {}
        data = resp.json()
        rates = data.get("rates", {})
        os.makedirs(os.path.dirname(_CACHE_FILE), exist_ok=True)
        with open(_CACHE_FILE, "w") as f:
            json.dump({"fetched_at": time.time(), "rates": rates}, f)
        log(f"fx: fetched {len(rates)} rates (EUR base)")
        return rates
    except Exception as e:
        log(f"fx: error fetching rates: {e}")
        return {}


def convert(amount: float, from_currency: str, to_currency: str = "GBP") -> float | None:
    """Convert amount between currencies. Returns None if rate unavailable."""
    if from_currency == to_currency:
        return amount

    global _rates_mem, _rates_mem_at
    if _rates_mem and time.time() - _rates_mem_at < 86400:
        rates = _rates_mem
    else:
        rates = _load_cache() or _fetch_rates()
        if rates:
            _rates_mem = rates
            _rates_mem_at = time.time()
    if not rates:
        return None

    # Rates are EUR-based
    if from_currency == "EUR":
        rate = rates.get(to_currency)
        if rate:
            return round(amount * rate, 2)
    elif to_currency == "EUR":
        rate = rates.get(from_currency)
        if rate:
            return round(amount / rate, 2)
    else:
        # Cross-rate via EUR
        from_rate = rates.get(from_currency)
        to_rate = rates.get(to_currency)
        if from_rate and to_rate:
            return round(amount / from_rate * to_rate, 2)

    log(f"fx: no rate for {from_currency}→{to_currency}")
    return None
