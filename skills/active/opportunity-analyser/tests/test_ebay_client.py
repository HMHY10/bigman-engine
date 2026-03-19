"""Tests for eBay Marketplace Insights API client."""
import json
import os
import sys
import time
from unittest.mock import patch, MagicMock

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from clients.ebay import EbayClient


@pytest.fixture
def client(tmp_data_dir):
    with patch.dict(os.environ, {
        "EBAY_APP_ID": "test-app-id",
        "EBAY_CERT_ID": "test-cert-id",
    }):
        c = EbayClient(data_dir=str(tmp_data_dir))
        yield c


@pytest.fixture
def mock_token_response():
    return {"access_token": "v^1.1#fake", "expires_in": 7200, "token_type": "Application Access Token"}


@pytest.fixture
def mock_search_response():
    return {
        "itemSales": [
            {
                "itemId": "v1|123|0",
                "title": "CeraVe Moisturising Cream 454g",
                "lastSoldPrice": {"value": "12.99", "currency": "GBP"},
                "totalSoldQuantity": 87,
                "lastSoldDate": "2026-03-15T10:00:00.000Z",
            },
            {
                "itemId": "v1|456|0",
                "title": "CeraVe Moisturising Cream 454g x2",
                "lastSoldPrice": {"value": "24.50", "currency": "GBP"},
                "totalSoldQuantity": 23,
                "lastSoldDate": "2026-03-10T10:00:00.000Z",
            },
        ],
        "total": 2,
    }


class TestEbayAuth:
    def test_no_credentials_returns_none(self, tmp_data_dir):
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("EBAY_APP_ID", None)
            os.environ.pop("EBAY_CERT_ID", None)
            c = EbayClient(data_dir=str(tmp_data_dir))
            assert c.available is False

    def test_auth_fetches_token(self, client, mock_token_response):
        with patch("clients.ebay.requests.post") as mock_post:
            mock_post.return_value = MagicMock(status_code=200, json=lambda: mock_token_response)
            token = client._get_token()
            assert token == "v^1.1#fake"


class TestEbaySoldSearch:
    def test_search_by_gtin(self, client, mock_token_response, mock_search_response):
        with patch("clients.ebay.requests.post") as mock_auth, \
             patch("clients.ebay.requests.get") as mock_get:
            mock_auth.return_value = MagicMock(status_code=200, json=lambda: mock_token_response)
            mock_get.return_value = MagicMock(status_code=200, json=lambda: mock_search_response)
            result = client.get_sold_data("5060462350018")
            assert result is not None
            assert result["total_sold"] == 110
            assert result["price_range"]["min"] == 12.99

    def test_returns_none_when_unavailable(self, tmp_data_dir):
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("EBAY_APP_ID", None)
            os.environ.pop("EBAY_CERT_ID", None)
            c = EbayClient(data_dir=str(tmp_data_dir))
            result = c.get_sold_data("5060462350018")
            assert result is None


class TestEbayCache:
    def test_cache_hit_skips_api(self, client, tmp_data_dir):
        cache_dir = os.path.join(str(tmp_data_dir), "ebay")
        cache_file = os.path.join(cache_dir, "5060462350018.json")
        cached = {
            "total_sold": 50, "price_range": {"min": 10.0, "max": 15.0, "avg": 12.5},
            "sell_through": 0.65, "cached_at": time.time(),
        }
        with open(cache_file, "w") as f:
            json.dump(cached, f)
        result = client.get_sold_data("5060462350018")
        assert result["total_sold"] == 50


class TestEbayBudget:
    def test_budget_exhausted_returns_none(self, client, mock_token_response):
        with patch("clients.ebay.requests.post") as mock_auth:
            mock_auth.return_value = MagicMock(status_code=200, json=lambda: mock_token_response)
            client._budget_remaining = 0
            result = client.get_sold_data("5060462350018")
            assert result is None
