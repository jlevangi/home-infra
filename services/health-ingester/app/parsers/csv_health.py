"""Health Sync CSV export parser.

Dispatch is driven by the CSV's own column headers rather than the Drive folder
or filename. Health Sync emits identical column layouts regardless of upstream
source (Health Connect, Samsung Health, Google Fit), and the filenames vary
enough -- 'Sleep 2026.07.27 03:01:00 Samsung Health.csv',
'Heart rate 30-2026 Samsung Health.csv', 'RHR 2026.06.19-2026.07.19 Health
Connect.csv' -- that any name-based rule silently drops whole categories.
"""

from __future__ import annotations

import csv
import io
import json

from .common import (
    js_number,
    observation,
    parse_export_datetime,
    source_name_for,
    to_float,
)


def _rows(content: bytes) -> list[dict]:
    text = content.decode("utf-8-sig", errors="replace")
    return [row for row in csv.DictReader(io.StringIO(text)) if any(v for v in row.values())]


def _payload(meta: dict, row: dict) -> str:
    return json.dumps(
        {
            "fileId": meta.get("file_id"),
            "fileName": meta.get("file_name"),
            "folderName": meta.get("folder_name"),
            "row": row,
        },
        separators=(",", ":"),
    )


def _has(row: dict, *names: str) -> bool:
    return all(name in row for name in names)


def parse(content: bytes, meta: dict) -> list[dict]:
    rows = _rows(content)
    if not rows:
        return []

    source = source_name_for(meta.get("file_name", ""))
    out: list[dict] = []

    for row in rows:
        date_str = (row.get("Date") or row.get("date") or "").strip()
        start = parse_export_datetime(date_str)
        if start is None:
            continue
        payload = _payload(meta, row)

        def emit(metric, original, external, **kw):
            out.append(
                observation(
                    metric_type=metric,
                    original_type=original,
                    start_time=start,
                    external_id=external,
                    source_name=source,
                    raw_payload=payload,
                    **kw,
                )
            )

        # --- simple scalar metrics -------------------------------------
        if _has(row, "Steps") and not _has(row, "Activity type"):
            value = to_float(row["Steps"])
            if value and value > 0:
                emit(
                    "steps",
                    "health_sync_steps",
                    f"hs_steps_{date_str}_{js_number(value)}",
                    end_time=None,
                    value_numeric=value,
                    unit="count",
                )

        if _has(row, "Heart rate"):
            value = to_float(row["Heart rate"])
            if value and value > 0:
                emit(
                    "heart_rate",
                    "health_sync_heart_rate",
                    f"hs_hr_{date_str}_{js_number(value)}",
                    end_time=None,
                    value_numeric=value,
                    unit="count/min",
                )

        if _has(row, "Resting heart rate"):
            value = to_float(row["Resting heart rate"])
            if value and value > 0:
                emit(
                    "resting_heart_rate",
                    "health_sync_resting_heart_rate",
                    f"hs_rhr_{date_str}_{js_number(value)}",
                    end_time=None,
                    value_numeric=value,
                    unit="count/min",
                )

        if _has(row, "Oxygen saturation"):
            value = to_float(row["Oxygen saturation"])
            if value and value > 0:
                emit(
                    "oxygen_saturation",
                    "health_sync_oxygen_saturation",
                    f"hs_o2_{date_str}_{js_number(value)}",
                    end_time=None,
                    value_numeric=value,
                    unit="%",
                )

        # --- energy ----------------------------------------------------
        for column, metric, original in (
            ("Active calories", "active_energy", "health_sync_active_calories"),
            ("Resting calories", "basal_energy", "health_sync_resting_calories"),
            ("Total calories", "calories", "health_sync_total_calories"),
        ):
            if column not in row:
                continue
            value = to_float(row[column])
            if value is not None and value != 0:
                emit(
                    metric,
                    original,
                    f"hs_{original}_{date_str}_{js_number(value)}",
                    end_time=None,
                    value_numeric=value,
                    unit="kcal",
                )

        # --- sleep -----------------------------------------------------
        if _has(row, "Duration in seconds", "Sleep stage"):
            duration = to_float(row["Duration in seconds"])
            stage = (row.get("Sleep stage") or "").strip().lower()
            if duration and duration > 0 and stage:
                end = start.fromtimestamp(start.timestamp() + duration, tz=start.tzinfo)
                emit(
                    "sleep_segment",
                    "health_sync_sleep_stage",
                    f"hs_sleep_{date_str}_{js_number(duration)}_{stage}",
                    end_time=end,
                    value_text=stage,
                    unit=None,
                )

        # --- body composition -----------------------------------------
        if _has(row, "Weight"):
            for column, metric, original, unit in (
                ("Weight", "weight", "health_sync_weight", row.get("Unit") or "kg"),
                ("Body fat percentage", "body_fat_percentage", "health_sync_body_fat_percentage", "%"),
                ("Skeletal muscle mass", "skeletal_muscle_mass", "health_sync_skeletal_muscle_mass", "kg"),
                ("Bone mass", "bone_mass", "health_sync_bone_mass", "kg"),
                ("Total body water", "body_water", "health_sync_body_water", "kg"),
                ("Basal metabolic rate", "basal_metabolic_rate", "health_sync_basal_metabolic_rate", "kcal"),
            ):
                if column not in row:
                    continue
                value = to_float(row[column])
                if value is None or value <= 0:
                    continue
                suffix = "weight" if column == "Weight" else original
                emit(
                    metric,
                    original,
                    f"hs_{suffix}_{date_str}_{js_number(value)}",
                    end_time=None,
                    value_numeric=value,
                    unit=unit,
                )

        # --- activity summaries ----------------------------------------
        if _has(row, "Activity type"):
            activity = row.get("Activity type") or "activity"
            elapsed = to_float(row.get("Elapsed time")) or 0.0
            active = to_float(row.get("Active time"))
            end = start.fromtimestamp(start.timestamp() + elapsed, tz=start.tzinfo)

            emit(
                "activity_segment",
                "health_sync_activity",
                f"hs_act_{date_str}_{activity}_{js_number(elapsed)}",
                end_time=end,
                value_numeric=active,
                value_text=activity,
                unit="s",
            )

            distance_mi = to_float(row.get("Distance (miles)"))
            if distance_mi and distance_mi > 0:
                emit(
                    "distance",
                    "health_sync_activity_distance",
                    f"hs_dist_{date_str}_{js_number(distance_mi)}",
                    end_time=end,
                    value_numeric=distance_mi * 1609.344,
                    unit="m",
                )

            calories = to_float(row.get("Calories (kcal)"))
            if calories and calories > 0:
                emit(
                    "active_energy",
                    "health_sync_activity_calories",
                    f"hs_cal_{date_str}_{js_number(calories)}",
                    end_time=end,
                    value_numeric=calories,
                    unit="kcal",
                )

            avg_hr = to_float(row.get("Average heart rate"))
            if avg_hr and avg_hr > 0:
                emit(
                    "heart_rate",
                    "health_sync_activity_avg_hr",
                    f"hs_act_hr_{date_str}_{js_number(avg_hr)}",
                    end_time=end,
                    value_numeric=avg_hr,
                    unit="count/min",
                )

            steps = to_float(row.get("Steps"))
            if steps and steps > 0:
                emit(
                    "steps",
                    "health_sync_activity_steps",
                    f"hs_act_steps_{date_str}_{js_number(steps)}",
                    end_time=end,
                    value_numeric=steps,
                    unit="count",
                )

    return out
