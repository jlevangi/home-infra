import os
import sys
import tempfile
import struct
import unittest
from pathlib import Path

# Add project root and ingester directory to Python path
repo_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo_root))
sys.path.insert(0, str(repo_root / "ingester"))

from fastapi.testclient import TestClient
from ingester.models import (
    TelemetryPoint,
    BINARY_RECORD_FORMAT_V1, RECORD_SIZE_V1,
    BINARY_RECORD_FORMAT_V2, RECORD_SIZE_V2
)
from ingester.database import (
    init_db,
    store_telemetry_batch,
    fetch_history,
    fetch_latest_row
)
from ingester.processing import (
    decode_fuel_status,
    sanitize_telemetry,
    update_derived_state,
    unpack_binary_payload,
    trip_tracker
)
from ingester.app import app

class TestCarTelemetryPipeline(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.test_db = Path(self.temp_dir.name) / "test_telemetry.db"
        init_db(self.test_db)

    def tearDown(self):
        self.temp_dir.cleanup()

    # ---------------------------------------------------------
    # 1. Database tests
    # ---------------------------------------------------------
    def test_database_init_and_storage(self):
        self.assertTrue(self.test_db.exists(), "Database file should exist after init_db")

        point = TelemetryPoint(
            uptime=120,
            vehicle="volvo",
            rpm=2100.0,
            speed_kph=65.0,
            coolant_c=88.0,
            load_pct=42.0,
            throttle_pct=24.0,
            voltage_v=14.2,
            iat_c=25.0,
            fuel_pct=75.0,
            map_kpa=125.0,
            maf_gps=28.5,
            oil_temp_c=92.0,
            runtime_s=450,
            stft_pct=1.2,
            ltft_pct=-0.8,
            timing_deg=18.5,
            baro_kpa=101.3,
            ambient_c=22.0,
            pedal_pct=22.0,
            mil_dist_km=0,
            mil_on=False,
            dtc_count=0,
            dtcs="none",
            smog_ready=True,
            vin="YV4TEST1234567890",
            lambda_ratio=1.002,
            afr=14.73,
            cat_temp_c=480.0,
            fuel_rail_bar=115.0,
            fuel_status="Closed Loop"
        )

        inserted = store_telemetry_batch([point], self.test_db, timestamp=1700000000.0)
        self.assertEqual(inserted, 1)

        history = fetch_history(vehicle="volvo", limit=10, db_path=self.test_db)
        self.assertEqual(len(history), 1)
        record = history[0]
        self.assertEqual(record["rpm"], 2100.0)
        self.assertEqual(record["speed_kph"], 65.0)
        self.assertEqual(record["lambda_ratio"], 1.002)
        self.assertEqual(record["fuel_status"], "Closed Loop")

        latest = fetch_latest_row(self.test_db)
        self.assertIsNotNone(latest)
        self.assertEqual(latest["vin"], "YV4TEST1234567890")

    # ---------------------------------------------------------
    # 2. Binary Protocol Unpacking (V1 and V2)
    # ---------------------------------------------------------
    def test_binary_unpacking_v2(self):
        self.assertEqual(RECORD_SIZE_V2, 36)
        payload = struct.pack(
            BINARY_RECORD_FORMAT_V2,
            65000,          # uptime_ms (I)
            2450,           # rpm (H)
            72,             # speed_kph (B)
            90,             # coolant_c (b)
            45,             # load_pct (B)
            28,             # throttle_pct (B)
            14150,          # voltage_mv (H) -> 14.15V
            30,             # iat_c (b)
            70,             # fuel_pct (B)
            135,            # map_kpa (B)
            3450,           # maf_cgs (H) -> 34.50 g/s
            95,             # oil_temp_c (b)
            600,            # runtime_s (H)
            2,              # stft_pct (b)
            -1,             # ltft_pct (b)
            19,             # timing_deg (b)
            101,            # baro_kpa (B)
            24,             # ambient_c (b)
            26,             # pedal_pct (B)
            0,              # mil_dist_km (H)
            0,              # flags (B)
            995,            # lambda_x1000 (H) -> 0.995
            450,            # cat_temp_c (h) -> 450C
            125,            # fuel_rail_bar (H) -> 125 bar
            2               # fuel_status_code (B) -> 2 = Closed Loop
        )
        records = unpack_binary_payload(payload, vehicle="volvo", vin="YV4TEST1234567890")
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r.rpm, 2450.0)
        self.assertEqual(r.speed_kph, 72.0)
        self.assertEqual(r.voltage_v, 14.15)
        self.assertEqual(r.maf_gps, 34.50)
        self.assertEqual(r.lambda_ratio, 0.995)
        self.assertEqual(r.afr, 14.63)
        self.assertEqual(r.cat_temp_c, 450.0)
        self.assertEqual(r.fuel_rail_bar, 125.0)
        self.assertEqual(r.fuel_status, "Closed Loop")

    def test_binary_unpacking_v1_backward_compatibility(self):
        self.assertEqual(RECORD_SIZE_V1, 29)
        payload = struct.pack(
            BINARY_RECORD_FORMAT_V1,
            30000, 2000, 50, 85, 40, 20, 14200, 28, 65, 120, 2500, 90, 300, 0, 0, 15, 101, 22, 18, 0, 0
        )
        records = unpack_binary_payload(payload, vehicle="volvo")
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r.rpm, 2000.0)
        self.assertEqual(r.speed_kph, 50.0)
        self.assertIsNone(r.lambda_ratio)
        self.assertIsNone(r.cat_temp_c)
        self.assertIsNone(r.fuel_status)

    # ---------------------------------------------------------
    # 3. Physical Sanitization & Safety Guardrails
    # ---------------------------------------------------------
    def test_engine_off_guardrail(self):
        point = TelemetryPoint(
            rpm=150.0, # Below 300 RPM threshold
            speed_kph=45.0,
            load_pct=30.0,
            maf_gps=12.0,
            stft_pct=5.0,
            ltft_pct=2.0,
            timing_deg=10.0,
            lambda_ratio=0.98,
            afr=14.4,
            cat_temp_c=400.0,
            fuel_rail_bar=100.0,
            fuel_status="Closed Loop",
            throttle_pct=0.0,
            pedal_pct=0.0
        )
        sanitized = sanitize_telemetry(point)
        self.assertEqual(sanitized.rpm, 0.0)
        self.assertEqual(sanitized.speed_kph, 0.0)
        self.assertEqual(sanitized.load_pct, 0.0)
        self.assertEqual(sanitized.maf_gps, 0.0)
        self.assertIsNone(sanitized.lambda_ratio)
        self.assertIsNone(sanitized.afr)
        self.assertIsNone(sanitized.cat_temp_c)
        self.assertIsNone(sanitized.fuel_rail_bar)
        self.assertIsNone(sanitized.fuel_status)
        # Electronic throttle resting spring angle retained
        self.assertGreater(sanitized.throttle_pct, 0.0)

    def test_volvo_abs_offline_guardrail(self):
        point = TelemetryPoint(
            rpm=0.0,
            speed_kph=255.0, # 0xFF offline ABS indicator
            throttle_pct=18.0
        )
        sanitized = sanitize_telemetry(point)
        self.assertEqual(sanitized.speed_kph, 0.0)

        # High speed while driving is NOT clamped
        running_point = TelemetryPoint(
            rpm=4500.0,
            speed_kph=252.0,
            throttle_pct=85.0
        )
        sanitized_running = sanitize_telemetry(running_point)
        self.assertEqual(sanitized_running.speed_kph, 252.0)

    def test_unavailable_sentinels(self):
        point = TelemetryPoint(
            rpm=2000.0,
            oil_temp_c=-128.0 # Binary sentinel for unequipped/offline oil sensor
        )
        sanitized = sanitize_telemetry(point)
        self.assertIsNone(sanitized.oil_temp_c)

    # ---------------------------------------------------------
    # 4. Derived Metrics & State Machine
    # ---------------------------------------------------------
    def test_derived_metrics_and_drive_state(self):
        point = TelemetryPoint(
            rpm=2800.0,
            speed_kph=100.0,
            coolant_c=90.0,
            map_kpa=175.0,
            baro_kpa=101.3,
            maf_gps=50.0,
            throttle_pct=25.0
        )
        derived = update_derived_state(point, custom_now=1700000000.0)
        self.assertEqual(derived["speed_mph"], 62.1)
        self.assertEqual(derived["coolant_f"], 194.0)
        self.assertEqual(derived["drive_state"], "Cruising")
        # Boost = (175 - 101.3) * 0.145038 = 73.7 * 0.145038 = 10.7 PSI
        self.assertAlmostEqual(derived["boost_psi"], 10.7, places=1)
        self.assertGreater(derived["est_horsepower"], 0.0)

    # ---------------------------------------------------------
    # 5. FastAPI Endpoints Integration
    # ---------------------------------------------------------
    def test_api_endpoints_pipeline(self):
        client = TestClient(app)

        # Healthcheck
        r = client.get("/healthz")
        self.assertEqual(r.status_code, 200)
        data = r.json()
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["record_size_bytes"], 36)

        # Live endpoint
        r = client.get("/api/live")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["status"], "ok")

        # JSON Telemetry ingestion
        sample_point = {
            "uptime": 100,
            "vehicle": "volvo",
            "rpm": 1800.0,
            "speed_kph": 50.0,
            "coolant_c": 85.0,
            "load_pct": 35.0,
            "throttle_pct": 20.0,
            "voltage_v": 14.1
        }
        r = client.post("/api/telemetry", json=[sample_point])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["inserted"], 1)

        # History endpoint
        r = client.get("/api/history?limit=5")
        self.assertEqual(r.status_code, 200)
        self.assertIn("records", r.json())

        # DTC endpoint
        r = client.get("/api/dtc")
        self.assertEqual(r.status_code, 200)
        self.assertIn("dtc_count", r.json())

        # Dashboard UI
        r = client.get("/")
        self.assertEqual(r.status_code, 200)
        self.assertIn("text/html", r.headers["content-type"])

if __name__ == "__main__":
    unittest.main()
