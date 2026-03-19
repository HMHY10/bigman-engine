"""Tests for vault-intel adapter."""
import json
import os
import sys
from unittest.mock import patch, MagicMock
from datetime import datetime

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))


@pytest.fixture
def mock_vault_note():
    return """# Supplier Pricing - BeautyWholesale Ltd

Received via email on 2026-03-15.

## Products Offered
- CeraVe Moisturising Cream 454g (EAN: 5060462350018) - £7.20/unit, MOQ 48
- La Roche-Posay Effaclar Duo 40ml - £8.50/unit, MOQ 24
- Bioderma Sensibio H2O 500ml (EAN: 3401345935571) - £6.80/unit, MOQ 36

## Notes
Competitor pricing seen on Amazon: CeraVe 454g at £11.99 (was £12.99 last month).
"""


@pytest.fixture
def mock_haiku_response():
    return [
        {"ean": "5060462350018", "product": "CeraVe Moisturising Cream 454g",
         "competitor": "BeautyWholesale Ltd", "price": 7.20, "marketplace": "wholesale",
         "date": "2026-03-15"},
        {"ean": "3401345935571", "product": "Bioderma Sensibio H2O 500ml",
         "competitor": "BeautyWholesale Ltd", "price": 6.80, "marketplace": "wholesale",
         "date": "2026-03-15"},
    ]


class TestVaultIntelExtraction:
    def test_extract_pricing_from_note(self, mock_vault_note, mock_haiku_response, tmp_data_dir):
        from adapters.vault_intel import extract_pricing_signals
        with patch("adapters.vault_intel.call_haiku") as mock_call:
            mock_call.return_value = mock_haiku_response
            results = extract_pricing_signals(mock_vault_note, "test-note.md")
            assert len(results) == 2
            assert results[0]["ean"] == "5060462350018"
            assert results[0]["price"] == 7.20

    def test_empty_note_returns_empty(self, tmp_data_dir):
        from adapters.vault_intel import extract_pricing_signals
        with patch("adapters.vault_intel.call_haiku") as mock_call:
            mock_call.return_value = []
            results = extract_pricing_signals("No pricing info here.", "test-note.md")
            assert results == []


class TestVaultIntelDedup:
    def test_skip_already_processed(self, tmp_data_dir):
        from adapters.vault_intel import is_processed, mark_processed
        path = "07-Marketplace/Buying/Competitor/test.md"
        assert is_processed(path, "2026-03-15T10:00:00", str(tmp_data_dir)) is False
        mark_processed(path, "2026-03-15T10:00:00", str(tmp_data_dir))
        assert is_processed(path, "2026-03-15T10:00:00", str(tmp_data_dir)) is True

    def test_reprocess_if_modified(self, tmp_data_dir):
        from adapters.vault_intel import is_processed, mark_processed
        path = "07-Marketplace/Buying/Competitor/test.md"
        mark_processed(path, "2026-03-15T10:00:00", str(tmp_data_dir))
        assert is_processed(path, "2026-03-16T12:00:00", str(tmp_data_dir)) is False
