"""Tests for image & listing verification stage."""
import os
import sys
from unittest.mock import patch, MagicMock

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from stages.image_verify import detect_pack_size, verify_image, run


class TestPackSizeDetection:
    def test_detects_pack_of_3(self):
        assert detect_pack_size("CeraVe Moisturising Cream 454g Pack of 3") == 3

    def test_detects_x_notation(self):
        assert detect_pack_size("Bioderma Sensibio H2O 500ml x6") == 6

    def test_detects_multipack(self):
        assert detect_pack_size("La Roche-Posay Effaclar Duo Multipack") == 2

    def test_single_item(self):
        assert detect_pack_size("CeraVe Moisturising Cream 454g") == 1

    def test_detects_twin_pack(self):
        assert detect_pack_size("Nivea Soft Cream Twin Pack") == 2


class TestImageVerification:
    def test_verify_returns_pass(self):
        mock_response = {
            "pass": True,
            "confidence": 0.92,
            "flags": [],
            "pack_size_detected": 1,
        }
        with patch("stages.image_verify.download_image") as mock_dl, \
             patch("stages.image_verify.call_vision") as mock_call:
            mock_dl.return_value = ("fakebase64data", "image/jpeg")
            mock_call.return_value = mock_response
            result = verify_image("https://example.com/image.jpg", "CeraVe Cream", "5060462350018")
            assert result["pass"] is True
            assert result["confidence"] >= 0.7

    def test_verify_flags_counterfeit(self):
        mock_response = {
            "pass": False,
            "confidence": 0.85,
            "flags": ["counterfeit_indicators"],
            "pack_size_detected": 1,
        }
        with patch("stages.image_verify.download_image") as mock_dl, \
             patch("stages.image_verify.call_vision") as mock_call:
            mock_dl.return_value = ("fakebase64data", "image/jpeg")
            mock_call.return_value = mock_response
            result = verify_image("https://example.com/image.jpg", "CeraVe Cream", "5060462350018")
            assert result["pass"] is False
            assert "counterfeit_indicators" in result["flags"]

    def test_no_image_url_skips(self):
        result = verify_image(None, "CeraVe Cream", "5060462350018")
        assert result is None
