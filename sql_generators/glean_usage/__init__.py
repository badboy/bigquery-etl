"""GLEAN Usage."""
from functools import partial
from pathlib import Path

import click
from pathos.multiprocessing import ProcessingPool

from bigquery_etl.cli.utils import is_valid_project, table_matches_patterns
from sql_generators.glean_usage import (
    baseline_clients_daily,
    baseline_clients_first_seen,
    baseline_clients_last_seen,
    clients_last_seen_joined,
    events_unnested,
    glean_app_ping_views,
    metrics_clients_daily,
    metrics_clients_last_seen,
)
from sql_generators.glean_usage.common import get_app_info, list_baseline_tables

# list of methods for generating queries
GLEAN_TABLES = [
    glean_app_ping_views.GleanAppPingViews(),
    baseline_clients_daily.BaselineClientsDailyTable(),
    baseline_clients_first_seen.BaselineClientsFirstSeenTable(),
    baseline_clients_last_seen.BaselineClientsLastSeenTable(),
    events_unnested.EventsUnnestedTable(),
    metrics_clients_daily.MetricsClientsDaily(),
    metrics_clients_last_seen.MetricsClientsLastSeen(),
    clients_last_seen_joined.ClientsLastSeenJoined(),
]

# * mlhackweek_search was an experiment that we don't want to generate tables
# for
# * regrets_reporter currently refers to two applications, skip the glean
# one to avoid confusion: https://github.com/mozilla/bigquery-etl/issues/2499
SKIP_APPS = ["mlhackweek_search", "regrets_reporter"]

# List of glean apps tables should be generated for.
# New Glean apps needs to be added to the list and tables
# need to be generated and deployed manually.
ALLOWED_APPS = [
    "firefox_desktop",
    "firefox_desktop_background_update",
    "pine",
    "fenix",
    "firefox_ios",
    "reference_browser",
    "firefox_fire_tv",
    "firefox_reality",
    "lockwise_android",
    "lockwise_ios",
    "mozregression",
    "burnham",
    "mozphab",
    "firefox_echo_show",
    "firefox_reality_pc",
    "mach",
    "focus_ios",
    "klar_ios",
    "focus_android",
    "klar_android",
    "bergamot",
    "firefox_translations",
    "mozilla_vpn",
    "mozilla_vpn_android",
    "glean_dictionary",
    "bedrock",
    "mozilla_lockbox",
    "mozilla_mach",
    "org_mozilla_connect_firefox",
    "org_mozilla_fenix_nightly",
    "org_mozilla_fenix",
    "org_mozilla_fennec_aurora",
    "org_mozilla_firefox_beta",
    "org_mozilla_firefox_vpn",
    "org_mozilla_firefox",
    "org_mozilla_firefoxreality",
    "org_mozilla_focus_beta",
    "org_mozilla_focus_nightly",
    "org_mozilla_focus",
    "org_mozilla_ios_fennec",
    "org_mozilla_ios_firefox",
    "org_mozilla_ios_firefoxbeta",
    "org_mozilla_ios_focus",
    "org_mozilla_ios_klar",
    "org_mozilla_ios_lockbox",
    "org_mozilla_klar",
    "org_mozilla_mozregression",
    "org_mozilla_reference_browser",
    "org_mozilla_tv_firefox",
    "org_mozilla_vrbrowser",
]


@click.command()
@click.option(
    "--target-project",
    "--target_project",
    help="GCP project ID",
    default="moz-fx-data-shared-prod",
    callback=is_valid_project,
)
@click.option(
    "--output-dir",
    "--output_dir",
    help="Output directory generated SQL is written to",
    type=click.Path(file_okay=False),
    default="sql",
)
@click.option(
    "--parallelism",
    "-p",
    help="Maximum number of tasks to execute concurrently",
    default=8,
)
@click.option(
    "--except",
    "-x",
    "exclude",
    help="Process all tables except for the given tables",
)
@click.option(
    "--only",
    "-o",
    help="Process only the given tables",
)
@click.option(
    "--app_name",
    "--app-name",
    help="App to generate per-app dataset metadata and union views for.",
)
def generate(target_project, output_dir, parallelism, exclude, only, app_name):
    """Generate per-app_id queries and views, and per-app dataset metadata and union views.

    Note that a file won't be generated if a corresponding file is already present
    in the target directory, which allows manual overrides of generated files by
    checking them into the sql/ tree of the default branch of the repository.
    """
    table_filter = partial(table_matches_patterns, "*", False)

    if only:
        table_filter = partial(table_matches_patterns, only, False)
    elif exclude:
        table_filter = partial(table_matches_patterns, exclude, True)

    baseline_tables = list_baseline_tables(
        project_id=target_project,
        only_tables=[only] if only else None,
        table_filter=table_filter,
    )

    # filter out skipped apps
    baseline_tables = [
        baseline_table
        for baseline_table in baseline_tables
        if baseline_table.split(".")[1]
        not in [f"{skipped_app}_stable" for skipped_app in SKIP_APPS]
    ]

    output_dir = Path(output_dir) / target_project

    # per app specific datasets
    app_info = get_app_info()
    if app_name:
        app_info = {name: info for name, info in app_info.items() if name == app_name}

    app_info = [info for name, info in app_info.items() if name in ALLOWED_APPS]

    # Prepare parameters so that generation of all Glean datasets can be done in parallel

    # Parameters to generate per-app_id datasets consist of the function to be called
    # and baseline tables
    generate_per_app_id = [
        (
            partial(
                table.generate_per_app_id,
                target_project,
                output_dir=output_dir,
            ),
            baseline_table,
        )
        for baseline_table in baseline_tables
        for table in GLEAN_TABLES
    ]

    # Parameters to generate per-app datasets consist of the function to be called
    # and app_info
    generate_per_app = [
        (
            partial(table.generate_per_app, target_project, output_dir=output_dir),
            info,
        )
        for info in app_info
        for table in GLEAN_TABLES
    ]

    with ProcessingPool(parallelism) as pool:
        pool.map(lambda f: f[0](f[1]), generate_per_app_id + generate_per_app)
