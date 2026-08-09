"""Workout export parsers: TCX / GPX (XML) and FIT (binary).

Health Sync writes one workout as several sibling files -- .csv, .tcx, .gpx,
.kml, .fit. The .csv summary is handled by csv_health; these formats carry the
per-trackpoint detail (heart-rate series, cadence, GPS) that the summary drops.

Only the time series is emitted here. Workout totals already arrive via the
.csv sibling, so re-deriving them would double-count distance and calories.
"""

from __future__ import annotations

import io
import json
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

from .common import iso_z, js_number, observation, source_name_for

TCX_NS = {
    "tcx": "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2",
    "ext": "http://www.garmin.com/xmlschemas/ActivityExtension/v2",
}
GPX_NS = {
    "gpx": "http://www.topografix.com/GPX/1/1",
    "tpx": "http://www.garmin.com/xmlschemas/TrackPointExtension/v1",
}


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _payload(meta: dict, extra: dict) -> str:
    return json.dumps(
        {
            "fileId": meta.get("file_id"),
            "fileName": meta.get("file_name"),
            "folderName": meta.get("folder_name"),
            **extra,
        },
        separators=(",", ":"),
    )


def _series(meta: dict, samples: list[tuple[datetime, float]], kind: str) -> list[dict]:
    """Emit a heart-rate time series with a stable, collision-free external_id."""
    source = source_name_for(meta.get("file_name", ""))
    out = []
    for when, value in samples:
        stamp = iso_z(when)
        out.append(
            observation(
                metric_type="heart_rate",
                original_type=f"health_sync_{kind}_hr",
                start_time=when,
                end_time=when,
                external_id=f"hs_{kind}_hr_{stamp}_{js_number(value)}",
                value_numeric=value,
                unit="count/min",
                source_name=source,
                raw_payload=_payload(meta, {"time": stamp, "heart_rate": value}),
            )
        )
    return out


def parse_tcx(content: bytes, meta: dict) -> list[dict]:
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        return []
    samples: list[tuple[datetime, float]] = []
    for point in root.iterfind(".//tcx:Trackpoint", TCX_NS):
        when = _parse_iso(point.findtext("tcx:Time", namespaces=TCX_NS))
        raw = point.findtext("tcx:HeartRateBpm/tcx:Value", namespaces=TCX_NS)
        if when is None or raw is None:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        if value > 0:
            samples.append((when, value))
    return _series(meta, samples, "tcx")


def parse_gpx(content: bytes, meta: dict) -> list[dict]:
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        return []
    samples: list[tuple[datetime, float]] = []
    for point in root.iterfind(".//gpx:trkpt", GPX_NS):
        when = _parse_iso(point.findtext("gpx:time", namespaces=GPX_NS))
        raw = point.findtext(".//tpx:hr", namespaces=GPX_NS)
        if when is None or raw is None:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        if value > 0:
            samples.append((when, value))
    return _series(meta, samples, "gpx")


def parse_fit(content: bytes, meta: dict) -> list[dict]:
    try:
        from fitparse import FitFile
    except ImportError:  # pragma: no cover - dependency is declared in the image
        return []
    try:
        fit = FitFile(io.BytesIO(content))
        messages = list(fit.get_messages("record"))
    except Exception:
        # FIT files are binary and Health Sync's writer is not always clean;
        # a malformed file must not fail the whole ingest run.
        return []

    samples: list[tuple[datetime, float]] = []
    for message in messages:
        values = message.get_values()
        when = values.get("timestamp")
        raw = values.get("heart_rate")
        if when is None or raw is None:
            continue
        if isinstance(when, datetime):
            when = when.replace(tzinfo=timezone.utc) if when.tzinfo is None else when
        else:
            continue
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        if value > 0:
            samples.append((when.astimezone(timezone.utc), value))
    return _series(meta, samples, "fit")
