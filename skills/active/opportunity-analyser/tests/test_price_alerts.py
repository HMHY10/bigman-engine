"""Tests for Qogita price alert management."""
import json
import os
import sys
from datetime import datetime, timedelta

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))


@pytest.fixture
def alerts_dir(tmp_data_dir):
    d = os.path.join(str(tmp_data_dir), "price-alerts")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "active.json"), "w") as f:
        json.dump([], f)
    return d


class TestTargetPriceCalc:
    def test_calculates_profitable_price(self):
        from alerts.qogita_alerts import calculate_target_price
        target = calculate_target_price(
            current_buy_price=10.0,
            sell_price=15.0,
            fees=1.50,
            fulfilment=2.50,
            min_roi=20.0,
        )
        assert target is not None
        assert target < 10.0

    def test_already_profitable_returns_none(self):
        from alerts.qogita_alerts import calculate_target_price
        target = calculate_target_price(
            current_buy_price=5.0,
            sell_price=15.0,
            fees=1.50,
            fulfilment=2.50,
            min_roi=20.0,
        )
        assert target is None


class TestAlertEligibility:
    def test_review_within_gap_eligible(self):
        from alerts.qogita_alerts import is_alert_eligible
        eligible = is_alert_eligible(
            classification="review",
            target_price=8.50,
            current_price=10.0,
            margin_gap_threshold=0.20,
            est_monthly_sales=100,
            moq=24,
        )
        assert eligible is True

    def test_skip_too_far_ineligible(self):
        from alerts.qogita_alerts import is_alert_eligible
        eligible = is_alert_eligible(
            classification="skip",
            target_price=5.0,
            current_price=10.0,
            margin_gap_threshold=0.20,
            est_monthly_sales=50,
            moq=24,
        )
        assert eligible is False

    def test_high_demand_skip_eligible(self):
        from alerts.qogita_alerts import is_alert_eligible
        eligible = is_alert_eligible(
            classification="skip",
            target_price=5.0,
            current_price=10.0,
            margin_gap_threshold=0.20,
            est_monthly_sales=500,
            moq=24,
        )
        assert eligible is True


class TestAlertExpiry:
    def test_low_volume_gets_expiry(self):
        from alerts.qogita_alerts import calculate_expiry
        expiry = calculate_expiry(est_monthly_sales=10, moq=24)
        assert expiry is not None

    def test_high_volume_no_expiry(self):
        from alerts.qogita_alerts import calculate_expiry
        expiry = calculate_expiry(est_monthly_sales=500, moq=24)
        assert expiry is None

    def test_high_moq_relative_to_sales(self):
        from alerts.qogita_alerts import calculate_expiry
        expiry = calculate_expiry(est_monthly_sales=20, moq=500)
        assert expiry is not None
