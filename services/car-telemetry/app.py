import os
import time
import json
import sqlite3
import struct
import urllib.request
from pathlib import Path
from typing import List, Optional
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import paho.mqtt.client as mqtt

# SQLite database path
DB_PATH = Path(os.environ.get("CAR_TELEMETRY_DB", "/home/pierce/workspace/car-telemetry/telemetry.db"))

app = FastAPI(title="Volvo Telemetry Ingester", version="2.2.0")
static_dir = Path(__file__).resolve().parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

DEVICE_INFO = {
    "identifiers": ["volvo_xc60_telemetry"],
    "name": "Volvo XC60 Telemetry",
    "model": "XC60 (OBD-II)",
    "manufacturer": "Volvo"
}
STATE_TOPIC = "homeassistant/sensor/volvo_xc60/state"

MQTT_SENSORS = [
    # 1. Electrical & Core Engine
    {
        "id": "battery_voltage",
        "comp": "sensor",
        "cfg": {
            "name": "Battery Voltage",
            "unique_id": "volvo_xc60_battery_voltage",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.voltage_v | round(1) }}",
            "unit_of_measurement": "V",
            "device_class": "voltage",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "engine_rpm",
        "comp": "sensor",
        "cfg": {
            "name": "Engine RPM",
            "unique_id": "volvo_xc60_engine_rpm",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.rpm | round(0) }}",
            "unit_of_measurement": "rpm",
            "icon": "mdi:gauge",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "vehicle_speed",
        "comp": "sensor",
        "cfg": {
            "name": "Vehicle Speed",
            "unique_id": "volvo_xc60_vehicle_speed",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.speed_kph | round(0) }}",
            "unit_of_measurement": "km/h",
            "device_class": "speed",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "coolant_temperature",
        "comp": "sensor",
        "cfg": {
            "name": "Coolant Temperature",
            "unique_id": "volvo_xc60_coolant_temperature",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.coolant_c | round(0) }}",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "oil_temperature",
        "comp": "sensor",
        "cfg": {
            "name": "Oil Temperature",
            "unique_id": "volvo_xc60_oil_temperature",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.oil_temp_c | round(0) }}",
            "availability_topic": STATE_TOPIC,
            "availability_template": "{{ 'online' if value_json.oil_temp_c is number else 'offline' }}",
            "payload_available": "online",
            "payload_not_available": "offline",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 2. Performance & Boost
    {
        "id": "turbo_boost",
        "comp": "sensor",
        "cfg": {
            "name": "Turbo Boost",
            "unique_id": "volvo_xc60_turbo_boost",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.boost_psi | round(1) }}",
            "unit_of_measurement": "psi",
            "icon": "mdi:gauge",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "estimated_power",
        "comp": "sensor",
        "cfg": {
            "name": "Estimated Engine Power",
            "unique_id": "volvo_xc60_estimated_power",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.est_horsepower | round(0) }}",
            "unit_of_measurement": "hp",
            "icon": "mdi:horse",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 3. Fuel Economy & Rates
    {
        "id": "instant_fuel_economy",
        "comp": "sensor",
        "cfg": {
            "name": "Instant Fuel Economy",
            "unique_id": "volvo_xc60_instant_fuel_economy",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.instant_mpg | round(1) }}",
            "unit_of_measurement": "mpg",
            "icon": "mdi:gas-station-outline",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "fuel_rate",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel Consumption Rate",
            "unique_id": "volvo_xc60_fuel_rate",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_rate_lph | round(2) }}",
            "unit_of_measurement": "L/h",
            "icon": "mdi:fuel",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "fuel_level",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel Tank Level",
            "unique_id": "volvo_xc60_fuel_level",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:gas-station",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 4. Driver Inputs & Tuning Health
    {
        "id": "engine_load",
        "comp": "sensor",
        "cfg": {
            "name": "Engine Load",
            "unique_id": "volvo_xc60_engine_load",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.load_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:engine",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "throttle_position",
        "comp": "sensor",
        "cfg": {
            "name": "Throttle Position",
            "unique_id": "volvo_xc60_throttle_position",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.throttle_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:car-cruise-control",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "accelerator_pedal",
        "comp": "sensor",
        "cfg": {
            "name": "Accelerator Pedal Position",
            "unique_id": "volvo_xc60_accelerator_pedal",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.pedal_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:car-seat-cooler",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "short_term_fuel_trim",
        "comp": "sensor",
        "cfg": {
            "name": "Short Term Fuel Trim",
            "unique_id": "volvo_xc60_short_term_fuel_trim",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.stft_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:tune",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "long_term_fuel_trim",
        "comp": "sensor",
        "cfg": {
            "name": "Long Term Fuel Trim",
            "unique_id": "volvo_xc60_long_term_fuel_trim",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.ltft_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:tune-vertical",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "timing_advance",
        "comp": "sensor",
        "cfg": {
            "name": "Ignition Timing Advance",
            "unique_id": "volvo_xc60_timing_advance",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.timing_deg | round(1) }}",
            "unit_of_measurement": "°",
            "icon": "mdi:flash",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 5. Environmental & Diagnostics
    {
        "id": "intake_air_temperature",
        "comp": "sensor",
        "cfg": {
            "name": "Intake Air Temperature",
            "unique_id": "volvo_xc60_intake_air_temperature",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.iat_c | round(0) }}",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "ambient_temperature",
        "comp": "sensor",
        "cfg": {
            "name": "Ambient Outside Temperature",
            "unique_id": "volvo_xc60_ambient_temperature",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.ambient_c | round(0) }}",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "barometric_pressure",
        "comp": "sensor",
        "cfg": {
            "name": "Barometric Pressure",
            "unique_id": "volvo_xc60_barometric_pressure",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.baro_kpa | round(0) }}",
            "unit_of_measurement": "kPa",
            "device_class": "pressure",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "vin",
        "comp": "sensor",
        "cfg": {
            "name": "Vehicle VIN",
            "unique_id": "volvo_xc60_vin",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.vin }}",
            "icon": "mdi:card-account-details",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "trouble_codes",
        "comp": "sensor",
        "cfg": {
            "name": "Diagnostic Trouble Codes",
            "unique_id": "volvo_xc60_trouble_codes",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.dtcs }}",
            "icon": "mdi:car-wrench",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "check_engine_light",
        "comp": "binary_sensor",
        "cfg": {
            "name": "Check Engine Light",
            "unique_id": "volvo_xc60_check_engine_light",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ 'ON' if value_json.mil_on else 'OFF' }}",
            "payload_on": "ON",
            "payload_off": "OFF",
            "device_class": "problem",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "smog_ready",
        "comp": "binary_sensor",
        "cfg": {
            "name": "Smog / Emissions Ready",
            "unique_id": "volvo_xc60_smog_ready",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ 'OFF' if value_json.smog_ready else 'ON' }}",
            "payload_on": "ON",
            "payload_off": "OFF",
            "device_class": "problem",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "engine_running",
        "comp": "binary_sensor",
        "cfg": {
            "name": "Engine Running",
            "unique_id": "volvo_xc60_engine_running",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ 'ON' if value_json.rpm > 300 else 'OFF' }}",
            "payload_on": "ON",
            "payload_off": "OFF",
            "device_class": "running",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "drive_state",
        "comp": "sensor",
        "cfg": {
            "name": "Drive State",
            "unique_id": "volvo_xc60_drive_state",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.drive_state }}",
            "icon": "mdi:car-side",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "trip_distance",
        "comp": "sensor",
        "cfg": {
            "name": "Trip Distance",
            "unique_id": "volvo_xc60_trip_distance",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.trip_miles }}",
            "unit_of_measurement": "mi",
            "device_class": "distance",
            "state_class": "total",
            "icon": "mdi:map-marker-distance",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "trip_fuel",
        "comp": "sensor",
        "cfg": {
            "name": "Trip Fuel Used",
            "unique_id": "volvo_xc60_trip_fuel",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.trip_fuel_gal }}",
            "unit_of_measurement": "gal",
            "state_class": "total",
            "icon": "mdi:gas-station",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "trip_avg_mpg",
        "comp": "sensor",
        "cfg": {
            "name": "Trip Average MPG",
            "unique_id": "volvo_xc60_trip_avg_mpg",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.trip_avg_mpg }}",
            "unit_of_measurement": "mpg",
            "state_class": "measurement",
            "icon": "mdi:chart-line",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "afr",
        "comp": "sensor",
        "cfg": {
            "name": "Air-Fuel Ratio",
            "unique_id": "volvo_xc60_afr",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.afr }}",
            "availability_topic": STATE_TOPIC,
            "availability_template": "{{ 'online' if value_json.afr is number else 'offline' }}",
            "payload_available": "online",
            "payload_not_available": "offline",
            "unit_of_measurement": ":1",
            "state_class": "measurement",
            "icon": "mdi:gauge",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "lambda",
        "comp": "sensor",
        "cfg": {
            "name": "Lambda Equivalence",
            "unique_id": "volvo_xc60_lambda",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.lambda_ratio }}",
            "availability_topic": STATE_TOPIC,
            "availability_template": "{{ 'online' if value_json.lambda_ratio is number else 'offline' }}",
            "payload_available": "online",
            "payload_not_available": "offline",
            "unit_of_measurement": "λ",
            "state_class": "measurement",
            "icon": "mdi:lambda",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "cat_temp",
        "comp": "sensor",
        "cfg": {
            "name": "Catalyst Temperature",
            "unique_id": "volvo_xc60_cat_temp",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.cat_temp_c }}",
            "availability_topic": STATE_TOPIC,
            "availability_template": "{{ 'online' if value_json.cat_temp_c is number else 'offline' }}",
            "payload_available": "online",
            "payload_not_available": "offline",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "icon": "mdi:thermometer-high",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "fuel_rail_pressure",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel Rail Pressure",
            "unique_id": "volvo_xc60_fuel_rail",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_rail_bar }}",
            "availability_topic": STATE_TOPIC,
            "availability_template": "{{ 'online' if value_json.fuel_rail_bar is number else 'offline' }}",
            "payload_available": "online",
            "payload_not_available": "offline",
            "unit_of_measurement": "bar",
            "device_class": "pressure",
            "state_class": "measurement",
            "icon": "mdi:gauge",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "fuel_status",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel System Status",
            "unique_id": "volvo_xc60_fuel_status",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_status }}",
            "icon": "mdi:engine",
            "device": DEVICE_INFO
        }
    }
]

mqtt_client = None

# Binary packet format V1 (29 bytes packed)
BINARY_RECORD_FORMAT_V1 = "<IHBbBBHbBBHbHbbbBbBHB"
RECORD_SIZE_V1 = struct.calcsize(BINARY_RECORD_FORMAT_V1)

# Binary packet format V2 (36 bytes packed): adds lambda_x1000 (H), cat_temp (h), fuel_rail_bar (H), fuel_status (B)
BINARY_RECORD_FORMAT_V2 = "<IHBbBBHbBBHbHbbbBbBHBHhHB"
RECORD_SIZE_V2 = struct.calcsize(BINARY_RECORD_FORMAT_V2)

BINARY_RECORD_FORMAT = BINARY_RECORD_FORMAT_V2
RECORD_SIZE = RECORD_SIZE_V2

def get_mqtt_credentials():
    # 1. Environment variables (Kubernetes ExternalSecrets / container config)
    env_host = os.environ.get("MQTT_HOST")
    if env_host:
        return {
            "host": env_host,
            "port": int(os.environ.get("MQTT_PORT", 1883)),
            "username": os.environ.get("MQTT_USERNAME", ""),
            "password": os.environ.get("MQTT_PASSWORD", "")
        }

    # 2. Local Vault AppRole token check (host/VM fallback)
    try:
        role_path = os.path.expanduser("~/.config/hermes/vault-role-id")
        secret_path = os.path.expanduser("~/.config/hermes/vault-secret-id")
        if not (os.path.exists(role_path) and os.path.exists(secret_path)):
            return None

        role_id = open(role_path).read().strip()
        secret_id = open(secret_path).read().strip()

        req = urllib.request.Request(
            "https://vault.levangie.dev/v1/auth/approle/login",
            data=json.dumps({"role_id": role_id, "secret_id": secret_id}).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        token = json.loads(urllib.request.urlopen(req, timeout=5).read().decode("utf-8"))["auth"]["client_token"]

        req2 = urllib.request.Request(
            "https://vault.levangie.dev/v1/kv/data/hermes/shared",
            headers={"X-Vault-Token": token}
        )
        data = json.loads(urllib.request.urlopen(req2, timeout=5).read().decode("utf-8"))["data"]["data"]
        return {
            "host": data.get("MQTT_HOST", "172.20.20.21"),
            "port": int(data.get("MQTT_PORT", 1883)),
            "username": data.get("MQTT_USERNAME", ""),
            "password": data.get("MQTT_PASSWORD", "")
        }
    except Exception as e:
        print("[MQTT] Vault credential fetch failed:", e)
        return None

def init_mqtt():
    global mqtt_client
    creds = get_mqtt_credentials()
    if not creds:
        print("[MQTT] No credentials available, skipping MQTT setup.")
        return

    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="volvo_telemetry_ingester")
        client.username_pw_set(creds["username"], creds["password"])
        client.connect(creds["host"], creds["port"], 60)
        client.loop_start()

        for s in MQTT_SENSORS:
            topic = f"homeassistant/{s['comp']}/volvo_xc60/{s['id']}/config"
            client.publish(topic, json.dumps(s["cfg"]), retain=True)

        mqtt_client = client
        print("[MQTT] Connected to Home Assistant broker and discovery configs published.")
    except Exception as e:
        print("[MQTT] Failed to initialize MQTT client:", e)

class TelemetryPoint(BaseModel):
    uptime: Optional[int] = None
    vehicle: str = "volvo"
    rpm: float = 0.0
    speed_kph: float = 0.0
    coolant_c: float = 0.0
    load_pct: float = 0.0
    throttle_pct: float = 0.0
    voltage_v: float = 0.0
    iat_c: Optional[float] = None
    fuel_pct: Optional[float] = None
    map_kpa: Optional[float] = None
    maf_gps: Optional[float] = None
    oil_temp_c: Optional[float] = None
    runtime_s: Optional[int] = None
    stft_pct: Optional[float] = None
    ltft_pct: Optional[float] = None
    timing_deg: Optional[float] = None
    baro_kpa: Optional[float] = None
    ambient_c: Optional[float] = None
    pedal_pct: Optional[float] = None
    mil_dist_km: Optional[int] = None
    mil_on: Optional[bool] = False
    dtc_count: Optional[int] = 0
    dtcs: Optional[str] = "none"
    smog_ready: Optional[bool] = True
    vin: Optional[str] = "UNKNOWN"
    lambda_ratio: Optional[float] = None
    afr: Optional[float] = None
    cat_temp_c: Optional[float] = None
    fuel_rail_bar: Optional[float] = None
    fuel_status: Optional[str] = None

def decode_fuel_status(code: int) -> str:
    if code == 1:
        return "Open Loop (Cold)"
    elif code == 2:
        return "Closed Loop"
    elif code == 4:
        return "Open Loop (Boost/Load)"
    elif code == 8:
        return "Open Loop (Fault)"
    elif code == 16:
        return "Closed Loop (Fault)"
    return "Off" if code == 0 else f"Code {code}"

trip_tracker = {
    "last_ts": None,
    "trip_distance_km": 0.0,
    "trip_fuel_liters": 0.0,
    "drive_state": "Parked"
}

def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            vehicle TEXT NOT NULL,
            rpm REAL,
            speed_kph REAL,
            coolant_c REAL,
            load_pct REAL,
            throttle_pct REAL,
            voltage_v REAL,
            iat_c REAL,
            fuel_pct REAL,
            map_kpa REAL,
            maf_gps REAL,
            oil_temp_c REAL,
            runtime_s INTEGER,
            mil_on INTEGER,
            dtc_count INTEGER,
            dtcs TEXT,
            uptime INTEGER,
            stft_pct REAL,
            ltft_pct REAL,
            timing_deg REAL,
            baro_kpa REAL,
            ambient_c REAL,
            pedal_pct REAL,
            mil_dist_km INTEGER,
            smog_ready INTEGER,
            vin TEXT
        )
    """)
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_ts ON telemetry (timestamp)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_veh ON telemetry (vehicle)")

    cursor.execute("PRAGMA table_info(telemetry)")
    cols = [row[1] for row in cursor.fetchall()]
    new_cols = [
        ("stft_pct", "REAL DEFAULT 0.0"),
        ("ltft_pct", "REAL DEFAULT 0.0"),
        ("timing_deg", "REAL DEFAULT 0.0"),
        ("baro_kpa", "REAL DEFAULT 101.3"),
        ("ambient_c", "REAL DEFAULT 0.0"),
        ("pedal_pct", "REAL DEFAULT 0.0"),
        ("mil_dist_km", "INTEGER DEFAULT 0"),
        ("smog_ready", "INTEGER DEFAULT 1"),
        ("vin", "TEXT DEFAULT 'UNKNOWN'"),
        ("lambda_ratio", "REAL DEFAULT 1.0"),
        ("afr", "REAL DEFAULT 14.7"),
        ("cat_temp_c", "REAL DEFAULT 0.0"),
        ("fuel_rail_bar", "REAL DEFAULT 0.0"),
        ("fuel_status", "TEXT DEFAULT 'Off'")
    ]
    for col_name, col_def in new_cols:
        if col_name not in cols:
            cursor.execute(f"ALTER TABLE telemetry ADD COLUMN {col_name} {col_def}")

    conn.commit()
    conn.close()

init_db()
init_mqtt()

last_known_state = {
    "coolant_c": 31.0,
    "oil_temp_c": 0.0,
    "iat_c": 32.0,
    "ambient_c": 30.0,
    "fuel_pct": 83.0,
    "baro_kpa": 101.3,
    "throttle_pct": 18.0,
    "vin": "YV4TESTING1234567"
}

def sanitize_telemetry(r: TelemetryPoint) -> TelemetryPoint:
    # 1. Engine Off Guards (RPM < 300)
    engine_running = (r.rpm is not None and r.rpm >= 300.0)
    if not engine_running:
        r.rpm = 0.0
        r.speed_kph = 0.0
        r.load_pct = 0.0
        r.maf_gps = 0.0
        r.stft_pct = 0.0
        r.ltft_pct = 0.0
        r.timing_deg = 0.0
        r.fuel_rail_bar = None
        r.fuel_status = None
        r.lambda_ratio = None
        r.afr = None
        r.cat_temp_c = None
        # When stopped and foot is off pedal, hold resting throttle plate angle
        if not r.pedal_pct or r.pedal_pct == 0.0:
            if r.throttle_pct == 0.0 and last_known_state.get("throttle_pct", 0) > 0:
                r.throttle_pct = last_known_state["throttle_pct"]

    # 2. Speed sanity guard (Volvo 0xFF = 255 offline artifact)
    if r.speed_kph >= 250.0 and (not r.rpm or r.rpm < 1500.0):
        r.speed_kph = 0.0

    # 3. Persistent physical state (retain last known valid values on dropped sub-second packets)
    if r.oil_temp_c is not None and not (-40.0 <= r.oil_temp_c <= 170.0):
        r.oil_temp_c = None

    for field in ["coolant_c", "iat_c", "ambient_c", "fuel_pct", "baro_kpa", "throttle_pct"]:
        val = getattr(r, field, None)
        if val is not None and val > 0.0:
            last_known_state[field] = val
        elif last_known_state.get(field, 0.0) > 0.0:
            setattr(r, field, last_known_state[field])

    # Oil uses -128 as unavailable in the binary protocol. Never sample-and-hold it.
    if r.oil_temp_c == -128.0:
        r.oil_temp_c = None

    # 4. VIN persistence
    if r.vin and r.vin != "UNKNOWN" and len(r.vin) >= 11:
        last_known_state["vin"] = r.vin
    elif last_known_state.get("vin") and last_known_state["vin"] != "UNKNOWN":
        r.vin = last_known_state["vin"]

    # 5. Smog ready truth
    r.smog_ready = not (r.mil_on or (r.dtc_count and r.dtc_count > 0) or (r.dtcs and r.dtcs != "none"))

    return r

latest_state: dict = {}

def update_latest_state(r: TelemetryPoint) -> dict:
    global latest_state
    # Update trip tracker
    now_ts = time.time()
    last_ts = trip_tracker["last_ts"]
    trip_tracker["last_ts"] = now_ts

    if r.rpm < 300.0:
        trip_tracker["drive_state"] = "Parked"
    elif r.speed_kph < 3.0:
        trip_tracker["drive_state"] = "Idling"
    elif (r.throttle_pct and r.throttle_pct > 35.0) or (r.load_pct and r.load_pct > 65.0):
        trip_tracker["drive_state"] = "Accelerating"
    elif (r.throttle_pct and r.throttle_pct < 5.0) and r.speed_kph > 20.0:
        trip_tracker["drive_state"] = "Coasting"
    else:
        trip_tracker["drive_state"] = "Cruising"

    # Trip reset logic if parked for > 15 mins (900 sec)
    if last_ts is not None and (now_ts - last_ts > 900.0):
        trip_tracker["trip_distance_km"] = 0.0
        trip_tracker["trip_fuel_liters"] = 0.0

    if last_ts is not None and now_ts > last_ts:
        dt = min(now_ts - last_ts, 30.0)
        if r.speed_kph > 0.5:
            trip_tracker["trip_distance_km"] += (r.speed_kph / 3600.0) * dt
        if r.rpm >= 300.0 and r.maf_gps and r.maf_gps > 0.0:
            trip_tracker["trip_fuel_liters"] += ((r.maf_gps / 14.7) / 740.0) * dt

    trip_miles = round(trip_tracker["trip_distance_km"] * 0.621371, 2)
    trip_fuel_gal = round(trip_tracker["trip_fuel_liters"] * 0.264172, 2)
    trip_avg_mpg = round(trip_miles / trip_fuel_gal, 1) if trip_fuel_gal > 0.02 else 0.0

    baro = r.baro_kpa if (r.baro_kpa and r.baro_kpa > 50.0) else 101.3
    boost_psi = round(max(0.0, (r.map_kpa - baro) * 0.145038), 1) if (r.map_kpa and r.map_kpa > baro) else 0.0
    fuel_rate_lph = round(r.maf_gps * 0.340, 2) if (r.maf_gps and r.maf_gps > 0) else 0.0
    instant_mpg = round((r.speed_kph * 7.104) / r.maf_gps, 1) if (r.maf_gps and r.maf_gps > 0.5 and r.speed_kph > 5.0) else 0.0
    est_horsepower = round(r.maf_gps / 0.8, 0) if (r.maf_gps and r.maf_gps > 0) else 0.0

    speed_mph = round(r.speed_kph * 0.621371, 1)
    coolant_f = round(r.coolant_c * 9.0 / 5.0 + 32.0, 1) if r.coolant_c is not None else None
    oil_temp_f = round(r.oil_temp_c * 9.0 / 5.0 + 32.0, 1) if r.oil_temp_c is not None else None
    cat_temp_f = round(r.cat_temp_c * 9.0 / 5.0 + 32.0, 1) if r.cat_temp_c is not None else None
    iat_f = round(r.iat_c * 9.0 / 5.0 + 32.0, 1) if r.iat_c is not None else None
    ambient_f = round(r.ambient_c * 9.0 / 5.0 + 32.0, 1) if r.ambient_c is not None else None

    latest_state = {
        "timestamp": now_ts,
        "rpm": r.rpm,
        "speed_kph": r.speed_kph,
        "speed_mph": speed_mph,
        "coolant_c": r.coolant_c,
        "coolant_f": coolant_f,
        "load_pct": r.load_pct,
        "throttle_pct": r.throttle_pct,
        "voltage_v": r.voltage_v,
        "iat_c": r.iat_c or 0.0,
        "iat_f": iat_f,
        "fuel_pct": r.fuel_pct or 0.0,
        "map_kpa": r.map_kpa or 0.0,
        "maf_gps": r.maf_gps or 0.0,
        "oil_temp_c": r.oil_temp_c,
        "oil_temp_f": oil_temp_f,
        "runtime_s": r.runtime_s or 0,
        "stft_pct": r.stft_pct or 0.0,
        "ltft_pct": r.ltft_pct or 0.0,
        "timing_deg": r.timing_deg or 0.0,
        "baro_kpa": baro,
        "ambient_c": r.ambient_c or 0.0,
        "ambient_f": ambient_f,
        "pedal_pct": r.pedal_pct or 0.0,
        "mil_dist_km": r.mil_dist_km or 0,
        "mil_on": r.mil_on or False,
        "dtc_count": r.dtc_count or 0,
        "dtcs": r.dtcs or "none",
        "smog_ready": not (r.mil_on or (r.dtc_count and r.dtc_count > 0) or (r.dtcs and r.dtcs != "none")),
        "vin": r.vin if (r.vin and r.vin != "UNKNOWN") else "Scanning...",
        "boost_psi": boost_psi,
        "fuel_rate_lph": fuel_rate_lph,
        "instant_mpg": instant_mpg,
        "est_horsepower": est_horsepower,
        "drive_state": trip_tracker["drive_state"],
        "trip_miles": trip_miles,
        "trip_fuel_gal": trip_fuel_gal,
        "trip_avg_mpg": trip_avg_mpg,
        "lambda_ratio": r.lambda_ratio,
        "afr": r.afr,
        "cat_temp_c": r.cat_temp_c,
        "cat_temp_f": cat_temp_f,
        "fuel_rail_bar": r.fuel_rail_bar,
        "fuel_status": r.fuel_status or "Unavailable"
    }
    return latest_state

def publish_mqtt_state(r: TelemetryPoint):
    state_payload = update_latest_state(r)
    if not mqtt_client:
        return
    mqtt_client.publish(STATE_TOPIC, json.dumps(state_payload), retain=True)

def load_latest_state_from_db():
    global latest_state
    if not DB_PATH.exists():
        return
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM telemetry ORDER BY id DESC LIMIT 1")
        row = cursor.fetchone()
        conn.close()
        if row:
            d = dict(row)
            tp = TelemetryPoint(
                uptime=d.get("uptime"),
                vehicle=d.get("vehicle", "volvo"),
                rpm=d.get("rpm", 0.0),
                speed_kph=d.get("speed_kph", 0.0),
                coolant_c=d.get("coolant_c", 0.0),
                load_pct=d.get("load_pct", 0.0),
                throttle_pct=d.get("throttle_pct", 0.0),
                voltage_v=d.get("voltage_v", 0.0),
                iat_c=d.get("iat_c"),
                fuel_pct=d.get("fuel_pct"),
                map_kpa=d.get("map_kpa"),
                maf_gps=d.get("maf_gps"),
                oil_temp_c=d.get("oil_temp_c"),
                runtime_s=d.get("runtime_s"),
                stft_pct=d.get("stft_pct"),
                ltft_pct=d.get("ltft_pct"),
                timing_deg=d.get("timing_deg"),
                baro_kpa=d.get("baro_kpa"),
                ambient_c=d.get("ambient_c"),
                pedal_pct=d.get("pedal_pct"),
                mil_dist_km=d.get("mil_dist_km"),
                mil_on=bool(d.get("mil_on")),
                dtc_count=d.get("dtc_count", 0),
                dtcs=d.get("dtcs", "none"),
                smog_ready=bool(d.get("smog_ready", 1)),
                vin=d.get("vin", "UNKNOWN"),
                lambda_ratio=d.get("lambda_ratio"),
                afr=d.get("afr"),
                cat_temp_c=d.get("cat_temp_c"),
                fuel_rail_bar=d.get("fuel_rail_bar"),
                fuel_status=d.get("fuel_status")
            )
            update_latest_state(tp)
            if d.get("timestamp"):
                latest_state["timestamp"] = d["timestamp"]
    except Exception as e:
        print("[DB] Note loading latest state:", e)

load_latest_state_from_db()

@app.api_route("/", methods=["GET", "HEAD"])
def get_dashboard():
    static_file = Path(__file__).resolve().parent / "static" / "index.html"
    if static_file.exists():
        return FileResponse(str(static_file), media_type="text/html")
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
        "mqtt_connected": mqtt_client is not None,
        "record_size_bytes": RECORD_SIZE,
        "db": str(DB_PATH)
    }

@app.post("/api/telemetry")
def ingest_telemetry(records: List[TelemetryPoint]):
    if not records:
        return {"status": "empty", "inserted": 0}

    now = time.time()
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    rows = []
    latest_record = None

    for r in records:
        r = sanitize_telemetry(r)
        rows.append((
            now, r.vehicle, r.rpm, r.speed_kph, r.coolant_c,
            r.load_pct, r.throttle_pct, r.voltage_v,
            r.iat_c, r.fuel_pct, r.map_kpa, r.maf_gps, r.oil_temp_c, r.runtime_s,
            1 if r.mil_on else 0, r.dtc_count, r.dtcs,
            r.uptime,
            r.stft_pct, r.ltft_pct, r.timing_deg, r.baro_kpa, r.ambient_c,
            r.pedal_pct, r.mil_dist_km, 1 if r.smog_ready else 0, r.vin,
            r.lambda_ratio, r.afr, r.cat_temp_c, r.fuel_rail_bar, r.fuel_status
        ))
        latest_record = r

    cursor.executemany("""
        INSERT INTO telemetry (
            timestamp, vehicle, rpm, speed_kph, coolant_c,
            load_pct, throttle_pct, voltage_v,
            iat_c, fuel_pct, map_kpa, maf_gps, oil_temp_c, runtime_s,
            mil_on, dtc_count, dtcs, uptime,
            stft_pct, ltft_pct, timing_deg, baro_kpa, ambient_c,
            pedal_pct, mil_dist_km, smog_ready, vin,
            lambda_ratio, afr, cat_temp_c, fuel_rail_bar, fuel_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, rows)
    conn.commit()
    conn.close()

    if latest_record:
        publish_mqtt_state(latest_record)

    return {"status": "ok", "inserted": len(rows)}

@app.post("/api/telemetry/binary")
async def ingest_binary_telemetry(
    request: Request,
    vehicle: str = "volvo",
    vin: str = "UNKNOWN",
    dtcs: str = "none"
):
    body = await request.body()
    if not body:
        return {"status": "empty", "inserted": 0}

    # Determine format version: V2 (36 bytes) or V1 (29 bytes)
    if len(body) % RECORD_SIZE_V2 == 0:
        rec_fmt = BINARY_RECORD_FORMAT_V2
        rec_sz = RECORD_SIZE_V2
        is_v2 = True
    else:
        rec_fmt = BINARY_RECORD_FORMAT_V1
        rec_sz = RECORD_SIZE_V1
        is_v2 = False

    valid_len = (len(body) // rec_sz) * rec_sz
    body = body[:valid_len]

    now = time.time()
    rows = []
    latest_record = None

    for item in struct.iter_unpack(rec_fmt, body):
        if is_v2:
            (
                uptime_ms, rpm, speed_kph, coolant_c, load_pct, throttle_pct, voltage_mv,
                iat_c, fuel_pct, map_kpa, maf_cgs, oil_temp_c, runtime_s,
                stft_pct, ltft_pct, timing_deg, baro_kpa, ambient_c,
                pedal_pct, mil_dist_km, flags,
                lambda_x1000, cat_temp_c, fuel_rail_bar, fuel_status_code
            ) = item
            lambda_val = round(lambda_x1000 / 1000.0, 3) if lambda_x1000 > 0 else None
            afr_val = round(lambda_val * 14.7, 2) if lambda_val is not None else None
            cat_val = None if cat_temp_c == -32768 else float(cat_temp_c)
            rail_val = None if fuel_rail_bar == 65535 else float(fuel_rail_bar)
            status_val = decode_fuel_status(fuel_status_code) if fuel_status_code else None
        else:
            (
                uptime_ms, rpm, speed_kph, coolant_c, load_pct, throttle_pct, voltage_mv,
                iat_c, fuel_pct, map_kpa, maf_cgs, oil_temp_c, runtime_s,
                stft_pct, ltft_pct, timing_deg, baro_kpa, ambient_c,
                pedal_pct, mil_dist_km, flags
            ) = item
            lambda_val = None
            afr_val = None
            cat_val = None
            rail_val = None
            status_val = None

        # Sanity guard: Volvo CAN returns 0xFF (255 km/h / 158 mph) when ABS is offline with engine off
        if speed_kph >= 250.0 and rpm < 500.0:
            speed_kph = 0.0

        mil_on = bool(flags & 0x01)
        dtc_present = bool(flags & 0x04)
        smog_ready = not mil_on and not dtc_present and (dtcs == "none")
        voltage_v = round(voltage_mv / 1000.0, 2)
        maf_gps = round(maf_cgs / 100.0, 2)

        record = TelemetryPoint(
            uptime=uptime_ms // 1000,
            vehicle=vehicle,
            rpm=float(rpm),
            speed_kph=float(speed_kph),
            coolant_c=float(coolant_c),
            load_pct=float(load_pct),
            throttle_pct=float(throttle_pct),
            voltage_v=voltage_v,
            iat_c=float(iat_c),
            fuel_pct=float(fuel_pct),
            map_kpa=float(map_kpa),
            maf_gps=maf_gps,
            oil_temp_c=float(oil_temp_c),
            runtime_s=runtime_s,
            stft_pct=float(stft_pct),
            ltft_pct=float(ltft_pct),
            timing_deg=float(timing_deg),
            baro_kpa=float(baro_kpa),
            ambient_c=float(ambient_c),
            pedal_pct=float(pedal_pct),
            mil_dist_km=mil_dist_km,
            mil_on=mil_on,
            dtc_count=1 if (flags & 0x04) else 0,
            dtcs=dtcs,
            smog_ready=smog_ready,
            vin=vin,
            lambda_ratio=lambda_val,
            afr=afr_val,
            cat_temp_c=cat_val,
            fuel_rail_bar=rail_val,
            fuel_status=status_val
        )

        record = sanitize_telemetry(record)

        rows.append((
            now, vehicle, record.rpm, record.speed_kph, record.coolant_c,
            record.load_pct, record.throttle_pct, record.voltage_v,
            record.iat_c, record.fuel_pct, record.map_kpa, record.maf_gps,
            record.oil_temp_c, record.runtime_s,
            1 if record.mil_on else 0, record.dtc_count, record.dtcs,
            record.uptime,
            record.stft_pct, record.ltft_pct, record.timing_deg,
            record.baro_kpa, record.ambient_c, record.pedal_pct,
            record.mil_dist_km, 1 if record.smog_ready else 0, record.vin,
            record.lambda_ratio, record.afr, record.cat_temp_c, record.fuel_rail_bar, record.fuel_status
        ))
        latest_record = record

    if rows:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.executemany("""
            INSERT INTO telemetry (
                timestamp, vehicle, rpm, speed_kph, coolant_c,
                load_pct, throttle_pct, voltage_v,
                iat_c, fuel_pct, map_kpa, maf_gps, oil_temp_c, runtime_s,
                mil_on, dtc_count, dtcs, uptime,
                stft_pct, ltft_pct, timing_deg, baro_kpa, ambient_c,
                pedal_pct, mil_dist_km, smog_ready, vin,
                lambda_ratio, afr, cat_temp_c, fuel_rail_bar, fuel_status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, rows)
        conn.commit()
        conn.close()

        if latest_record:
            publish_mqtt_state(latest_record)

    return {"status": "ok", "inserted": len(rows), "bytes": len(body)}

@app.get("/api/history")
def get_history(vehicle: str = "volvo", limit: int = 100):
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute("""
        SELECT timestamp, vehicle, rpm, speed_kph, coolant_c, load_pct, throttle_pct, voltage_v,
               iat_c, fuel_pct, map_kpa, maf_gps, oil_temp_c, stft_pct, ltft_pct, timing_deg,
               mil_on, dtcs, vin, lambda_ratio, afr, cat_temp_c, fuel_rail_bar, fuel_status
        FROM telemetry
        WHERE vehicle = ?
        ORDER BY timestamp DESC, id DESC
        LIMIT ?
    """, (vehicle, limit))
    rows = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"vehicle": vehicle, "count": len(rows), "records": rows}
