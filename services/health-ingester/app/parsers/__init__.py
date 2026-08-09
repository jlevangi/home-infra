"""Format dispatch for Health Sync exports."""

from __future__ import annotations

from . import csv_health, workout

# .kml carries only route geometry that .gpx/.tcx already express, so it is
# recognised and skipped rather than treated as an unsupported failure.
SKIPPED_SUFFIXES = (".kml",)


def parse(content: bytes, meta: dict) -> tuple[list[dict], str]:
    """Return (observations, format_label).

    format_label is 'skipped' for known-but-ignored types and 'unsupported'
    for anything unrecognised; callers record both in the ledger so silent
    drops stay visible.
    """
    name = (meta.get("file_name") or "").lower()

    if name.endswith(".csv"):
        return csv_health.parse(content, meta), "csv"
    if name.endswith(".tcx"):
        return workout.parse_tcx(content, meta), "tcx"
    if name.endswith(".gpx"):
        return workout.parse_gpx(content, meta), "gpx"
    if name.endswith(".fit"):
        return workout.parse_fit(content, meta), "fit"
    if name.endswith(SKIPPED_SUFFIXES):
        return [], "skipped"
    return [], "unsupported"
