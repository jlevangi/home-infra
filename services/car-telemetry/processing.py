import time
import struct
from typing import List, Tuple, Optional
try:
    from .models import (
        TelemetryPoint,
        BINARY_RECORD_FORMAT_V1, RECORD_SIZE_V1,
        BINARY_RECORD_FORMAT_V2, RECORD_SIZE_V2
    )
except ImportError:
    from models import (
        TelemetryPoint,
        BINARY_RECORD_FORMAT_V1, RECORD_SIZE_V1,
        BINARY_RECORD_FORMAT_V2, RECORD_SIZE_V2
    )

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

trip_tracker = {
    "last_ts": None,
    "trip_distance_km": 0.0,
    "trip_fuel_liters": 0.0,
    "drive_state": "Parked"
}

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

def update_derived_state(r: TelemetryPoint, custom_now: Optional[float] = None) -> dict:
    now_ts = custom_now if custom_now is not None else time.time()
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

    return {
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

def unpack_binary_payload(
    body: bytes,
    vehicle: str = "volvo",
    vin: str = "UNKNOWN",
    dtcs: str = "none"
) -> List[TelemetryPoint]:
    if not body:
        return []

    # Format version detection:
    # 1. Exact multiple of V2 (36) -> V2
    # 2. Exact multiple of V1 (29) -> V1
    # 3. Truncated stream fallback: prefer V2 if >= 36 bytes, else V1 if >= 29 bytes
    if len(body) % RECORD_SIZE_V2 == 0:
        rec_fmt = BINARY_RECORD_FORMAT_V2
        rec_sz = RECORD_SIZE_V2
        is_v2 = True
    elif len(body) % RECORD_SIZE_V1 == 0:
        rec_fmt = BINARY_RECORD_FORMAT_V1
        rec_sz = RECORD_SIZE_V1
        is_v2 = False
    elif len(body) >= RECORD_SIZE_V2:
        rec_fmt = BINARY_RECORD_FORMAT_V2
        rec_sz = RECORD_SIZE_V2
        is_v2 = True
    elif len(body) >= RECORD_SIZE_V1:
        rec_fmt = BINARY_RECORD_FORMAT_V1
        rec_sz = RECORD_SIZE_V1
        is_v2 = False
    else:
        return []

    valid_len = (len(body) // rec_sz) * rec_sz
    body = body[:valid_len]

    records = []
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
        records.append(record)

    return records
