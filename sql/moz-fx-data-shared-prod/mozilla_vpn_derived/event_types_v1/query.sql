-- Generated by bigquery_etl/events_daily/generate_queries.py
SELECT
  * EXCEPT (submission_date)
FROM
  mozilla_vpn_derived.event_types_history_v1
WHERE
  submission_date = @submission_date
