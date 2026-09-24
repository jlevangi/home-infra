"""
Derived analytics engine for Volvo XC60 telemetry.

Computes cross-sensor insights that no single metric reveals:
engine health trending, thermal behavior, driving scores,
and predictive maintenance signals.
"""

import math
import time
from collections import deque
from typing import Optional

# Rolling windows — retain last N samples for trend computation
_WINDOW_SIZE = 120  # ~2 min at 1 sample/s, ~10 min at 5s interval

_rpm_hist = deque(maxlen=_WINDOW_SIZE)
_throttle_hist = deque(maxlen=_WINDOW_SIZE)
_pedal_hist = deque(maxlen=_WINDOW_SIZE)
_boost_hist = deque(maxlen=_WINDOW_SIZE)
_speed_hist = deque(maxlen=_WINDOW_SIZE)
_load_hist = deque(maxlen=_WINDOW_SIZE)

# Warmup tracker
_warmup = {
    "cold_start_ts": None,
    "cold_start_coolant": None,
    "warmup_seconds": None,
    "is_warming": False,
}

# Idle tracker
_idle = {
    "idle_seconds": 0.0,
    "idle_fuel_liters": 0.0,
    "last_ts": None,
}

# Baseline accumulators (simple exponential moving averages)
_ema_alpha = 0.05  # slow-moving baseline
_baselines = {
    "voltage_at_cruise": None,
    "boost_at_3k_rpm": None,
    "cat_temp_at_cruise": None,
    "fuel_rail_at_load": None,
}


def _ema(current: Optional[float], new_val: float, alpha: float = _ema_alpha) -> float:
    if current is None:
        return new_val
    return current * (1.0 - alpha) + new_val * alpha


def _stddev(values) -> float:
    if len(values) < 2:
        return 0.0
    mean = sum(values) / len(values)
    variance = sum((v - mean) ** 2 for v in values) / len(values)
    return math.sqrt(variance)


def compute_analytics(state: dict) -> dict:
    """
    Accepts the derived state dict from update_derived_state().
    Returns a dict of analytics fields to merge into the state payload.
    """
    rpm = state.get("rpm", 0.0) or 0.0
    speed_kph = state.get("speed_kph", 0.0) or 0.0
    speed_mph = state.get("speed_mph", 0.0) or 0.0
    maf = state.get("maf_gps", 0.0) or 0.0
    map_kpa = state.get("map_kpa", 0.0) or 0.0
    iat_c = state.get("iat_c", 0.0) or 0.0
    coolant_c = state.get("coolant_c", 0.0) or 0.0
    baro = state.get("baro_kpa", 101.3) or 101.3
    throttle = state.get("throttle_pct", 0.0) or 0.0
    pedal = state.get("pedal_pct", 0.0) or 0.0
    load = state.get("load_pct", 0.0) or 0.0
    boost_psi = state.get("boost_psi", 0.0) or 0.0
    stft = state.get("stft_pct", 0.0) or 0.0
    ltft = state.get("ltft_pct", 0.0) or 0.0
    lambda_r = state.get("lambda_ratio")
    voltage = state.get("voltage_v", 0.0) or 0.0
    ambient_c = state.get("ambient_c", 0.0) or 0.0
    cat_temp_c = state.get("cat_temp_c")
    fuel_rail = state.get("fuel_rail_bar")
    fuel_rate = state.get("fuel_rate_lph", 0.0) or 0.0
    timestamp = state.get("timestamp", time.time())

    engine_on = rpm >= 300.0
    driving = speed_kph > 3.0 and engine_on

    # Append to rolling windows
    if engine_on:
        _rpm_hist.append(rpm)
        _throttle_hist.append(throttle)
        _pedal_hist.append(pedal)
        _boost_hist.append(boost_psi)
        _speed_hist.append(speed_mph)
        _load_hist.append(load)

    result = {}

    # ──────────────────────────────────────────────
    # 1. Volumetric Efficiency (VE%)
    # VE = (MAF_actual / MAF_theoretical) * 100
    # MAF_theoretical = (RPM * displacement * air_density) / (2 * 60)
    # Volvo T6 3.0L displacement = 2953 cc
    # ──────────────────────────────────────────────
    ve_pct = None
    if engine_on and maf > 0.1 and rpm > 500 and map_kpa > 10:
        displacement_l = 2.953
        iat_k = iat_c + 273.15
        air_density = (map_kpa * 1000.0) / (287.05 * iat_k)  # kg/m³
        # 4-stroke intake cycles: (rpm / 120) * (disp / 1000 m³) * air_density (kg/m³) * 1000 g/kg
        theoretical_maf = (rpm * displacement_l * air_density) / 120.0  # g/s
        if theoretical_maf > 0.01:
            ve_pct = round(min((maf / theoretical_maf) * 100.0, 150.0), 1)
    result["volumetric_efficiency_pct"] = ve_pct

    # ──────────────────────────────────────────────
    # 2. Combustion Quality Score (0-100)
    # Based on fuel trim health — ideal is both trims near 0
    # ──────────────────────────────────────────────
    combustion_score = None
    if engine_on:
        trim_penalty = abs(stft) * 2.0 + abs(ltft) * 3.0
        lambda_penalty = 0.0
        if lambda_r is not None and lambda_r > 0:
            lambda_penalty = abs(1.0 - lambda_r) * 50.0
        combustion_score = round(max(0.0, min(100.0, 100.0 - trim_penalty - lambda_penalty)), 0)
    result["combustion_quality"] = combustion_score

    # ──────────────────────────────────────────────
    # 3. Fuel Trim Health (traffic-light)
    # ──────────────────────────────────────────────
    fuel_trim_health = None
    if engine_on:
        total_trim = abs(stft) + abs(ltft)
        if total_trim < 5.0:
            fuel_trim_health = "Healthy"
        elif total_trim < 10.0:
            fuel_trim_health = "Monitor"
        elif total_trim < 15.0:
            fuel_trim_health = "Warning"
        else:
            fuel_trim_health = "Critical"
    result["fuel_trim_health"] = fuel_trim_health

    # ──────────────────────────────────────────────
    # 4. Driving Aggressiveness Score (0-100)
    # High throttle variance + boost events + high RPM band
    # ──────────────────────────────────────────────
    aggression_score = None
    if len(_throttle_hist) >= 10 and engine_on:
        throttle_volatility = _stddev(_throttle_hist)
        avg_pedal = sum(_pedal_hist) / max(len(_pedal_hist), 1)
        boost_events = sum(1 for b in _boost_hist if b > 3.0) / max(len(_boost_hist), 1) * 100
        high_rpm_pct = sum(1 for r in _rpm_hist if r > 4000) / max(len(_rpm_hist), 1) * 100

        raw = (throttle_volatility * 1.5) + (avg_pedal * 0.5) + (boost_events * 0.8) + (high_rpm_pct * 0.5)
        aggression_score = round(max(0.0, min(100.0, raw)), 0)
    result["driving_aggression"] = aggression_score

    # ──────────────────────────────────────────────
    # 5. IAT vs Ambient Delta (intercooler efficiency proxy)
    # ──────────────────────────────────────────────
    iat_delta = None
    if engine_on and iat_c > -30 and ambient_c > -30:
        iat_delta = round(iat_c - ambient_c, 1)
    result["iat_ambient_delta_c"] = iat_delta

    iat_ambient_status = None
    if iat_delta is not None:
        if iat_delta <= 10:
            iat_ambient_status = "Normal"
        elif iat_delta <= 25:
            iat_ambient_status = "Warm"
        elif iat_delta <= 40:
            iat_ambient_status = "Hot"
        else:
            iat_ambient_status = "Excessive"
    result["intercooler_status"] = iat_ambient_status

    # ──────────────────────────────────────────────
    # 6. Warmup Tracking
    # ──────────────────────────────────────────────
    WARM_THRESHOLD_C = 80.0
    if engine_on and coolant_c < 50.0 and not _warmup["is_warming"]:
        _warmup["cold_start_ts"] = timestamp
        _warmup["cold_start_coolant"] = coolant_c
        _warmup["is_warming"] = True
        _warmup["warmup_seconds"] = None

    if _warmup["is_warming"]:
        if coolant_c >= WARM_THRESHOLD_C:
            _warmup["warmup_seconds"] = round(timestamp - _warmup["cold_start_ts"], 0)
            _warmup["is_warming"] = False
        elif not engine_on:
            _warmup["is_warming"] = False

    result["warmup_seconds"] = _warmup["warmup_seconds"]
    result["warmup_active"] = _warmup["is_warming"]

    # ──────────────────────────────────────────────
    # 7. Idle Fuel Tracking
    # ──────────────────────────────────────────────
    if engine_on and speed_kph < 3.0:
        if _idle["last_ts"] is not None:
            dt = min(timestamp - _idle["last_ts"], 30.0)
            if dt > 0:
                _idle["idle_seconds"] += dt
                _idle["idle_fuel_liters"] += fuel_rate * (dt / 3600.0)
        _idle["last_ts"] = timestamp
    else:
        _idle["last_ts"] = timestamp

    # Reset idle tracker with trip reset (>15 min gap handled by caller)
    result["idle_seconds"] = round(_idle["idle_seconds"], 0)
    result["idle_fuel_gal"] = round(_idle["idle_fuel_liters"] * 0.264172, 3)

    # ──────────────────────────────────────────────
    # 8. Battery/Alternator Health
    # ──────────────────────────────────────────────
    battery_status = None
    if engine_on and voltage > 0:
        if driving and rpm > 1000:
            _baselines["voltage_at_cruise"] = _ema(_baselines["voltage_at_cruise"], voltage)

        if voltage < 12.0:
            battery_status = "Critical"
        elif voltage < 13.2:
            battery_status = "Low"
        elif voltage <= 14.8:
            battery_status = "Normal"
        else:
            battery_status = "Overcharging"
    elif not engine_on and voltage > 0:
        if voltage < 11.8:
            battery_status = "Weak (Engine Off)"
        else:
            battery_status = "OK (Engine Off)"
    result["battery_status"] = battery_status
    result["voltage_baseline"] = round(_baselines["voltage_at_cruise"], 2) if _baselines["voltage_at_cruise"] else None

    # ──────────────────────────────────────────────
    # 9. Turbo Boost Health
    # ──────────────────────────────────────────────
    if engine_on and rpm > 2800 and boost_psi > 1.0:
        _baselines["boost_at_3k_rpm"] = _ema(_baselines["boost_at_3k_rpm"], boost_psi)

    result["boost_baseline_psi"] = round(_baselines["boost_at_3k_rpm"], 1) if _baselines["boost_at_3k_rpm"] else None

    # ──────────────────────────────────────────────
    # 10. Cat Converter Trending
    # ──────────────────────────────────────────────
    if cat_temp_c is not None and driving and load > 30:
        _baselines["cat_temp_at_cruise"] = _ema(_baselines["cat_temp_at_cruise"], cat_temp_c)

    result["cat_temp_baseline_c"] = round(_baselines["cat_temp_at_cruise"], 0) if _baselines["cat_temp_at_cruise"] else None

    # ──────────────────────────────────────────────
    # 11. Fuel Rail Pressure Stability
    # ──────────────────────────────────────────────
    if fuel_rail is not None and engine_on and load > 40:
        _baselines["fuel_rail_at_load"] = _ema(_baselines["fuel_rail_at_load"], fuel_rail)

    fuel_rail_status = None
    if fuel_rail is not None and _baselines["fuel_rail_at_load"] is not None and engine_on:
        deviation = abs(fuel_rail - _baselines["fuel_rail_at_load"])
        if deviation < 5:
            fuel_rail_status = "Stable"
        elif deviation < 15:
            fuel_rail_status = "Variable"
        else:
            fuel_rail_status = "Unstable"
    result["fuel_rail_status"] = fuel_rail_status

    # ──────────────────────────────────────────────
    # 12. Cold Start Fuel Penalty
    # Estimated extra fuel consumption during warmup vs warm baseline
    # ──────────────────────────────────────────────
    cold_penalty_pct = None
    if engine_on and coolant_c < 60.0 and ltft != 0:
        cold_penalty_pct = round(abs(ltft) + abs(stft) * 0.5, 1)
    result["cold_start_fuel_penalty_pct"] = cold_penalty_pct

    # ──────────────────────────────────────────────
    # 13. Engine Efficiency Band
    # Optimal RPM range where VE and fuel economy converge
    # ──────────────────────────────────────────────
    efficiency_band = None
    if engine_on:
        if 1200 <= rpm <= 2500 and load < 60:
            efficiency_band = "Optimal"
        elif 2500 < rpm <= 3500:
            efficiency_band = "Power"
        elif rpm > 3500:
            efficiency_band = "Performance"
        elif rpm < 1200 and rpm >= 300:
            efficiency_band = "Low"
    result["efficiency_band"] = efficiency_band

    # ──────────────────────────────────────────────
    # 14. Overall Engine Health Score (0-100)
    # Composite: fuel trims, voltage, VE, boost consistency
    # ──────────────────────────────────────────────
    engine_health = None
    if engine_on:
        score = 100.0
        # Fuel trim penalty
        score -= min(abs(ltft) * 2.0, 20.0)
        score -= min(abs(stft) * 1.0, 10.0)
        # Voltage penalty
        if voltage < 13.0 and rpm > 1000:
            score -= 10.0
        elif voltage > 15.0:
            score -= 5.0
        # VE penalty (if available)
        if ve_pct is not None and ve_pct < 70:
            score -= (70 - ve_pct) * 0.5
        engine_health = round(max(0.0, min(100.0, score)), 0)
    result["engine_health_score"] = engine_health

    return result


def reset_trip_analytics():
    """Called when trip resets (>15 min gap)."""
    _idle["idle_seconds"] = 0.0
    _idle["idle_fuel_liters"] = 0.0
    _idle["last_ts"] = None
    _warmup["warmup_seconds"] = None
    _warmup["is_warming"] = False
    _rpm_hist.clear()
    _throttle_hist.clear()
    _pedal_hist.clear()
    _boost_hist.clear()
    _speed_hist.clear()
    _load_hist.clear()
