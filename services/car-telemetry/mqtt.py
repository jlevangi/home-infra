import os
import json
import urllib.request
from typing import Optional, Dict
import paho.mqtt.client as mqtt
try:
    from .config import DEVICE_INFO, STATE_TOPIC, DISCOVERY_PREFIX
except ImportError:
    from config import DEVICE_INFO, STATE_TOPIC, DISCOVERY_PREFIX

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
        "id": "speed",
        "comp": "sensor",
        "cfg": {
            "name": "Speed",
            "unique_id": "volvo_xc60_speed",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.speed_mph | round(0) }}",
            "unit_of_measurement": "mph",
            "device_class": "speed",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "coolant_temp",
        "comp": "sensor",
        "cfg": {
            "name": "Coolant Temperature",
            "unique_id": "volvo_xc60_coolant_temp",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.coolant_f | round(0) }}",
            "unit_of_measurement": "°F",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "oil_temp",
        "comp": "sensor",
        "cfg": {
            "name": "Engine Oil Temperature",
            "unique_id": "volvo_xc60_oil_temp",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.oil_temp_f if value_json.oil_temp_f is not none else 'unavailable' }}",
            "unit_of_measurement": "°F",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "cat_temp",
        "comp": "sensor",
        "cfg": {
            "name": "Catalytic Converter Temperature",
            "unique_id": "volvo_xc60_cat_temp",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.cat_temp_f if value_json.cat_temp_f is not none else 'unavailable' }}",
            "unit_of_measurement": "°F",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "intake_temp",
        "comp": "sensor",
        "cfg": {
            "name": "Intake Air Temperature",
            "unique_id": "volvo_xc60_intake_temp",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.iat_f | round(0) }}",
            "unit_of_measurement": "°F",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "ambient_temp",
        "comp": "sensor",
        "cfg": {
            "name": "Ambient Temperature",
            "unique_id": "volvo_xc60_ambient_temp",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.ambient_f | round(0) }}",
            "unit_of_measurement": "°F",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 2. Air, Boost & Performance
    {
        "id": "turbo_boost",
        "comp": "sensor",
        "cfg": {
            "name": "Turbo Boost",
            "unique_id": "volvo_xc60_turbo_boost",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.boost_psi | round(1) }}",
            "unit_of_measurement": "psi",
            "device_class": "pressure",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "map",
        "comp": "sensor",
        "cfg": {
            "name": "Intake Manifold Pressure",
            "unique_id": "volvo_xc60_map",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.map_kpa | round(0) }}",
            "unit_of_measurement": "kPa",
            "device_class": "pressure",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "maf",
        "comp": "sensor",
        "cfg": {
            "name": "Mass Air Flow",
            "unique_id": "volvo_xc60_maf",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.maf_gps | round(2) }}",
            "unit_of_measurement": "g/s",
            "icon": "mdi:weather-windy",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "est_horsepower",
        "comp": "sensor",
        "cfg": {
            "name": "Estimated Horsepower",
            "unique_id": "volvo_xc60_est_horsepower",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.est_horsepower | round(0) }}",
            "unit_of_measurement": "hp",
            "icon": "mdi:horse-variant",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "engine_load",
        "comp": "sensor",
        "cfg": {
            "name": "Engine Load",
            "unique_id": "volvo_xc60_engine_load",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.load_pct | round(0) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:car-speed-limiter",
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
            "value_template": "{{ value_json.throttle_pct | round(0) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:speedometer",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "pedal_position",
        "comp": "sensor",
        "cfg": {
            "name": "Accelerator Pedal Position",
            "unique_id": "volvo_xc60_pedal_position",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.pedal_pct | round(0) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:car-brake-low-pressure",
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
            "icon": "mdi:fire",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 3. Combustion & Fuel Mixture
    {
        "id": "lambda_ratio",
        "comp": "sensor",
        "cfg": {
            "name": "Equivalence Ratio (Lambda)",
            "unique_id": "volvo_xc60_lambda_ratio",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.lambda_ratio if value_json.lambda_ratio is not none else 'unavailable' }}",
            "icon": "mdi:molecule",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "air_fuel_ratio",
        "comp": "sensor",
        "cfg": {
            "name": "Air-Fuel Ratio (AFR)",
            "unique_id": "volvo_xc60_air_fuel_ratio",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.afr if value_json.afr is not none else 'unavailable' }}",
            "unit_of_measurement": "AFR",
            "icon": "mdi:gas-station",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "fuel_rail_pressure",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel Rail Pressure",
            "unique_id": "volvo_xc60_fuel_rail_pressure",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_rail_bar if value_json.fuel_rail_bar is not none else 'unavailable' }}",
            "unit_of_measurement": "bar",
            "device_class": "pressure",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "fuel_status",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel Loop State",
            "unique_id": "volvo_xc60_fuel_status",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_status if value_json.fuel_status is not none else 'unavailable' }}",
            "icon": "mdi:autorenew",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "stft",
        "comp": "sensor",
        "cfg": {
            "name": "Short Term Fuel Trim",
            "unique_id": "volvo_xc60_stft",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.stft_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:tune",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "ltft",
        "comp": "sensor",
        "cfg": {
            "name": "Long Term Fuel Trim",
            "unique_id": "volvo_xc60_ltft",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.ltft_pct | round(1) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:tune-vertical",
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
            "value_template": "{{ value_json.fuel_pct | round(0) }}",
            "unit_of_measurement": "%",
            "icon": "mdi:gas-station",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    # 4. Trip, Economy & Diagnostics
    {
        "id": "instant_fuel_rate",
        "comp": "sensor",
        "cfg": {
            "name": "Fuel Consumption Rate",
            "unique_id": "volvo_xc60_instant_fuel_rate",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.fuel_rate_lph | round(2) }}",
            "unit_of_measurement": "L/h",
            "icon": "mdi:fuel",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "instant_mpg",
        "comp": "sensor",
        "cfg": {
            "name": "Instant Economy",
            "unique_id": "volvo_xc60_instant_mpg",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.instant_mpg | round(1) }}",
            "unit_of_measurement": "mpg",
            "icon": "mdi:leaf",
            "state_class": "measurement",
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
            "value_template": "{{ value_json.trip_miles | round(2) }}",
            "unit_of_measurement": "mi",
            "device_class": "distance",
            "state_class": "total",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "trip_fuel_used",
        "comp": "sensor",
        "cfg": {
            "name": "Trip Fuel Used",
            "unique_id": "volvo_xc60_trip_fuel_used",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.trip_fuel_gal | round(2) }}",
            "unit_of_measurement": "gal",
            "icon": "mdi:gas-station-in-use",
            "state_class": "total",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "trip_avg_mpg",
        "comp": "sensor",
        "cfg": {
            "name": "Trip Average Economy",
            "unique_id": "volvo_xc60_trip_avg_mpg",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.trip_avg_mpg | round(1) }}",
            "unit_of_measurement": "mpg",
            "icon": "mdi:calculator",
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
        "id": "barometric_pressure",
        "comp": "sensor",
        "cfg": {
            "name": "Barometric Pressure",
            "unique_id": "volvo_xc60_barometric_pressure",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.baro_kpa | round(1) }}",
            "unit_of_measurement": "kPa",
            "device_class": "atmospheric_pressure",
            "state_class": "measurement",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "mil_status",
        "comp": "binary_sensor",
        "cfg": {
            "name": "Check Engine Light (MIL)",
            "unique_id": "volvo_xc60_mil_status",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ 'ON' if value_json.mil_on else 'OFF' }}",
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
            "device_class": "running",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "dtc_codes",
        "comp": "sensor",
        "cfg": {
            "name": "Trouble Codes (DTC)",
            "unique_id": "volvo_xc60_dtc_codes",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.dtcs }}",
            "icon": "mdi:alert-octagon",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "smog_readiness",
        "comp": "binary_sensor",
        "cfg": {
            "name": "Smog Check Readiness",
            "unique_id": "volvo_xc60_smog_readiness",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ 'ON' if value_json.smog_ready else 'OFF' }}",
            "icon": "mdi:check-decagram",
            "device": DEVICE_INFO
        }
    },
    {
        "id": "vin_number",
        "comp": "sensor",
        "cfg": {
            "name": "Vehicle VIN",
            "unique_id": "volvo_xc60_vin_number",
            "state_topic": STATE_TOPIC,
            "value_template": "{{ value_json.vin }}",
            "icon": "mdi:card-account-details",
            "device": DEVICE_INFO
        }
    }
]

def get_mqtt_credentials() -> Optional[Dict[str, any]]:
    env_host = os.environ.get("MQTT_HOST")
    if env_host:
        return {
            "host": env_host,
            "port": int(os.environ.get("MQTT_PORT", 1883)),
            "username": os.environ.get("MQTT_USERNAME", ""),
            "password": os.environ.get("MQTT_PASSWORD", "")
        }

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

class MqttBridge:
    def __init__(self):
        self.client: Optional[mqtt.Client] = None
        self.connected = False

    def connect(self):
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
                topic = f"{DISCOVERY_PREFIX}/{s['comp']}/volvo_xc60/{s['id']}/config"
                client.publish(topic, json.dumps(s["cfg"]), retain=True)

            self.client = client
            self.connected = True
            print("[MQTT] Connected to Home Assistant broker and discovery configs published.")
        except Exception as e:
            print("[MQTT] Failed to initialize MQTT client:", e)
            self.connected = False

    def publish_state(self, state_payload: dict):
        if not self.client:
            return
        try:
            self.client.publish(STATE_TOPIC, json.dumps(state_payload), retain=True)
        except Exception as e:
            print("[MQTT] Error publishing state:", e)

    def disconnect(self):
        if self.client:
            try:
                self.client.loop_stop()
                self.client.disconnect()
            except Exception:
                pass
            self.client = None
            self.connected = False
