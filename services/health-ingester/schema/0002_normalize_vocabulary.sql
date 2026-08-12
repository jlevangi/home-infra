-- Normalise the archive to one vocabulary and one unit per measurement.
--
-- The archive merged six source systems (apple_health, google_fit, health_sync,
-- health_connect, health_connect_direct, home_assistant) that each named and
-- measured the same things differently. It is all one person's health data, so
-- metric_type and unit should not depend on which app happened to record it.
-- source_system and original_type stay untouched and remain the means of
-- telling sources apart for deduplication and provenance.
--
-- Every statement keys off the value it is replacing, so re-running this file
-- is a no-op. raw_payload_json still holds the original as received.
--
-- NOTE: value_numeric is `real`, so converted values carry ~7 significant
-- digits. That is unchanged by this migration; see 0001_baseline.sql.

BEGIN;

-- 1. Apple identifiers become readable names.
--    235k rows across 25 types were still named HKQuantityTypeIdentifier*,
--    which no dashboard panel could ever match.
UPDATE health_observations_raw SET metric_type = CASE metric_type
    WHEN 'HKQuantityTypeIdentifierPhysicalEffort'                   THEN 'physical_effort'
    WHEN 'HKQuantityTypeIdentifierWalkingSpeed'                     THEN 'walking_speed'
    WHEN 'HKQuantityTypeIdentifierWalkingStepLength'                THEN 'walking_step_length'
    WHEN 'HKCategoryTypeIdentifierAppleStandHour'                   THEN 'stand_hour'
    WHEN 'HKQuantityTypeIdentifierWalkingDoubleSupportPercentage'   THEN 'walking_double_support_percentage'
    WHEN 'HKQuantityTypeIdentifierHeadphoneAudioExposure'           THEN 'headphone_audio_exposure'
    WHEN 'HKQuantityTypeIdentifierEnvironmentalAudioExposure'       THEN 'environmental_audio_exposure'
    WHEN 'HKQuantityTypeIdentifierWalkingAsymmetryPercentage'       THEN 'walking_asymmetry_percentage'
    WHEN 'HKQuantityTypeIdentifierTimeInDaylight'                   THEN 'time_in_daylight'
    WHEN 'HKQuantityTypeIdentifierEnvironmentalSoundReduction'      THEN 'environmental_sound_reduction'
    WHEN 'HKQuantityTypeIdentifierStairDescentSpeed'                THEN 'stair_descent_speed'
    WHEN 'HKQuantityTypeIdentifierStairAscentSpeed'                 THEN 'stair_ascent_speed'
    WHEN 'HKCategoryTypeIdentifierHandwashingEvent'                 THEN 'handwashing_event'
    WHEN 'HKQuantityTypeIdentifierWalkingHeartRateAverage'          THEN 'walking_heart_rate_average'
    WHEN 'HKQuantityTypeIdentifierAppleWalkingSteadiness'           THEN 'walking_steadiness'
    WHEN 'HKQuantityTypeIdentifierSixMinuteWalkTestDistance'        THEN 'six_minute_walk_test_distance'
    WHEN 'HKCategoryTypeIdentifierAudioExposureEvent'               THEN 'audio_exposure_event'
    WHEN 'HKCategoryTypeIdentifierToothbrushingEvent'               THEN 'toothbrushing_event'
    WHEN 'HKQuantityTypeIdentifierAppleSleepingWristTemperature'    THEN 'sleeping_wrist_temperature'
    WHEN 'HKCategoryTypeIdentifierMindfulSession'                   THEN 'mindful_session'
    WHEN 'HKCategoryTypeIdentifierHighHeartRateEvent'               THEN 'high_heart_rate_event'
    WHEN 'HKDataTypeSleepDurationGoal'                              THEN 'sleep_duration_goal'
    WHEN 'HKCategoryTypeIdentifierHeadphoneAudioExposureEvent'      THEN 'headphone_audio_exposure_event'
    -- These two are the same measurement as something already in the archive.
    WHEN 'HKQuantityTypeIdentifierDietaryWater'                     THEN 'hydration'
    WHEN 'HKCategoryTypeIdentifierSexualActivity'                   THEN 'sexual_activity'
    ELSE metric_type END
WHERE metric_type LIKE 'HK%';

-- 2. Unit relabels. Apple's "Cal" is the kilocalorie, and bpm and breaths/min
--    are count/min under another name, so these carry no value change.
UPDATE health_observations_raw SET unit = 'kcal' WHERE unit = 'Cal';
UPDATE health_observations_raw SET unit = 'count/min' WHERE unit IN ('bpm', 'breaths/min');
UPDATE health_observations_raw SET unit = 'min'
 WHERE metric_type = 'exercise_session' AND unit IS NULL AND value_numeric IS NOT NULL;

-- 3. Real conversions to the canonical unit: metres, kilograms, metres/second,
--    degrees Celsius, litres.
UPDATE health_observations_raw SET value_numeric = value_numeric * 1609.344, unit = 'm'
 WHERE metric_type IN ('distance', 'distance_cycling') AND unit = 'mi';

UPDATE health_observations_raw SET value_numeric = value_numeric * 0.45359237, unit = 'kg'
 WHERE metric_type = 'weight' AND unit = 'lb';

UPDATE health_observations_raw SET value_numeric = value_numeric * 0.3048, unit = 'm'
 WHERE metric_type = 'height' AND unit = 'ft';

UPDATE health_observations_raw SET value_numeric = value_numeric * 0.44704, unit = 'm/s'
 WHERE metric_type = 'walking_speed' AND unit = 'mi/hr';

UPDATE health_observations_raw SET value_numeric = value_numeric * 0.3048, unit = 'm/s'
 WHERE metric_type IN ('stair_ascent_speed', 'stair_descent_speed') AND unit = 'ft/s';

UPDATE health_observations_raw SET value_numeric = value_numeric * 0.0254, unit = 'm'
 WHERE metric_type = 'walking_step_length' AND unit = 'in';

UPDATE health_observations_raw SET value_numeric = (value_numeric - 32) * 5.0 / 9.0, unit = 'degC'
 WHERE metric_type = 'sleeping_wrist_temperature' AND unit = 'degF';

UPDATE health_observations_raw SET value_numeric = value_numeric * 0.0295735295625, unit = 'L'
 WHERE metric_type = 'hydration' AND unit = 'fl_oz_us';

COMMIT;

-- Deliberately NOT normalised, because these are name collisions rather than
-- unit differences and merging them would corrupt the data:
--
--   activity_segment  google_fit stores an activity *type code* (value 7 =
--                     walking, unit NULL) while health_sync stores a *duration*
--                     in seconds. Same name, different quantity.
--   sleep_segment     stage codes, stage names in value_text, and one
--                     home_assistant row holding minutes.
--
-- Both need a semantic decision, not a conversion factor.
