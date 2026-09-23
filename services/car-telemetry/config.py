import os
from pathlib import Path

# Paths
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
DB_PATH = Path(os.environ.get("CAR_TELEMETRY_DB", "/home/pierce/workspace/car-telemetry/telemetry.db"))

# Home Assistant Device Info
DEVICE_INFO = {
    "identifiers": ["volvo_xc60_telemetry"],
    "name": "Volvo XC60 Telemetry",
    "model": "XC60 (OBD-II)",
    "manufacturer": "Volvo"
}

STATE_TOPIC = "homeassistant/sensor/volvo_xc60/state"
DISCOVERY_PREFIX = "homeassistant"
