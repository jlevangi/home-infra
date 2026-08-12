-- Revive the daily precedence rollup and teach it the collector.
--
-- refresh_health_daily_numeric_summaries already resolves the same
-- measurement arriving from several sources: it ranks sources per metric per
-- day, keeps the winner in health_daily_summaries and records every source's
-- value in health_daily_source_comparison. Nothing has called it since the v2
-- n8n workflow dropped the call, so both tables are stale.
--
-- Two changes. health_connect_direct did not exist when this was written and
-- was scoring 0, below every other source, so the phone would have lost every
-- tie. And the metric list predates 0002, so the renamed Apple metrics were
-- invisible to it.

CREATE OR REPLACE FUNCTION public.refresh_health_daily_numeric_summaries(p_from date DEFAULT (CURRENT_DATE - 3), p_to date DEFAULT CURRENT_DATE) RETURNS integer
    LANGUAGE plpgsql
    AS $$
declare changed integer;
begin
  if p_from > p_to then
    raise exception 'p_from (%) must be <= p_to (%)', p_from, p_to;
  end if;

  delete from health_daily_summaries where summary_date::date between p_from and p_to;
  delete from health_daily_source_comparison where summary_date::date between p_from and p_to;

  with raw_numeric as (
    select (o.start_time::timestamptz at time zone 'America/New_York')::date as day,
           o.metric_type, o.source_id, s.source_system, s.source_name,
           o.start_time::timestamptz start_ts, o.external_id, o.value_numeric,
           case
             when o.metric_type in ('distance','distance_cycling') and o.unit='mi' then o.value_numeric * 1609.344
             when o.metric_type in ('distance','distance_cycling') and o.unit='m' then o.value_numeric
             when o.metric_type='weight' and o.unit='lb' then o.value_numeric * 0.45359237
             when o.metric_type='weight' and o.unit='kg' then o.value_numeric
             when o.metric_type='height' and o.unit='ft' then o.value_numeric * 0.3048
             when o.metric_type='height' and o.unit='m' then o.value_numeric
             when o.metric_type='oxygen_saturation' and o.unit='%' and o.value_numeric <= 1 then o.value_numeric * 100
             when o.metric_type='oxygen_saturation' and o.unit='%' then o.value_numeric
             when o.metric_type in ('active_energy','basal_energy','calories') and o.unit in ('Cal','kcal') then o.value_numeric
             when o.metric_type not in ('distance','distance_cycling','weight','height','oxygen_saturation','active_energy','basal_energy','calories') then o.value_numeric
           end::double precision value,
           case
             when o.metric_type in ('distance','distance_cycling') then 'm'
             when o.metric_type in ('active_energy','basal_energy','calories') then 'kcal'
             when o.metric_type='weight' then 'kg'
             when o.metric_type='height' then 'm'
             when o.metric_type='steps' then 'count'
             when o.metric_type='oxygen_saturation' then '%'
             else o.unit
           end unit,
           case
             when s.source_system='health_connect_direct' then 50
             when s.source_system='health_sync' and s.source_name like '%Samsung Health%' then 44
             when s.source_system='health_sync' and s.source_name like '%Health Connect%' then 43
             when s.source_system='health_sync' and s.source_name like '%Google Fit%' then 42
             when s.source_system='health_sync' then 40
             when s.source_system='health_connect' and o.metric_type='steps' and s.source_name='Fit' then 41
             when s.source_system='health_connect' and o.metric_type='steps' and s.source_name='Pixel 9 Pro XL' then 40
             when s.source_system='health_connect' and o.metric_type='steps' and s.source_name='Zepp' then 39
             when s.source_system='health_connect' and o.metric_type='steps' then 38
             when s.source_system='health_connect' and o.metric_type in ('heart_rate','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate') and s.source_name='Zepp' then 42
             when s.source_system='health_connect' and o.metric_type='resting_heart_rate' and s.source_name='Sleep' then 42
             when s.source_system='health_connect' then 40
             when s.source_system='home_assistant' then 30
             when s.source_system='apple_health' and o.metric_type in ('heart_rate','resting_heart_rate','heart_rate_variability_sdnn') then 25
             when s.source_system='google_fit' and o.metric_type='steps' and s.source_name like '%merge_step_deltas%' then 24
             when s.source_system='google_fit' and o.metric_type='steps' and s.source_name like '%top_level%' then 23
             when s.source_system='google_fit' and o.metric_type='steps' and s.source_name like '%estimated_steps%' then 22
             when s.source_system='google_fit' and o.metric_type='steps' then 21
             when s.source_system='google_fit' then 20
             when s.source_system='apple_health' then 10 else 0 end priority
    from health_observations_raw o join health_sources s on s.id=o.source_id
    where o.value_numeric is not null
      and o.start_time >= (p_from - 1)::text and o.start_time < (p_to + 2)::text
      and (o.start_time::timestamptz at time zone 'America/New_York')::date between p_from and p_to
      and o.metric_type in ('steps','distance','distance_cycling','active_energy','basal_energy','calories','exercise_time','stand_time','flights_climbed','active_minutes','heart_minutes','heart_rate','resting_heart_rate','heart_rate_variability_sdnn','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate','vo2max','weight','height','body_fat_percentage','basal_metabolic_rate','blood_pressure_systolic','blood_pressure_diastolic','walking_speed','speed','stair_ascent_speed','stair_descent_speed','walking_step_length','walking_asymmetry_percentage','walking_double_support_percentage','walking_steadiness','walking_heart_rate_average','physical_effort','headphone_audio_exposure','environmental_audio_exposure','environmental_sound_reduction','sleeping_wrist_temperature','body_temperature','basal_body_temperature','blood_glucose','skin_temperature_delta','skin_temperature_baseline','hydration','time_in_daylight','stand_hour','elevation_gained','wheelchair_pushes','six_minute_walk_test_distance','dietary_energy','dietary_protein','dietary_carbohydrates','dietary_fat','dietary_fiber','dietary_sugar','dietary_sodium','dietary_cholesterol','lean_body_mass','bone_mass','body_water')
      and not (o.metric_type='steps' and s.source_system='apple_health')
      and not (o.metric_type='basal_energy' and s.source_system='apple_health' and o.value_numeric > 5000)
      and not (o.metric_type in ('basal_metabolic_rate','body_fat_percentage') and o.value_numeric <= 0)
  ), numeric_by_source as (
    select day, metric_type, source_id, source_system, source_name, priority,
           case when metric_type in ('heart_rate','resting_heart_rate','heart_rate_variability_sdnn','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate','vo2max','basal_metabolic_rate','blood_pressure_systolic','blood_pressure_diastolic','walking_speed','speed','stair_ascent_speed','stair_descent_speed','walking_step_length','walking_asymmetry_percentage','walking_double_support_percentage','walking_steadiness','walking_heart_rate_average','physical_effort','headphone_audio_exposure','environmental_audio_exposure','environmental_sound_reduction','sleeping_wrist_temperature','body_temperature','basal_body_temperature','blood_glucose','skin_temperature_delta','skin_temperature_baseline') then avg(value)
                when metric_type in ('weight','height','body_fat_percentage','lean_body_mass','bone_mass','body_water') or (source_system='health_sync' and metric_type in ('basal_energy','calories')) then (array_agg(value order by start_ts desc, external_id desc))[1]
                else sum(value) end value_numeric,
           (array_agg(unit order by start_ts desc, external_id desc))[1] unit,
           case when metric_type in ('heart_rate','resting_heart_rate','heart_rate_variability_sdnn','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate','vo2max','basal_metabolic_rate','blood_pressure_systolic','blood_pressure_diastolic','walking_speed','speed','stair_ascent_speed','stair_descent_speed','walking_step_length','walking_asymmetry_percentage','walking_double_support_percentage','walking_steadiness','walking_heart_rate_average','physical_effort','headphone_audio_exposure','environmental_audio_exposure','environmental_sound_reduction','sleeping_wrist_temperature','body_temperature','basal_body_temperature','blood_glucose','skin_temperature_delta','skin_temperature_baseline') then 'preferred_source_avg'
                when metric_type in ('weight','height','body_fat_percentage','lean_body_mass','bone_mass','body_water') or (source_system='health_sync' and metric_type in ('basal_energy','calories')) then 'preferred_source_last'
                else 'preferred_source_sum' end method,
           count(*)::integer observation_count
    from raw_numeric where value is not null
    group by day,metric_type,source_id,source_system,source_name,priority
  ), intervals as (
    select o.metric_type, o.source_id, s.source_system, s.source_name,
           case when o.metric_type='sleep_segment' then
             case when lower(coalesce(o.value_text,'')) like '%light%' or lower(coalesce(o.value_text,'')) like '%core%' then 'sleep_light_hours'
                  when lower(coalesce(o.value_text,'')) like '%deep%' then 'sleep_deep_hours'
                  when lower(coalesce(o.value_text,'')) like '%rem%' then 'sleep_rem_hours'
                  when lower(coalesce(o.value_text,'')) like '%awake%' then 'sleep_awake_hours'
                  when lower(coalesce(o.value_text,'')) like '%inbed%' or lower(coalesce(o.value_text,'')) like '%in_bed%' then 'sleep_in_bed_hours'
                  when lower(coalesce(o.value_text,'')) like '%asleep%' then 'sleep_unspecified_hours' end
             else 'workout_hours' end metric_type_out,
           case when s.source_system='health_connect_direct' then 50
             when s.source_system='health_sync' and s.source_name like '%Samsung Health%' then 44
                when s.source_system='health_connect' then 40 when s.source_system='apple_health' then 10 else 20 end priority,
           o.start_time::timestamptz start_ts, o.end_time::timestamptz end_ts
    from health_observations_raw o join health_sources s on s.id=o.source_id
    where o.metric_type in ('sleep_segment','exercise_session','workout_session')
      -- Lexical ISO bounds avoid casting the whole raw archive before date checks.
      and o.start_time < (p_to + 2)::text and o.end_time >= (p_from - 1)::text
      and o.end_time::timestamptz > o.start_time::timestamptz
      and (o.start_time::timestamptz at time zone 'America/New_York')::date <= p_to
      and (o.end_time::timestamptz at time zone 'America/New_York')::date >= p_from
  ), split_intervals as (
    select i.metric_type_out, i.source_id, i.source_system, i.source_name, i.priority,
           d::date as day,
           greatest(i.start_ts, (d::timestamp at time zone 'America/New_York')) start_ts,
           least(i.end_ts, (((d::date + 1)::timestamp) at time zone 'America/New_York')) end_ts
    from intervals i cross join lateral generate_series(
      greatest(p_from, (i.start_ts at time zone 'America/New_York')::date),
      least(p_to, (i.end_ts at time zone 'America/New_York')::date), interval '1 day') d
    where i.metric_type_out is not null
  ), interval_by_source as (
    select day,metric_type_out metric_type,source_id,source_system,source_name,priority,
           extract(epoch from sum(upper(ranges.r)-lower(ranges.r)))/3600.0 value_numeric,
           'h'::text unit,'preferred_source_union'::text method,count(*)::integer observation_count
    from (select day,metric_type_out,source_id,source_system,source_name,priority,
                 range_agg(tstzrange(start_ts,end_ts,'[)')) r
          from split_intervals where end_ts>start_ts
          group by day,metric_type_out,source_id,source_system,source_name,priority) x
    cross join lateral unnest(x.r) as ranges(r)
    group by day,metric_type_out,source_id,source_system,source_name,priority
  ), candidates as (
    select * from numeric_by_source union all select * from interval_by_source
  ), ranked as (
    select *, row_number() over (partition by day,metric_type order by priority desc,source_system asc,source_name asc,source_id asc) source_rank
    from candidates
  ), ins_comparison as (
    insert into health_daily_source_comparison (person_id,summary_date,metric_type,source_id,source_system,source_name,value_numeric,unit,method,contributing_observation_count,priority,selected)
    select 'pierce',day,metric_type,source_id,source_system,source_name,value_numeric,unit,method,observation_count,priority,(source_rank=1)
    from ranked returning 1
  ), ins_summary as (
    insert into health_daily_summaries (person_id,summary_date,metric_type,value_numeric,unit,method,contributing_observation_count)
    select 'pierce',day,metric_type,value_numeric,unit,method,observation_count from ranked where source_rank=1
    returning 1
  ), heart_companions as (
    insert into health_daily_summaries (person_id,summary_date,metric_type,value_numeric,unit,method,contributing_observation_count)
    select 'pierce',day,metric_type||'_min',min(value),null,'preferred_source_avg',count(*)::integer
    from raw_numeric r join ranked x using(day,metric_type,source_id) where r.metric_type='heart_rate' and x.source_rank=1 group by day,metric_type
    union all select 'pierce',day,metric_type||'_max',max(value),null,'preferred_source_avg',count(*)::integer
    from raw_numeric r join ranked x using(day,metric_type,source_id) where r.metric_type='heart_rate' and x.source_rank=1 group by day,metric_type
    union all select 'pierce',day,'heart_rate_sample_count',count(*)::double precision,null,'preferred_source_avg',count(*)::integer
    from raw_numeric r join ranked x using(day,metric_type,source_id) where r.metric_type='heart_rate' and x.source_rank=1 group by day
    returning 1
  ) select (select count(*) from ins_comparison)+(select count(*) from ins_summary)+(select count(*) from heart_companions) into changed;
  return changed;
end;
$$;
