-- Generated via ./bqetl generate glean_usage
CREATE OR REPLACE VIEW
    `{{ project_id }}.{{ target_view }}`
AS
{% for (dataset, channel) in datasets -%}
{% if not loop.first -%}
UNION ALL
{% endif -%}
{% if app_name == "fenix" -%}
SELECT * REPLACE(mozfun.norm.fenix_app_info("{{ dataset }}", app_build).channel AS normalized_channel)
{% else -%}
SELECT * REPLACE("{{ channel }}" AS normalized_channel)
{% endif -%}
FROM `{{ project_id }}.{{ dataset }}.{{ table }}`
{% endfor %}
