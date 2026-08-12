"""Registry mapping Health Connect protocol v1 record types to archive rows.

The collector sends 39 record types. Rather than a branch per type, each type
declares its shape here and health_connect.py dispatches on that shape.

Two rules govern the values below and both are load-bearing:

1. metric_type reuses the vocabulary the Health Sync CSV parser already writes
   (see parsers/csv_health.py). Health Connect's own names differ -- it says
   active_calories_burned where the archive says active_energy -- and inventing
   a second name for the same measurement splits every dashboard panel at the
   point the phone took over from the Drive exports.

2. original_type is 'health_connect_direct_<recordType>' with one exception,
   sleep, which shipped as '..._sleep_stage'. It is part of the
   (source_id, original_type, external_id) unique key, so changing it would
   re-insert every sleep stage already in the archive.
"""

from __future__ import annotations

# recordType -> (payload_field, metric_type, unit)
SCALARS = {
    "steps": ("count", "steps", "count"),
    "wheelchair_pushes": ("count", "wheelchair_pushes", "count"),
    "oxygen_saturation": ("percentage", "oxygen_saturation", "%"),
    "heart_rate_variability_rmssd": (
        "heartRateVariabilityMillis", "heart_rate_variability_rmssd", "ms"),
    "resting_heart_rate": ("beatsPerMinute", "resting_heart_rate", "count/min"),
    "total_calories_burned": ("energyKcal", "calories", "kcal"),
    "active_calories_burned": ("energyKcal", "active_energy", "kcal"),
    "weight": ("weightKg", "weight", "kg"),
    "height": ("heightMeters", "height", "m"),
    "body_fat": ("percentage", "body_fat_percentage", "%"),
    "body_water_mass": ("massKg", "body_water", "kg"),
    "bone_mass": ("massKg", "bone_mass", "kg"),
    "lean_body_mass": ("massKg", "lean_body_mass", "kg"),
    "basal_metabolic_rate": (
        "basalMetabolicRateKcalPerDay", "basal_metabolic_rate", "kcal"),
    "body_temperature": ("temperatureCelsius", "body_temperature", "Celsius"),
    "basal_body_temperature": (
        "temperatureCelsius", "basal_body_temperature", "Celsius"),
    "blood_glucose": ("levelMmolPerLiter", "blood_glucose", "mmol/L"),
    "respiratory_rate": ("rate", "respiratory_rate", "count/min"),
    "hydration": ("volumeLiters", "hydration", "L"),
    "distance": ("distanceMeters", "distance", "m"),
    # flights_climbed and vo2max (no underscore) are the names already in the
    # archive from the Apple Health and Home Assistant imports.
    "floors_climbed": ("floors", "flights_climbed", "count"),
    "elevation_gained": ("elevationMeters", "elevation_gained", "m"),
    "vo2_max": ("vo2MillilitersPerMinuteKilogram", "vo2max", "mL/min·kg"),
}

# recordType -> (sample_value_field, metric_type, unit)
# Each sample becomes its own row timestamped at the sample instant.
SAMPLE_SERIES = {
    # count/min, not bpm: 0002_normalize_vocabulary.sql collapsed both spellings
    # onto count/min, and emitting bpm here would reintroduce the split.
    "heart_rate": ("beatsPerMinute", "heart_rate", "count/min"),
    "speed": ("speedMetersPerSecond", "speed", "m/s"),
    "power": ("powerWatts", "power", "W"),
    "cycling_pedaling_cadence": (
        "revolutionsPerMinute", "cycling_pedaling_cadence", "rpm"),
    "steps_cadence": ("rate", "steps_cadence", "count/min"),
}

# recordType -> [(payload_field, metric_type, unit), ...]
# One record carries several distinct measurements; absent fields are skipped.
MULTI = {
    "blood_pressure": [
        ("systolicMmHg", "blood_pressure_systolic", "mmHg"),
        ("diastolicMmHg", "blood_pressure_diastolic", "mmHg"),
    ],
    "skin_temperature": [
        ("deltaCelsius", "skin_temperature_delta", "Celsius"),
        ("baselineCelsius", "skin_temperature_baseline", "Celsius"),
    ],
    "nutrition": [
        ("energyKcal", "dietary_energy", "kcal"),
        ("proteinGrams", "dietary_protein", "g"),
        ("totalCarbsGrams", "dietary_carbohydrates", "g"),
        ("totalFatGrams", "dietary_fat", "g"),
        ("dietaryFiberGrams", "dietary_fiber", "g"),
        ("sugarGrams", "dietary_sugar", "g"),
        ("sodiumGrams", "dietary_sodium", "g"),
        ("cholesterolGrams", "dietary_cholesterol", "g"),
    ],
}

# recordType -> (payload_field, metric_type)
# Health Connect enum codes. The integer is stored as-is rather than decoded:
# the full label tables are large, change between Health Connect releases, and
# raw_payload_json keeps the original anyway.
CODED = {
    "menstruation_flow": ("flow", "menstruation_flow"),
    "ovulation_test": ("result", "ovulation_test"),
    "cervical_mucus": ("appearance", "cervical_mucus"),
    "sexual_activity": ("protectionUsed", "sexual_activity"),
}

# recordType -> metric_type. Occurrence markers whose only payload is a note.
TEXT_NOTES = {
    "intermenstrual_bleeding": "intermenstrual_bleeding",
    "menstruation_period": "menstruation_period",
}

# Sleep and exercise_session are shaped individually in health_connect.py:
# sleep fans out over stages, and exercise_session is stored as a duration in
# minutes to match the 'exercise_session' rows the earlier health_connect
# import already wrote. Health Connect's integer exerciseType is left in
# raw_payload_json rather than decoded -- the label tables are large and shift
# between Health Connect releases.
SPECIAL = {"sleep", "exercise_session"}

# Deviations from 'health_connect_direct_<recordType>'. Do not extend casually:
# these strings are part of the archive's dedup key.
ORIGINAL_TYPE = {"sleep": "health_connect_direct_sleep_stage"}

TYPES = (
    set(SCALARS) | set(SAMPLE_SERIES) | set(MULTI) | set(CODED)
    | set(TEXT_NOTES) | SPECIAL
)


def original_type_for(record_type: str) -> str:
    return ORIGINAL_TYPE.get(record_type, f"health_connect_direct_{record_type}")
