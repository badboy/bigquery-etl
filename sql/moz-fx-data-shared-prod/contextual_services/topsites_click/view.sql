-- Generated by bigquery_etl.view.generate_stable_views
CREATE OR REPLACE VIEW
  `moz-fx-data-shared-prod.contextual_services.topsites_click`
AS
SELECT
  * REPLACE (mozfun.norm.metadata(metadata) AS metadata)
FROM
  `moz-fx-data-shared-prod.contextual_services_stable.topsites_click_v1`
