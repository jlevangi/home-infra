import struct
from typing import List, Optional
from pydantic import BaseModel, Field

# Binary packet format V1 (29 bytes packed)
BINARY_RECORD_FORMAT_V1 = "<IHBbBBHbBBHbHbbbBbBHB"
RECORD_SIZE_V1 = struct.calcsize(BINARY_RECORD_FORMAT_V1)

# Binary packet format V2 (36 bytes packed): adds lambda_x1000 (H), cat_temp (h), fuel_rail_bar (H), fuel_status (B)
BINARY_RECORD_FORMAT_V2 = "<IHBbBBHbBBHbHbbbBbBHBHhHB"
RECORD_SIZE_V2 = struct.calcsize(BINARY_RECORD_FORMAT_V2)

BINARY_RECORD_FORMAT = BINARY_RECORD_FORMAT_V2
RECORD_SIZE = RECORD_SIZE_V2

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


class RelayTelemetryPoint(TelemetryPoint):
    """A browser-relayed point with a durable identity from the device spool."""

    device_id: str = Field(..., min_length=1, max_length=128)
    boot_id: str = Field(..., min_length=1, max_length=128)
    sequence: int = Field(..., ge=0)

    @property
    def record_id(self) -> str:
        return f"{self.device_id}:{self.boot_id}:{self.sequence}"
