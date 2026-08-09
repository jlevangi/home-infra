"""Parser tests built from rows actually present in health_observations_raw.

The literal expectations here (external_id strings, UTC timestamps) come from
production data written by the n8n workflow. They are the compatibility
contract: if these change, the ingester will duplicate existing rows.
"""

import json

from app.parsers import parse
from app.parsers.common import js_number, parse_export_datetime, iso_z


def meta(name, folder=None):
    return {
        "file_id": "f1",
        "version_key": "1",
        "file_name": name,
        "folder_name": folder or "",
    }


def by_type(observations):
    return {o["original_type"]: o for o in observations}


def test_export_timestamps_are_interpreted_as_eastern():
    # 21:25 EDT is 01:25 UTC the following day; production rows agree.
    parsed = parse_export_datetime("2026.08.05 21:25:00")
    assert iso_z(parsed) == "2026-08-06T01:25:00.000Z"


def test_js_number_matches_javascript_stringification():
    # external_id values were built in JS, where 94.0 renders as "94".
    assert js_number(94.0) == "94"
    assert js_number(186.375) == "186.375"
    assert js_number(0.19617392) == "0.19617392"


def test_health_connect_heart_rate_matches_existing_external_id():
    csv = b"Date,Time,Heart rate,Source\n2026.08.05 21:25:00,21:25:00,87,com.huami.watch.hmwatchmanager\n"
    observations, fmt = parse(csv, meta("Heart rate 2026.08.05 Health Connect.csv"))
    assert fmt == "csv"
    assert len(observations) == 1
    row = observations[0]
    assert row["external_id"] == "hs_hr_2026.08.05 21:25:00_87"
    assert row["metric_type"] == "heart_rate"
    assert row["unit"] == "count/min"
    assert row["start_time"] == "2026-08-06T01:25:00.000Z"
    assert row["source_name"] == "Health Sync / Health Connect"


def test_energy_row_emits_three_metrics_with_legacy_ids():
    csv = (
        b"Date,Time,Active calories,Resting calories,Total calories\n"
        b"2026.08.07 00:00:00,00:00:00,186.375,1568.3721923828125,1754.7471923828125\n"
    )
    observations, _ = parse(csv, meta("Energy burned 2026.08.07 Health Connect.csv"))
    found = by_type(observations)
    assert found["health_sync_active_calories"]["external_id"] == (
        "hs_health_sync_active_calories_2026.08.07 00:00:00_186.375"
    )
    assert found["health_sync_resting_calories"]["metric_type"] == "basal_energy"
    assert found["health_sync_total_calories"]["metric_type"] == "calories"


def test_samsung_sleep_file_parses_despite_filename():
    # This filename has a time component and a 'Samsung Health' suffix -- the
    # old selector rejected it outright, which is why sleep data stopped.
    csv = (
        b"Date,Time,Duration in seconds,Sleep stage\n"
        b"2026.07.27 10:15:00,10:15:00,60,awake\n"
    )
    observations, _ = parse(
        csv, meta("Sleep 2026.07.27 03:01:00 Samsung Health.csv", "Health Sync Sleep")
    )
    assert len(observations) == 1
    row = observations[0]
    assert row["metric_type"] == "sleep_segment"
    assert row["value_text"] == "awake"
    assert row["source_name"] == "Health Sync / Samsung Health"
    # 60s segment starting 10:15 EDT -> 14:15Z .. 14:16Z
    assert row["start_time"] == "2026-07-27T14:15:00.000Z"
    assert row["end_time"] == "2026-07-27T14:16:00.000Z"


def test_week_numbered_samsung_heart_rate_file_parses():
    # 'Heart rate 30-2026 Samsung Health.csv' carries no YYYY.MM.DD token, so
    # the old single-date-token rule dropped it. Dispatch is column-based now.
    csv = b"Date,Time,Heart rate,Source\n2026.07.22 08:59:00,08:59:00,67,\n"
    observations, _ = parse(csv, meta("Heart rate 30-2026 Samsung Health.csv"))
    assert len(observations) == 1
    assert observations[0]["value_numeric"] == 67


def test_resting_heart_rate_range_named_file_parses():
    csv = b"Date,Time,Resting heart rate,Source\n2026.06.27 00:00:00,00:00:00,80,x\n"
    observations, _ = parse(
        csv, meta("RHR 2026.06.19-2026.07.19 Health Connect.csv")
    )
    assert len(observations) == 1
    assert observations[0]["metric_type"] == "resting_heart_rate"


def test_weight_file_emits_body_composition():
    csv = (
        b"Date,Time,Weight,Body fat percentage,Basal metabolic rate\n"
        b"2025.10.07 16:40:26,16:40:26,168.6,18.5,1600\n"
    )
    observations, _ = parse(csv, meta("Weight 2025.10.07 Samsung Health.csv"))
    found = by_type(observations)
    assert found["health_sync_weight"]["value_numeric"] == 168.6
    assert found["health_sync_body_fat_percentage"]["value_numeric"] == 18.5
    assert found["health_sync_basal_metabolic_rate"]["value_numeric"] == 1600


def test_zero_valued_body_composition_columns_are_skipped():
    # Samsung writes 0.0 for unmeasured fields; those are absent, not zero.
    csv = (
        b"Date,Time,Weight,Body fat percentage,Bone mass\n"
        b"2025.10.07 16:40:26,16:40:26,168.6,0.0,0.0\n"
    )
    observations, _ = parse(csv, meta("Weight 2025.10.07 Samsung Health.csv"))
    assert set(by_type(observations)) == {"health_sync_weight"}


def test_activity_summary_emits_segment_distance_calories_and_hr():
    csv = (
        b"Source app,Activity type,Activity name,Date,Time,Elapsed time,Active time,"
        b"Distance (miles),Calories (kcal),Steps,Average heart rate,Max heart rate\n"
        b"null,WALKING,null,2026.07.25 17:48:34,17:48:34,987,987,"
        b"0.19617392,79.680984,1352,93,110\n"
    )
    observations, _ = parse(
        csv, meta("WALKING 2026.07.25 17.48.csv", "Health Sync Activities")
    )
    found = by_type(observations)
    assert found["health_sync_activity"]["value_text"] == "WALKING"
    assert found["health_sync_activity"]["external_id"] == (
        "hs_act_2026.07.25 17:48:34_WALKING_987"
    )
    # miles -> metres
    assert round(found["health_sync_activity_distance"]["value_numeric"], 3) == 315.711
    assert found["health_sync_activity_avg_hr"]["value_numeric"] == 93
    assert found["health_sync_activity_steps"]["value_numeric"] == 1352


def test_activity_steps_do_not_collide_with_daily_step_rows():
    csv = (
        b"Source app,Activity type,Date,Elapsed time,Steps\n"
        b"null,WALKING,2026.07.25 17:48:34,987,1352\n"
    )
    observations, _ = parse(csv, meta("WALKING 2026.07.25 17.48.csv"))
    step_rows = [o for o in observations if o["metric_type"] == "steps"]
    assert len(step_rows) == 1
    assert step_rows[0]["original_type"] == "health_sync_activity_steps"


def test_tcx_trackpoints_become_heart_rate_series():
    tcx = b"""<?xml version="1.0"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities><Activity Sport="Walking"><Lap><Track>
    <Trackpoint><Time>2026-07-28T21:26:00Z</Time>
      <HeartRateBpm><Value>92</Value></HeartRateBpm></Trackpoint>
    <Trackpoint><Time>2026-07-28T21:26:05Z</Time>
      <HeartRateBpm><Value>95</Value></HeartRateBpm></Trackpoint>
  </Track></Lap></Activity></Activities>
</TrainingCenterDatabase>"""
    observations, fmt = parse(tcx, meta("2026.07.28 17.26-WALKING.tcx"))
    assert fmt == "tcx"
    assert len(observations) == 2
    assert observations[0]["metric_type"] == "heart_rate"
    assert observations[0]["external_id"] == "hs_tcx_hr_2026-07-28T21:26:00.000Z_92"


def test_gpx_heart_rate_extension_is_read():
    gpx = b"""<?xml version="1.0"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="1" lon="2"><time>2026-07-28T21:26:00Z</time>
      <extensions><TrackPointExtension
        xmlns="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
        <hr>101</hr></TrackPointExtension></extensions></trkpt>
  </trkseg></trk>
</gpx>"""
    observations, fmt = parse(gpx, meta("2026.07.28 17.26-WALKING.gpx"))
    assert fmt == "gpx"
    assert len(observations) == 1
    assert observations[0]["value_numeric"] == 101


def test_kml_is_skipped_not_treated_as_failure():
    observations, fmt = parse(b"<kml/>", meta("2026.07.28 17.26-WALKING.kml"))
    assert (observations, fmt) == ([], "skipped")


def test_unknown_extension_is_reported_as_unsupported():
    observations, fmt = parse(b"whatever", meta("notes.txt"))
    assert (observations, fmt) == ([], "unsupported")


def test_malformed_rows_are_skipped_without_failing_the_file():
    csv = (
        b"Date,Time,Heart rate\n"
        b"not-a-date,,80\n"
        b"2026.08.05 21:25:00,21:25:00,87\n"
        b"2026.08.05 21:26:00,21:26:00,\n"
    )
    observations, _ = parse(csv, meta("Heart rate 2026.08.05 Health Connect.csv"))
    assert len(observations) == 1
    assert observations[0]["value_numeric"] == 87


def test_raw_payload_round_trips_the_source_row():
    csv = b"Date,Time,Steps\n2026.08.08 12:57:01,12:57:01,8\n"
    observations, _ = parse(csv, meta("Steps 2026.08.08 Health Connect.csv", "Health Sync Steps"))
    payload = json.loads(observations[0]["raw_payload_json"])
    assert payload["row"]["Steps"] == "8"
    assert payload["folderName"] == "Health Sync Steps"
    assert observations[0]["external_id"] == "hs_steps_2026.08.08 12:57:01_8"
