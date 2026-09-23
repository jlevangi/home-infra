import sys
from pathlib import Path

# Add server or parent directory to path
server_dir = Path(__file__).resolve().parent.parent
if (server_dir / "ingester").exists():
    sys.path.insert(0, str(server_dir / "ingester"))
else:
    sys.path.insert(0, str(server_dir))

from app import ingest_telemetry, get_history, sanitize_telemetry, TelemetryPoint, get_dashboard, get_live

def test_telemetry_flow():
    # 1. Ingest batch with new metrics
    batch = [
        TelemetryPoint(
            uptime=100,
            vehicle="volvo",
            rpm=2250.0,
            speed_kph=68.0,
            coolant_c=90.0,
            load_pct=35.0,
            throttle_pct=20.0,
            voltage_v=14.2,
            map_kpa=150.0,
            baro_kpa=101.3,
            maf_gps=25.0,
            stft_pct=1.5,
            ltft_pct=-0.5,
            timing_deg=16.0,
            smog_ready=True,
            vin="YV4TESTING1234567"
        )
    ]
    res = ingest_telemetry(batch)
    assert res["status"] == "ok"
    assert res["inserted"] == 1

    # 2. Check history
    hist = get_history(vehicle="volvo", limit=1)
    assert hist["count"] == 1
    assert hist["records"][0]["rpm"] == 2250.0
    assert hist["records"][0]["stft_pct"] == 1.5
    assert hist["records"][0]["vin"] == "YV4TESTING1234567"

    # 3. PID 015C raw 0xFF decodes to 215°C; reject that unavailable sentinel.
    guarded = sanitize_telemetry(TelemetryPoint(rpm=0.0, oil_temp_c=215.0))
    assert guarded.oil_temp_c != 215.0

    # 4. Engine-dependent sensors must be unavailable, not plausible-looking defaults.
    parked = sanitize_telemetry(TelemetryPoint(
        rpm=0.0, lambda_ratio=1.0, afr=14.7,
        cat_temp_c=0.0, fuel_rail_bar=0.0, fuel_status="Off"
    ))
    assert parked.lambda_ratio is None
    assert parked.afr is None
    assert parked.cat_temp_c is None
    assert parked.fuel_rail_bar is None
    assert parked.fuel_status is None

    # 5. Live endpoint and Web UI dashboard
    live = get_live()
    assert live["status"] == "ok"
    assert "data" in live
    assert live["data"]["rpm"] == 2250.0
    assert live["data"]["vin"] == "YV4TESTING1234567"
    assert live["data"]["speed_mph"] > 0

    dash = get_dashboard()
    assert dash is not None

    print("All telemetry self-checks passed directly against app logic!")

if __name__ == "__main__":
    test_telemetry_flow()
