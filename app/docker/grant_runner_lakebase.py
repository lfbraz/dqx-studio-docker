"""Grant the task-runner service principal its Lakebase access, as the app SP.

setup.sh pipes this file into a one-off app container
(docker compose run -T dqx-studio python -): the app SP owns the Lakebase
schema and its tables, so only it can grant on them, and the container already
holds its credentials. It first applies the app's Postgres migrations, which
the app also runs at startup and which are idempotent, so dq_run_configs exists
before the app's first start. Then it grants the Postgres role named by
DQX_TASK_RUNNER_CLIENT_ID CONNECT on the database, USAGE on the schema, and
SELECT + DELETE on dq_run_configs, and verifies them.

Exit status: 0 when granted, 1 on any failure.
"""

import os
import re
import sys

from databricks.sdk import WorkspaceClient

from databricks_labs_dqx_app.backend.config import conf
from databricks_labs_dqx_app.backend.migrations.postgres import PgMigrationRunner
from databricks_labs_dqx_app.backend.pg_executor import build_pg_executor_from_connection
from databricks_labs_dqx_app.backend.setup.resources import resolve_lakebase_connection
from databricks_labs_dqx_app.backend.sql_utils import escape_sql_string

_APPLICATION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def main() -> int:
    runner = os.environ.get("DQX_TASK_RUNNER_CLIENT_ID", "")
    if not _APPLICATION_ID.fullmatch(runner):
        print("DQX_TASK_RUNNER_CLIENT_ID must be a lowercase application id (UUID)", file=sys.stderr)
        return 1
    connection = resolve_lakebase_connection(conf, os.environ)
    if connection is None:
        print("no Lakebase connection is configured", file=sys.stderr)
        return 1

    pg = build_pg_executor_from_connection(WorkspaceClient(), connection)
    try:
        PgMigrationRunner(pg).run_all()

        table = f"{pg.q(connection.schema)}.{pg.q('dq_run_configs')}"
        role = pg.q(runner)
        pg.execute(f"GRANT CONNECT ON DATABASE {pg.q(connection.database)} TO {role}")
        pg.execute(f"GRANT USAGE ON SCHEMA {pg.q(connection.schema)} TO {role}")
        pg.execute(f"GRANT SELECT, DELETE ON TABLE {table} TO {role}")

        # GRANT only warns when the grantor lacks the grant option, so check the outcome.
        name = escape_sql_string(runner)
        schema = escape_sql_string(connection.schema)
        qualified = escape_sql_string(table)
        checks = {
            "CONNECT": f"has_database_privilege('{name}', current_database(), 'CONNECT')",
            "USAGE": f"has_schema_privilege('{name}', '{schema}', 'USAGE')",
            "SELECT": f"has_table_privilege('{name}', '{qualified}', 'SELECT')",
            "DELETE": f"has_table_privilege('{name}', '{qualified}', 'DELETE')",
        }
        row = pg.query("SELECT " + ", ".join(f"({check})::text" for check in checks.values()))[0]
        missing = [privilege for privilege, held in zip(checks, row) if held != "true"]
        if missing:
            print(f"the task-runner role still lacks: {', '.join(missing)}", file=sys.stderr)
            return 1
        return 0
    finally:
        pg.close()


if __name__ == "__main__":
    sys.exit(main())
