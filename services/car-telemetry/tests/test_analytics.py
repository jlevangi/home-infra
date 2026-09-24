"""
Unit tests for analytics.py. Run with: python3 tests/test_analytics.py
"""

import sys
import unittest
from pathlib import Path

# Add ingester directory to path (handles both repo layouts)
test_dir = Path(__file__).resolve().parent
if (test_dir.parent / "ingester").exists():
    sys.path.insert(0, str(test_dir.parent / "ingester"))
else:
    sys.path.insert(0, str(test_dir.parent))

from analytics import compute_analytics, reset_trip_analytics


class TestAnalytics(unittest.TestCase):
    def setUp(self):
        reset_trip_analytics()

    def test_engine_off_defaults(self):
        state = {
            "rpm": 0.0,
            "speed_kph": 0.0,
            "speed_mph": 0.0,
            "coolant_c": 20.0,
            "voltage_v": 12.4,
            "timestamp": 1000.0,
        }
        res = compute_analytics(state)
        self.assertIsNone(res["volumetric_efficiency_pct"])
        self.assertIsNone(res["combustion_quality"])
        self.assertIsNone(res["fuel_trim_health"])
        self.assertEqual(res["battery_status"], "OK (Engine Off)")
        self.assertIsNone(res["engine_health_score"])

    def test_engine_running_computations(self):
        state = {
            "rpm": 2000.0,
            "speed_kph": 60.0,
            "speed_mph": 37.3,
            "maf_gps": 55.0,  # ~82% VE at 120 kPa MAP and 35C IAT
            "map_kpa": 120.0,
            "iat_c": 35.0,
            "coolant_c": 85.0,
            "baro_kpa": 101.3,
            "throttle_pct": 25.0,
            "pedal_pct": 20.0,
            "load_pct": 45.0,
            "boost_psi": 2.7,
            "stft_pct": 1.2,
            "ltft_pct": -0.8,
            "lambda_ratio": 1.0,
            "voltage_v": 14.2,
            "ambient_c": 25.0,
            "cat_temp_c": 650.0,
            "fuel_rail_bar": 120.0,
            "fuel_rate_lph": 8.5,
            "timestamp": 1000.0,
        }
        res = compute_analytics(state)
        self.assertIsNotNone(res["volumetric_efficiency_pct"])
        self.assertTrue(70 <= res["volumetric_efficiency_pct"] <= 95)
        self.assertEqual(res["combustion_quality"], 95.0)  # 100 - (1.2*2 + 0.8*3) = 95.2 -> 95
        self.assertEqual(res["fuel_trim_health"], "Healthy")
        self.assertEqual(res["intercooler_status"], "Normal")  # delta = 10C
        self.assertEqual(res["battery_status"], "Normal")
        self.assertEqual(res["efficiency_band"], "Optimal")
        self.assertGreaterEqual(res["engine_health_score"], 90.0)

    def test_fuel_trim_warnings(self):
        state = {
            "rpm": 1500.0,
            "speed_kph": 30.0,
            "stft_pct": 8.0,
            "ltft_pct": 10.0,  # total 18% -> Critical
            "voltage_v": 13.8,
            "timestamp": 1000.0,
        }
        res = compute_analytics(state)
        self.assertEqual(res["fuel_trim_health"], "Critical")
        self.assertLess(res["combustion_quality"], 60.0)

    def test_battery_states(self):
        states = [
            (11.5, True, 1500, "Critical"),
            (12.8, True, 1500, "Low"),
            (14.0, True, 1500, "Normal"),
            (15.2, True, 1500, "Overcharging"),
            (11.5, False, 0, "Weak (Engine Off)"),
            (12.5, False, 0, "OK (Engine Off)"),
        ]
        for v, eng, rpm, expected in states:
            s = {"voltage_v": v, "rpm": rpm, "speed_kph": 0.0, "timestamp": 1000.0}
            res = compute_analytics(s)
            self.assertEqual(res["battery_status"], expected, f"Failed for {v}V, eng={eng}")

    def test_warmup_detection(self):
        # Cold start
        s1 = {"rpm": 1200.0, "coolant_c": 30.0, "timestamp": 1000.0}
        r1 = compute_analytics(s1)
        self.assertTrue(r1["warmup_active"])
        self.assertIsNone(r1["warmup_seconds"])

        # Mid warmup
        s2 = {"rpm": 1000.0, "coolant_c": 60.0, "timestamp": 1100.0}
        r2 = compute_analytics(s2)
        self.assertTrue(r2["warmup_active"])

        # Reached warm (>80C)
        s3 = {"rpm": 800.0, "coolant_c": 82.0, "timestamp": 1300.0}
        r3 = compute_analytics(s3)
        self.assertFalse(r3["warmup_active"])
        self.assertEqual(r3["warmup_seconds"], 300.0)


if __name__ == "__main__":
    unittest.main()
