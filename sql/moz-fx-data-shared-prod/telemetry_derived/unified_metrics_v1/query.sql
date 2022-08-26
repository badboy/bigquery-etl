WITH ios_is_default_browser AS (
SELECT client_info.client_id AS client_id,
          DATE(submission_timestamp) AS submission_date,
          SUM(COALESCE(metrics.counter.app_opened_as_default_browser, 0)) > 0 AS is_default_browser,

   FROM org_mozilla_ios_firefox.metrics m
   WHERE DATE(submission_timestamp) >= DATE(2021, 1, 1)
     AND CAST(REGEXP_EXTRACT(client_info.app_display_version, r'^([0-9]+\.[0-9]+)') AS float64) >= 29.2 -- ability to set default browser started in iOS 14
     AND CAST(REGEXP_EXTRACT(client_info.os_version, r'^([0-9]+\.[0-9]+)') AS float64) >= 14.0
     AND sample_id < 20
   GROUP BY 1,
            2
 )
,
unioned_source AS (
  SELECT
    submission_date,
    normalized_channel,
    client_id,
    sample_id,
    days_since_seen,
    days_seen_bits,
    days_created_profile_bits,
    durations,
    normalized_os,
    normalized_os_version,
    locale,
    city,
    country,
    app_display_version,
    device_model,
    first_seen_date,
    submission_date = first_seen_date AS is_new_profile,
    uri_count,
    is_default_browser,
    CAST(NULL AS string) AS distribution_id,
    isp,
    'Fenix' AS normalized_app_name
  FROM
    fenix.clients_last_seen_joined
  WHERE
    submission_date = @submission_date
  UNION ALL
SELECT
    clsj.submission_date,
    clsj.normalized_channel,
    clsj.client_id,
    clsj.sample_id,
    clsj.days_since_seen,
    clsj.days_seen_bits,
    clsj.days_created_profile_bits,
    clsj.durations,
    clsj.normalized_os,
    clsj.normalized_os_version,
    clsj.locale,
    clsj.city,
    clsj.country,
    clsj.app_display_version,
    clsj.device_model,
    clsj.first_seen_date,
    clsj.submission_date = first_seen_date AS is_new_profile,
    clsj.uri_count,
    ios_db.is_default_browser,
    CAST(NULL AS string) AS distribution_id,
    clsj.isp,
    'Firefox iOS' AS normalized_app_name
  FROM
    firefox_ios.clients_last_seen_joined clsj
  LEFT JOIN
    ios_is_default_browser ios_db
    ON ios_db.client_id = clsj.client_id
    AND ios_db.submission_date = clsj.submission_date
  WHERE
    clsj.submission_date = @submission_date
   -- AND ios_db.is_default_browser is not null  -- Prior to v. 14, we couldn't identify if default browser was set to default, so we will get nulls
  UNION ALL
  SELECT
    submission_date,
    normalized_channel,
    client_id,
    sample_id,
    days_since_seen,
    days_seen_bits,
    days_created_profile_bits,
    durations,
    normalized_os,
    normalized_os_version,
    locale,
    city,
    country,
    app_display_version,
    device_model,
    first_seen_date,
    submission_date = first_seen_date AS is_new_profile,
    uri_count,
    is_default_browser,
    CAST(NULL AS string) AS distribution_id,
    isp,
    'Focus iOS' AS normalized_app_name
  FROM
    focus_ios.clients_last_seen_joined
  WHERE
    submission_date = @submission_date
  UNION ALL
  SELECT
    submission_date,
    normalized_channel,
    client_id,
    udf_js.sample_id(client_id) AS sample_id,
    days_since_seen,
    days_seen_bits,
    days_created_profile_bits,
    durations,
    os AS normalized_os,
    osversion AS normalized_os_version,
    locale,
    city,
    country,
    metadata_app_version AS app_display_version,
    device AS device_model,
    first_seen_date,
    submission_date = first_seen_date AS is_new_profile,
    NULL AS uri_count,
    default_browser AS is_default_browser,
    distribution_id,
    CAST(NULL AS string) AS isp,
    'Focus Android' AS normalized_app_name
  FROM
    telemetry.core_clients_last_seen
  WHERE
    submission_date = @submission_date
    AND app_name = 'Focus'
    AND os = 'Android'
),
unioned AS (
  SELECT
    * EXCEPT (isp) REPLACE(
      -- Per bug 1757216 we need to exclude BrowserStack clients from KPIs,
      -- so we mark them with a separate app name here. We expect BrowserStack
      -- clients only on release channel of Fenix, so the only variant this is
      -- expected to produce is 'Fenix BrowserStack'
      IF(
        isp = 'BrowserStack',
        CONCAT(normalized_app_name, ' BrowserStack'),
        normalized_app_name
      ) AS normalized_app_name
    )
  FROM
    unioned_source
),
search_clients AS (
  SELECT
    client_id,
    submission_date,
    ad_click,
    organic,
    search_count,
    search_with_ads
  FROM
    search_derived.mobile_search_clients_daily_v1
  WHERE
    submission_date = @submission_date
),
search_metrics AS (
  SELECT
    unioned.client_id,
    unioned.submission_date,
        -- the table is more than one row per client (one row per engine, looks like), so we have to aggregate.
    SUM(ad_click) AS ad_click,
    SUM(organic) AS organic_search_count,
    SUM(search_count) AS search_count,
    SUM(search_with_ads) AS search_with_ads,
  FROM
    unioned
  LEFT JOIN
    search_clients s
  ON
    unioned.client_id = s.client_id
    AND unioned.submission_date = s.submission_date
  GROUP BY
    client_id,
    submission_date
),
mobile_with_searches AS (
  SELECT
    unioned.client_id,
    unioned.sample_id,
    CASE
    WHEN
      BIT_COUNT(days_seen_bits)
      BETWEEN 1
      AND 6
    THEN
      'infrequent_user'
    WHEN
      BIT_COUNT(days_seen_bits)
      BETWEEN 7
      AND 13
    THEN
      'casual_user'
    WHEN
      BIT_COUNT(days_seen_bits)
      BETWEEN 14
      AND 20
    THEN
      'regular_user'
    WHEN
      BIT_COUNT(days_seen_bits) >= 21
    THEN
      'core_user'
    ELSE
      'other'
    END
    AS activity_segment,
    unioned.normalized_app_name,
    unioned.app_display_version AS app_version,
    unioned.normalized_channel,
    IFNULL(country, '??') country,
    unioned.city,
    unioned.days_seen_bits,
    unioned.days_created_profile_bits,
    DATE_DIFF(unioned.submission_date, unioned.first_seen_date, DAY) AS days_since_first_seen,
    unioned.device_model,
    unioned.is_new_profile,
    unioned.locale,
    unioned.first_seen_date,
    unioned.days_since_seen,
    unioned.normalized_os,
    unioned.normalized_os_version,
    COALESCE(
      SAFE_CAST(NULLIF(SPLIT(unioned.normalized_os_version, ".")[SAFE_OFFSET(0)], "") AS INTEGER),
      0
    ) AS os_version_major,
    COALESCE(
      SAFE_CAST(NULLIF(SPLIT(unioned.normalized_os_version, ".")[SAFE_OFFSET(1)], "") AS INTEGER),
      0
    ) AS os_version_minor,
    COALESCE(
      SAFE_CAST(NULLIF(SPLIT(unioned.normalized_os_version, ".")[SAFE_OFFSET(2)], "") AS INTEGER),
      0
    ) AS os_version_patch,
    unioned.durations,
    unioned.submission_date,
    unioned.uri_count,
    unioned.is_default_browser,
    unioned.distribution_id,
    CAST(NULL AS string) AS attribution_content,
    CAST(NULL AS string) AS attribution_source,
    CAST(NULL AS string) AS attribution_medium,
    CAST(NULL AS string) AS attribution_campaign,
    CAST(NULL AS string) AS attribution_experiment,
    CAST(NULL AS string) AS attribution_variation,
    search.ad_click,
    search.organic_search_count,
    search.search_count,
    search.search_with_ads,
    NULL AS active_hours_sum
  FROM
    unioned
  LEFT JOIN
    search_metrics search
  ON
    search.client_id = unioned.client_id
    AND search.submission_date = unioned.submission_date
),
desktop AS (
  SELECT
    client_id,
    sample_id,
    activity_segments_v1 AS activity_segment,
    'Firefox Desktop' AS normalized_app_name,
    app_version AS app_version,
    normalized_channel,
    IFNULL(country, '??') country,
    city,
    days_visited_1_uri_bits AS days_seen_bits,
    days_created_profile_bits,
    days_since_first_seen,
    CAST(NULL AS string) AS device_model,
    submission_date = first_seen_date AS is_new_profile,
    locale,
    first_seen_date,
    days_since_seen,
    os AS normalized_os,
    normalized_os_version,
    COALESCE(
      CAST(NULLIF(SPLIT(normalized_os_version, ".")[SAFE_OFFSET(0)], "") AS INTEGER),
      0
    ) AS os_version_major,
    COALESCE(
      CAST(NULLIF(SPLIT(normalized_os_version, ".")[SAFE_OFFSET(1)], "") AS INTEGER),
      0
    ) AS os_version_minor,
    COALESCE(
      CAST(NULLIF(SPLIT(normalized_os_version, ".")[SAFE_OFFSET(2)], "") AS INTEGER),
      0
    ) AS os_version_patch,
    subsession_hours_sum AS durations,
    submission_date,
    COALESCE(
      scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum,
      scalar_parent_browser_engagement_total_uri_count_sum
    ) AS uri_count,
    is_default_browser,
    distribution_id,
    attribution.content AS attribution_content,
    attribution.source AS attribution_source,
    attribution.medium AS attribution_medium,
    attribution.campaign AS attribution_campaign,
    attribution.experiment AS attribution_experiment,
    attribution.variation AS attribution_variation,
    ad_clicks_count_all AS ad_clicks,
    search_count_organic AS organic_search_count,
    search_count_all AS search_count,
    search_with_ads_count_all AS search_with_ads,
    active_hours_sum
  FROM
    telemetry.clients_last_seen
  WHERE
    submission_date = @submission_date
)

SELECT
  *
FROM
  mobile_with_searches
UNION ALL
SELECT
  *
FROM
  desktop