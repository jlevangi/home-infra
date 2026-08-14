--
-- PostgreSQL database dump
--

\restrict qbApzl8VNjyQBvgjJkODzUEmnbsLu45t3ztaDEZOsp93tfhQbufhB8NLoJ1u7Le

-- Dumped from database version 16.14
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: refresh_health_daily_numeric_summaries(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_health_daily_numeric_summaries(p_from date DEFAULT (CURRENT_DATE - 3), p_to date DEFAULT CURRENT_DATE) RETURNS integer
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
      and o.metric_type in ('steps','distance','distance_cycling','active_energy','basal_energy','calories','exercise_time','stand_time','flights_climbed','active_minutes','heart_minutes','heart_rate','resting_heart_rate','heart_rate_variability_sdnn','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate','vo2max','weight','height','body_fat_percentage','basal_metabolic_rate','blood_pressure_systolic','blood_pressure_diastolic')
      and not (o.metric_type='steps' and s.source_system='apple_health')
      and not (o.metric_type='basal_energy' and s.source_system='apple_health' and o.value_numeric > 5000)
      and not (o.metric_type in ('basal_metabolic_rate','body_fat_percentage') and o.value_numeric <= 0)
  ), numeric_by_source as (
    select day, metric_type, source_id, source_system, source_name, priority,
           case when metric_type in ('heart_rate','resting_heart_rate','heart_rate_variability_sdnn','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate','vo2max','basal_metabolic_rate','blood_pressure_systolic','blood_pressure_diastolic') then avg(value)
                when metric_type in ('weight','height','body_fat_percentage') or (source_system='health_sync' and metric_type in ('basal_energy','calories')) then (array_agg(value order by start_ts desc, external_id desc))[1]
                else sum(value) end value_numeric,
           (array_agg(unit order by start_ts desc, external_id desc))[1] unit,
           case when metric_type in ('heart_rate','resting_heart_rate','heart_rate_variability_sdnn','heart_rate_variability_rmssd','oxygen_saturation','respiratory_rate','vo2max','basal_metabolic_rate','blood_pressure_systolic','blood_pressure_diastolic') then 'preferred_source_avg'
                when metric_type in ('weight','height','body_fat_percentage') or (source_system='health_sync' and metric_type in ('basal_energy','calories')) then 'preferred_source_last'
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
           case when s.source_system='health_sync' and s.source_name like '%Samsung Health%' then 44
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


--
-- Name: text_to_timestamptz_immutable(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.text_to_timestamptz_immutable(text) RETURNS timestamp with time zone
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $_$ SELECT $1::timestamptz $_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: health_daily_source_comparison; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_daily_source_comparison (
    person_id text DEFAULT 'pierce'::text NOT NULL,
    summary_date date NOT NULL,
    metric_type text NOT NULL,
    source_id integer NOT NULL,
    source_system text NOT NULL,
    source_name text NOT NULL,
    value_numeric double precision,
    unit text,
    method text NOT NULL,
    contributing_observation_count integer NOT NULL,
    priority integer NOT NULL,
    selected boolean DEFAULT false NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: health_daily_summaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_daily_summaries (
    person_id text DEFAULT 'pierce'::text NOT NULL,
    summary_date date NOT NULL,
    metric_type text NOT NULL,
    value_numeric double precision,
    unit text,
    method text NOT NULL,
    contributing_observation_count integer NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: health_ingested_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_ingested_files (
    source_system text NOT NULL,
    external_file_id text NOT NULL,
    version_key text NOT NULL,
    file_name text NOT NULL,
    folder_id text,
    folder_name text,
    modified_time timestamp with time zone,
    md5_checksum text,
    status text NOT NULL,
    observation_count integer DEFAULT 0 NOT NULL,
    inserted_count integer DEFAULT 0 NOT NULL,
    processed_at timestamp with time zone DEFAULT now() NOT NULL,
    error_text text,
    CONSTRAINT health_ingested_files_status_check CHECK ((status = ANY (ARRAY['processed'::text, 'failed'::text])))
);


--
-- Name: health_observations_raw; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_observations_raw (
    id integer NOT NULL,
    person_id text DEFAULT 'pierce'::text NOT NULL,
    source_id integer NOT NULL,
    metric_type text NOT NULL,
    original_type text NOT NULL,
    start_time text NOT NULL,
    end_time text NOT NULL,
    value_numeric real,
    value_text text,
    unit text,
    source_name text,
    device_name text,
    external_id text NOT NULL,
    raw_payload_json text NOT NULL
);


--
-- Name: health_observations_raw_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.health_observations_raw_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: health_observations_raw_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.health_observations_raw_id_seq OWNED BY public.health_observations_raw.id;


--
-- Name: health_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_sources (
    id integer NOT NULL,
    source_system text NOT NULL,
    source_name text NOT NULL,
    source_type text,
    device_name text,
    external_source_id text,
    metadata_json text DEFAULT '{}'::text NOT NULL
);


--
-- Name: health_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.health_sources_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: health_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.health_sources_id_seq OWNED BY public.health_sources.id;


--
-- Name: health_observations_raw id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_observations_raw ALTER COLUMN id SET DEFAULT nextval('public.health_observations_raw_id_seq'::regclass);


--
-- Name: health_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_sources ALTER COLUMN id SET DEFAULT nextval('public.health_sources_id_seq'::regclass);


--
-- Name: health_daily_source_comparison health_daily_source_comparison_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_daily_source_comparison
    ADD CONSTRAINT health_daily_source_comparison_pkey PRIMARY KEY (person_id, summary_date, metric_type, source_id, method);


--
-- Name: health_daily_summaries health_daily_summaries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_daily_summaries
    ADD CONSTRAINT health_daily_summaries_pkey PRIMARY KEY (person_id, summary_date, metric_type, method);


--
-- Name: health_ingested_files health_ingested_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_ingested_files
    ADD CONSTRAINT health_ingested_files_pkey PRIMARY KEY (source_system, external_file_id, version_key);


--
-- Name: health_observations_raw health_observations_raw_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_observations_raw
    ADD CONSTRAINT health_observations_raw_pkey PRIMARY KEY (id);


--
-- Name: health_observations_raw health_observations_raw_source_id_original_type_external_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_observations_raw
    ADD CONSTRAINT health_observations_raw_source_id_original_type_external_id_key UNIQUE (source_id, original_type, external_id);


--
-- Name: health_sources health_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_sources
    ADD CONSTRAINT health_sources_pkey PRIMARY KEY (id);


--
-- Name: health_sources health_sources_source_system_source_name_external_source_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_sources
    ADD CONSTRAINT health_sources_source_system_source_name_external_source_id_key UNIQUE (source_system, source_name, external_source_id);


--
-- Name: health_daily_source_comparison_bounded_delete; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX health_daily_source_comparison_bounded_delete ON public.health_daily_source_comparison USING btree (summary_date, metric_type);


--
-- Name: health_daily_source_comparison_one_selected; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX health_daily_source_comparison_one_selected ON public.health_daily_source_comparison USING btree (person_id, metric_type, summary_date) WHERE selected;


--
-- Name: health_daily_source_comparison_selected_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX health_daily_source_comparison_selected_lookup ON public.health_daily_source_comparison USING btree (person_id, metric_type, summary_date) WHERE selected;


--
-- Name: idx_health_raw_metric_type_start_time_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_raw_metric_type_start_time_ts ON public.health_observations_raw USING btree (metric_type, public.text_to_timestamptz_immutable(start_time));


--
-- Name: idx_health_raw_source_metric_start_time_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_raw_source_metric_start_time_ts ON public.health_observations_raw USING btree (source_id, metric_type, public.text_to_timestamptz_immutable(start_time) DESC);


--
-- Name: idx_health_raw_metric_end_time_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_raw_metric_end_time_ts ON public.health_observations_raw USING btree (metric_type, public.text_to_timestamptz_immutable(end_time));


--
-- Name: idx_health_raw_start_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_raw_start_time ON public.health_observations_raw USING btree (start_time);


--
-- Name: idx_raw_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_raw_external_id ON public.health_observations_raw USING btree (external_id);


--
-- Name: health_daily_source_comparison health_daily_source_comparison_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_daily_source_comparison
    ADD CONSTRAINT health_daily_source_comparison_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.health_sources(id);


--
-- Name: health_observations_raw health_observations_raw_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_observations_raw
    ADD CONSTRAINT health_observations_raw_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.health_sources(id);


--
-- PostgreSQL database dump complete
--

\unrestrict qbApzl8VNjyQBvgjJkODzUEmnbsLu45t3ztaDEZOsp93tfhQbufhB8NLoJ1u7Le

