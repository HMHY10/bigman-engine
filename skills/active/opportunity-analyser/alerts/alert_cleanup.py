#!/usr/bin/env python3
"""Monthly alert cleanup — prune expired alerts from active.json.

Cron: 0 5 1 * * (1st of month, 5am)
"""
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import config
from alerts.qogita_alerts import load_active_alerts, save_active_alerts, log


def cleanup():
    """Remove expired alerts."""
    active = load_active_alerts()
    before = len(active)
    today = datetime.now().strftime("%Y-%m-%d")

    remaining = []
    for alert in active:
        expiry = alert.get("expiry_date")
        if expiry and expiry < today:
            log(f"expired: {alert['ean']} ({alert['product_name']}) — set {alert['date_set']}, expired {expiry}")
        else:
            remaining.append(alert)

    save_active_alerts(remaining)
    removed = before - len(remaining)
    log(f"cleanup done: {removed} expired alerts removed, {len(remaining)} remaining")


if __name__ == "__main__":
    cleanup()
