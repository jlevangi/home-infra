import time
import sqlite3
from pathlib import Path
from typing import List, Optional, Sequence
try:
    from .config import DB_PATH
    from .models import TelemetryPoint
except ImportError:
    from config import DB_PATH
    from models import TelemetryPoint

def init_db(db_path: Path = DB_PATH):
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            record_id TEXT,
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
        ("fuel_status", "TEXT DEFAULT 'Off'"),
        ("record_id", "TEXT")
    ]
    for col_name, col_def in new_cols:
        if col_name not in cols:
            cursor.execute(f"ALTER TABLE telemetry ADD COLUMN {col_name} {col_def}")

    # Legacy binary rows remain nullable; only relay rows participate in deduplication.
    cursor.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_telemetry_record_id ON telemetry(record_id) WHERE record_id IS NOT NULL")
    conn.commit()
    conn.close()

def store_telemetry_batch(records: Sequence[TelemetryPoint], db_path: Path = DB_PATH, timestamp: Optional[float] = None) -> int:
    if not records:
        return 0
    now = timestamp if timestamp is not None else time.time()
    rows = [
        (
            getattr(r, "record_id", None), now, r.vehicle, r.rpm, r.speed_kph, r.coolant_c,
            r.load_pct, r.throttle_pct, r.voltage_v,
            r.iat_c, r.fuel_pct, r.map_kpa, r.maf_gps, r.oil_temp_c, r.runtime_s,
            1 if r.mil_on else 0, r.dtc_count, r.dtcs,
            r.uptime,
            r.stft_pct, r.ltft_pct, r.timing_deg, r.baro_kpa, r.ambient_c,
            r.pedal_pct, r.mil_dist_km, 1 if r.smog_ready else 0, r.vin,
            r.lambda_ratio, r.afr, r.cat_temp_c, r.fuel_rail_bar, r.fuel_status
        )
        for r in records
    ]
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.executemany("""
        INSERT OR IGNORE INTO telemetry (
            record_id, timestamp, vehicle, rpm, speed_kph, coolant_c,
            load_pct, throttle_pct, voltage_v,
            iat_c, fuel_pct, map_kpa, maf_gps, oil_temp_c, runtime_s,
            mil_on, dtc_count, dtcs, uptime,
            stft_pct, ltft_pct, timing_deg, baro_kpa, ambient_c,
            pedal_pct, mil_dist_km, smog_ready, vin,
            lambda_ratio, afr, cat_temp_c, fuel_rail_bar, fuel_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, rows)
    inserted = cursor.rowcount
    conn.commit()
    conn.close()
    return inserted

def fetch_history(vehicle: str = "volvo", limit: int = 100, db_path: Path = DB_PATH) -> List[dict]:
    if not db_path.exists():
        return []
    conn = sqlite3.connect(db_path)
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
    return rows

def fetch_latest_row(db_path: Path = DB_PATH) -> Optional[dict]:
    if not db_path.exists():
        return None
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM telemetry ORDER BY id DESC LIMIT 1")
        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None
    except Exception:
        return None
