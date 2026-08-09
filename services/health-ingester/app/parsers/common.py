"""Shared helpers for Health Sync export parsers.

The values produced here must stay byte-compatible with the n8n workflow this
service replaces: external_id strings are the dedup key in
health_observations_raw (source_id, original_type, external_id), so any change
in formatting would re-insert rows that already exist.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

# Health Sync writes wall-clock timestamps with no offset. The n8n workflow
# interpreted them as America/New_York; keep that reading so old and new rows
# describe the same instant.
EXPORT_TZ = ZoneInfo("America/New_York")

_DATE_RE = re.compile(r"(\d{4})\.(\d{2})\.(\d{2})\s+(\d{2}):(\d{2}):(\d{2})")


def parse_export_datetime(value: str) -> datetime | None:
    """Parse 'YYYY.MM.DD HH:MM:SS' as export-local time, returned as UTC."""
    if not value:
        return None
    match = _DATE_RE.search(value)
    if not match:
        return None
    year, month, day, hour, minute, second = (int(part) for part in match.groups())
    try:
        local = datetime(year, month, day, hour, minute, second, tzinfo=EXPORT_TZ)
    except ValueError:
        return None
    return local.astimezone(timezone.utc)


def iso_z(value: datetime) -> str:
    """Render as '...Z', matching JavaScript's Date.toISOString()."""
    return (
        value.astimezone(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def js_number(value: float) -> str:
    """Stringify a float the way JavaScript template literals do.

    JS renders 94.0 as "94" while Python's str() gives "94.0". external_id
    values were built with JS semantics, so integral floats must lose the
    trailing ".0" or dedup against existing rows breaks.
    """
    if value == int(value):
        return str(int(value))
    return repr(value)


def to_float(value: object) -> float | None:
    """Best-effort float conversion mirroring JS parseFloat leniency."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    match = re.match(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", text)
    if not match:
        return None
    try:
        return float(match.group(0))
    except ValueError:
        return None


def source_name_for(file_name: str) -> str:
    """Derive the health_sources.source_name from the export filename."""
    if "Samsung Health" in file_name:
        return "Health Sync / Samsung Health"
    if "Google Fit" in file_name:
        return "Health Sync / Google Fit"
    if "Health Connect" in file_name:
        return "Health Sync / Health Connect"
    return "Health Sync"


def observation(
    *,
    metric_type: str,
    original_type: str,
    start_time: datetime,
    end_time: datetime | None,
    external_id: str,
    value_numeric: float | None = None,
    value_text: str | None = None,
    unit: str | None = None,
    source_name: str,
    raw_payload: str,
) -> dict:
    return {
        "metric_type": metric_type,
        "original_type": original_type,
        "start_time": iso_z(start_time),
        "end_time": iso_z(end_time if end_time is not None else start_time),
        "value_numeric": value_numeric,
        "value_text": value_text,
        "unit": unit,
        "source_name": source_name,
        "external_id": external_id,
        "raw_payload_json": raw_payload,
    }
