import hmac
import os
import time
from pathlib import Path
from typing import List
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

try:
    from .config import DB_PATH, STATIC_DIR
    from .models import TelemetryPoint, RECORD_SIZE
    from .database import init_db, store_telemetry_batch, fetch_history, fetch_latest_row
    from .processing import (
        sanitize_telemetry,
        update_derived_state,
        unpack_binary_payload
    )
    from .mqtt import MqttBridge
except ImportError:
    from config import DB_PATH, STATIC_DIR
    from models import TelemetryPoint, RECORD_SIZE
    from database import init_db, store_telemetry_batch, fetch_history, fetch_latest_row
    from processing import (
        sanitize_telemetry,
        update_derived_state,
        unpack_binary_payload
    )
    from mqtt import MqttBridge

mqtt_bridge = MqttBridge()
latest_state: dict = {}
INGEST_TOKEN = os.environ.get("CAR_TELEMETRY_INGEST_TOKEN", "")

def require_ingest_token(authorization: str | None):
    if not INGEST_TOKEN:
        raise HTTPException(status_code=503, detail="ingest authentication is not configured")
    scheme, _, supplied = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(supplied, INGEST_TOKEN):
        raise HTTPException(status_code=401, detail="invalid ingest credentials")

def hydrate_latest_state():
    global latest_state
    row = fetch_latest_row(DB_PATH)
    if not row:
        return
    try:
        tp = TelemetryPoint(
            uptime=row.get("uptime"),
            vehicle=row.get("vehicle", "volvo"),
            rpm=row.get("rpm", 0.0),
            speed_kph=row.get("speed_kph", 0.0),
            coolant_c=row.get("coolant_c", 0.0),
            load_pct=row.get("load_pct", 0.0),
            throttle_pct=row.get("throttle_pct", 0.0),
            voltage_v=row.get("voltage_v", 0.0),
            iat_c=row.get("iat_c"),
            fuel_pct=row.get("fuel_pct"),
            map_kpa=row.get("map_kpa"),
            maf_gps=row.get("maf_gps"),
            oil_temp_c=row.get("oil_temp_c"),
            runtime_s=row.get("runtime_s"),
            stft_pct=row.get("stft_pct"),
            ltft_pct=row.get("ltft_pct"),
            timing_deg=row.get("timing_deg"),
            baro_kpa=row.get("baro_kpa"),
            ambient_c=row.get("ambient_c"),
            pedal_pct=row.get("pedal_pct"),
            mil_dist_km=row.get("mil_dist_km"),
            mil_on=bool(row.get("mil_on")),
            dtc_count=row.get("dtc_count", 0),
            dtcs=row.get("dtcs", "none"),
            smog_ready=bool(row.get("smog_ready", 1)),
            vin=row.get("vin", "UNKNOWN"),
            lambda_ratio=row.get("lambda_ratio"),
            afr=row.get("afr"),
            cat_temp_c=row.get("cat_temp_c"),
            fuel_rail_bar=row.get("fuel_rail_bar"),
            fuel_status=row.get("fuel_status")
        )
        derived = update_derived_state(tp)
        if row.get("timestamp"):
            derived["timestamp"] = row["timestamp"]
        latest_state = derived
    except Exception as e:
        print("[INIT] Error hydrating latest state from DB:", e)

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db(DB_PATH)
    mqtt_bridge.connect()
    hydrate_latest_state()
    yield
    mqtt_bridge.disconnect()

app = FastAPI(
    title="Volvo Telemetry Ingester",
    version="2.3.0",
    lifespan=lifespan
)

if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

@app.api_route("/", methods=["GET", "HEAD"])
def get_dashboard():
    dashboard_file = STATIC_DIR / "index.html"
    if dashboard_file.exists():
        return FileResponse(str(dashboard_file), media_type="text/html")
    return HTMLResponse("<h1>Volvo Telemetry Dashboard</h1>", media_type="text/html")

@app.get("/api/live")
def get_live():
    age = None
    if "timestamp" in latest_state:
        age = round(time.time() - latest_state["timestamp"], 1)
    return {
        "status": "ok",
        "age_seconds": age,
        "data": latest_state
    }

@app.api_route("/healthz", methods=["GET", "HEAD"])
def healthz():
    return {
        "status": "ok",
        "mqtt_connected": mqtt_bridge.connected,
        "record_size_bytes": RECORD_SIZE,
        "db": str(DB_PATH)
    }

@app.post("/api/telemetry")
def ingest_telemetry(
    records: List[TelemetryPoint],
    authorization: str | None = Header(default=None)
):
    global latest_state
    require_ingest_token(authorization)
    if not records:
        return {"status": "empty", "inserted": 0}

    sanitized = [sanitize_telemetry(r) for r in records]
    inserted = store_telemetry_batch(sanitized, DB_PATH)

    latest_record = sanitized[-1]
    derived = update_derived_state(latest_record)
    latest_state = derived
    mqtt_bridge.publish_state(derived)

    return {"status": "ok", "inserted": inserted}

@app.post("/api/telemetry/binary")
async def ingest_binary_telemetry(
    request: Request,
    vehicle: str = "volvo",
    vin: str = "UNKNOWN",
    dtcs: str = "none",
    authorization: str | None = Header(default=None)
):
    global latest_state
    require_ingest_token(authorization)
    body = await request.body()
    if not body:
        return {"status": "empty", "inserted": 0}

    records = unpack_binary_payload(body, vehicle=vehicle, vin=vin, dtcs=dtcs)
    if not records:
        return {"status": "invalid_payload", "inserted": 0, "bytes": len(body)}

    inserted = store_telemetry_batch(records, DB_PATH)

    latest_record = records[-1]
    derived = update_derived_state(latest_record)
    latest_state = derived
    mqtt_bridge.publish_state(derived)

    return {"status": "ok", "inserted": inserted, "bytes": len(body)}

@app.get("/api/history")
def get_history(vehicle: str = "volvo", limit: int = 100):
    records = fetch_history(vehicle, limit, DB_PATH)
    return {"vehicle": vehicle, "count": len(records), "records": records}

@app.get("/api/dtc")
def get_dtc_diagnostics():
    return {
        "dtc_count": latest_state.get("dtc_count", 0),
        "dtcs": latest_state.get("dtcs", "none"),
        "mil_on": latest_state.get("mil_on", False),
        "smog_ready": latest_state.get("smog_ready", True)
    }
