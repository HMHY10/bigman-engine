"""Shared test fixtures for opportunity-analyser."""
import json
import os
import tempfile
from dataclasses import asdict
from unittest.mock import patch

import pytest

# Ensure imports work from skill root
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from models import Product, Opportunity, AmazonMatch, MarketData, Recommendation


@pytest.fixture
def sample_product():
    return Product(
        ean="5060462350018",
        name="CeraVe Moisturising Cream 454g",
        brand="CeraVe",
        buy_price=8.50,
        currency="GBP",
    )


@pytest.fixture
def sample_opportunity(sample_product, tmp_path):
    """Create a sample opportunity file (direct JSON, matching queue format)."""
    opp_data = {
        "id": "test-001",
        "source": "test",
        "supplier": "TestSupplier",
        "received_at": "2026-03-19T10:00:00Z",
        "products": [asdict(sample_product)],
    }
    path = tmp_path / "test-opp.json"
    path.write_text(json.dumps(opp_data))
    return Opportunity(id="test-001", source="test", supplier="TestSupplier",
                       received_at="2026-03-19T10:00:00Z", products=[sample_product]), str(path)


@pytest.fixture
def sample_amazon_match():
    return AmazonMatch(
        asin="B07Z4F5KLN",
        title="CeraVe Moisturising Cream 454g",
        brand="CeraVe",
        confidence=0.95,
    )


@pytest.fixture
def sample_market_data():
    return MarketData(
        buy_box_price=12.99,
        seller_count_total=8,
        bsr=1500,
        bsr_category="Health & Beauty",
        est_monthly_sales=450,
    )


@pytest.fixture
def tmp_data_dir(tmp_path):
    """Create temporary data directory structure."""
    for subdir in ["ebay", "competitor", "competitor-snapshots", "price-alerts"]:
        (tmp_path / subdir).mkdir(parents=True)
    return tmp_path
