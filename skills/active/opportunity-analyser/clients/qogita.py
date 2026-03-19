"""Qogita buyer API client. Auth via JWT, paginated catalog search, cart/checkout/orders."""
import json
import os
import time

import requests

from config import STATE_DIR
from vault import log

BASE_URL = "https://api.qogita.com"
EMAIL = os.getenv("QOGITA_BUYER_EMAIL", "")
PASSWORD = os.getenv("QOGITA_BUYER_PASSWORD", "")

_TOKEN_FILE = f"{STATE_DIR}/qogita-tokens.json"

# In-process token cache to avoid disk read on every API call
_cached_token: str = ""
_cached_token_expires: float = 0.0


def _load_tokens() -> dict:
    if os.path.exists(_TOKEN_FILE):
        with open(_TOKEN_FILE) as f:
            return json.load(f)
    return {}


def _save_tokens(tokens: dict):
    os.makedirs(os.path.dirname(_TOKEN_FILE), exist_ok=True)
    with open(_TOKEN_FILE, "w") as f:
        json.dump(tokens, f)


def _get_access_token() -> str:
    """Get valid access token, re-authenticating when expired."""
    global _cached_token, _cached_token_expires

    # Check in-process cache first (avoids disk read)
    # Qogita tokens expire in 5 min — use 30s buffer
    if _cached_token and time.time() < _cached_token_expires - 30:
        return _cached_token

    # Fall back to disk cache
    tokens = _load_tokens()
    access = tokens.get("access", "")
    expires = tokens.get("expires_at", 0)

    # Token still valid (with 30s buffer)
    if access and time.time() < expires - 30:
        _cached_token = access
        _cached_token_expires = expires
        return access

    # Full login (Qogita uses accessToken, no refresh tokens)
    if not EMAIL or not PASSWORD:
        log("qogita: QOGITA_BUYER_EMAIL/PASSWORD not set")
        return ""

    try:
        resp = requests.post(f"{BASE_URL}/auth/login/",
                             json={"email": EMAIL, "password": PASSWORD}, timeout=15)
        if resp.status_code == 200:
            data = resp.json()
            # Qogita returns accessToken + accessExp (ms timestamp)
            access_token = data.get("accessToken", "")
            access_exp = data.get("accessExp", 0)
            new_tokens = {
                "access": access_token,
                "expires_at": access_exp / 1000,  # convert ms to seconds
            }
            _save_tokens(new_tokens)
            _cached_token = access_token
            _cached_token_expires = access_exp / 1000
            log("qogita: logged in")
            return access_token
        else:
            log(f"qogita: login failed HTTP {resp.status_code}")
            return ""
    except Exception as e:
        log(f"qogita: login error: {e}")
        return ""


def _headers() -> dict:
    token = _get_access_token()
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def list_offers(page: int = 1, size: int = 100) -> dict:
    """List available offers. Returns {results: [...], count, next}.

    Each offer contains: variant (gtin, name, brand, category),
    price, priceCurrency, inventory, unit, qid.
    Note: category filtering via API param does not work — filter client-side.
    """
    params = {"page": page, "size": size}

    try:
        resp = requests.get(f"{BASE_URL}/offers/", headers=_headers(),
                            params=params, timeout=30)
        if resp.status_code == 429:
            retry_after = int(resp.headers.get("Retry-After", "60"))
            log(f"qogita: rate limited, retry after {retry_after}s")
            time.sleep(min(retry_after, 120))
            return {"results": [], "count": 0, "_retry": True}
        if resp.status_code != 200:
            log(f"qogita: offers failed HTTP {resp.status_code}")
            return {"results": [], "count": 0}
        data = resp.json()
        # Extract image URLs from offers
        for offer in data.get('results', []):
            image_url = offer.get('variant', {}).get('image', {}).get('url') or offer.get('image', '')
            offer['image_url'] = image_url
        return data
    except Exception as e:
        log(f"qogita: offers error: {e}")
        return {"results": [], "count": 0}


def get_offer(qid: str) -> dict | None:
    """Get a single offer by QID."""
    try:
        resp = requests.get(f"{BASE_URL}/offers/{qid}/", headers=_headers(), timeout=15)
        if resp.status_code == 200:
            return resp.json()
        return None
    except Exception:
        return None


def add_to_cart(gtin: str, quantity: int) -> dict | None:
    """Add item to active cart."""
    try:
        resp = requests.post(f"{BASE_URL}/carts/active/lines/", headers=_headers(),
                             json={"gtin": gtin, "quantity": quantity}, timeout=15)
        if resp.status_code in (200, 201):
            return resp.json()
        log(f"qogita: add to cart failed HTTP {resp.status_code}: {resp.text[:200]}")
        return None
    except Exception as e:
        log(f"qogita: add to cart error: {e}")
        return None


def get_cart() -> dict | None:
    """Get active cart."""
    try:
        resp = requests.get(f"{BASE_URL}/carts/active/", headers=_headers(), timeout=15)
        if resp.status_code == 200:
            return resp.json()
        return None
    except Exception:
        return None


def optimize_cart(cart_qid: str = "active") -> dict | None:
    """Optimize cart and create checkout."""
    try:
        resp = requests.post(f"{BASE_URL}/carts/{cart_qid}/optimize/",
                             headers=_headers(), timeout=30)
        if resp.status_code in (200, 201):
            return resp.json()
        log(f"qogita: optimize failed HTTP {resp.status_code}: {resp.text[:200]}")
        return None
    except Exception as e:
        log(f"qogita: optimize error: {e}")
        return None


def list_orders(status: str = "", page: int = 1, size: int = 50) -> dict:
    """List orders with optional status filter."""
    params = {"page": page, "size": size}
    if status:
        params["status"] = status
    try:
        resp = requests.get(f"{BASE_URL}/orders/", headers=_headers(),
                            params=params, timeout=15)
        if resp.status_code == 200:
            return resp.json()
        return {"results": [], "count": 0}
    except Exception:
        return {"results": [], "count": 0}
