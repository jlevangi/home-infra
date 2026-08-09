from app import db


def test_freshness_query_uses_index_driven_latest_metric_lookups():
    sql = " ".join(db._FRESHNESS_SQL.split()).lower()

    assert "with recursive metric_types" in sql
    assert "cross join lateral" in sql
    assert "order by candidate.metric_type limit 1" in sql
    assert "order by text_to_timestamptz_immutable(observation.start_time) desc limit 1" in sql
    assert "group by metric_type" not in sql
