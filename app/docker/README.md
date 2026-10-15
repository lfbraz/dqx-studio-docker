# Running DQX Studio in Docker

Runs DQX Studio (the React UI and the FastAPI backend) as a single container, on
a local Docker engine (Colima, Docker Desktop) or a cloud container platform.

> The container is not standalone: it uses a live Databricks workspace (SQL
> warehouse, Unity Catalog, and Lakebase) and authenticates as a service
> principal (SP).

## Prerequisites

- Docker. With Colima: `colima start --memory 6`.
- A SQL warehouse and a Lakebase project in the workspace. `setup.sh` creates
  everything else.
- A Databricks CLI profile for your own admin identity (`<your-profile>` below).
  If the catalog doesn't exist yet, it also needs `CREATE CATALOG` on the
  metastore.

## Set up

Run everything from `app/docker`, with your own profile.

1. **Create two service principals**, one for the app and one for the
   task-runner job:

   ```bash
   databricks service-principals create --display-name dqx-studio-local -p <your-profile> -o json
   databricks service-principals create --display-name dqx-studio-local-runner -p <your-profile> -o json
   ```

   They must be different: the task runner executes rule logic, so it gets fewer
   privileges than the app, and setup rejects a shared one.

2. **Create an OAuth secret for the app SP.** `<id>` is its numeric `id` from
   step 1, and the secret is shown only once. The task runner needs no secret.

   ```bash
   databricks service-principal-secrets-proxy create <id> -p <your-profile> -o json
   ```

3. **Fill in `.env`.** Copy the template, then set `DATABRICKS_HOST`,
   `DATABRICKS_CLIENT_ID` (the app SP's `applicationId`),
   `DATABRICKS_CLIENT_SECRET`, `DQX_TASK_RUNNER_CLIENT_ID` (the task-runner SP's
   `applicationId`), and your resources. The comments in the file explain each
   value. `.env` is git-ignored and never baked into the image.

   ```bash
   cp .env.example .env
   ```

4. **Create the resources and grant the permissions.** It also builds the image
   when it is missing. Preview first with `--dry-run`:

   ```bash
   ./setup.sh --profile <your-profile>
   ```

5. **Start**, then open <http://localhost:8000>. The setup wizard shows anything
   still missing.

   ```bash
   docker compose up
   ```

The script is safe to re-run, and it lists anything it couldn't do. It creates
whatever is missing among the catalog, schemas, and wheels volume (from
`DQX_WHEELS_VOLUME`), the Lakebase database (owned by the app SP), and the
task-runner job. It also applies the app's Lakebase migrations, so that it can
grant the task runner access to a table they create. Then it grants:

| Resource | App SP | Task-runner SP |
|---|---|---|
| Workspace | `workspace-access`, `databricks-sql-access` | — |
| SQL warehouse | `CAN_USE` | — |
| Catalog | `USE_CATALOG`, `CREATE_SCHEMA`, `READ_METADATA` (to verify the task runner's grants) | `USE_CATALOG` |
| Main schema | `ALL_PRIVILEGES` | `USE_SCHEMA`, `SELECT`, `MODIFY` |
| Tmp and genie schemas | `ALL_PRIVILEGES` | `USE_SCHEMA` on tmp |
| Wheels volume | `ALL_PRIVILEGES` | `READ_VOLUME` |
| Lakebase | Postgres role in `DATABRICKS_SUPERUSER` | Postgres role; `SELECT`, `DELETE` on `dq_run_configs` |
| Task-runner job | `CAN_MANAGE` | Run as |
| `DQX_ADMIN_GROUP` | Member (the group is created if missing) | — |

Setting the job's run-as requires the **Service principal: User** role on the
task-runner SP, so the script also gives that role to your own identity.

To browse or profile your own tables in the UI, also grant the app SP
`USE CATALOG`, `USE SCHEMA`, and `SELECT` on them.

## Authentication

The container runs **every request as the app SP**: `DQX_DEFAULT_AUTH_FALLBACK=1`
replaces the per-user login that Databricks Apps provides. That is fine on your
laptop, but anyone who can reach the port acts as a Studio admin.

Before exposing it beyond a trusted network, put an authenticating proxy in
front (e.g. oauth2-proxy with Databricks as the OIDC provider). The proxy must
set `X-Forwarded-Access-Token` and `X-Forwarded-Email` and strip any
client-supplied `X-Forwarded-*` headers. Then unset `DQX_DEFAULT_AUTH_FALLBACK`,
so user calls run as each signed-in user, as on Databricks Apps. Keep
`DATABRICKS_CLIENT_SECRET` in the platform's secret manager.

## Everyday use

- UI: <http://localhost:8000> · API docs: <http://localhost:8000/docs> · health:
  <http://localhost:8000/api/health>
- Logs: `docker compose logs -f` · stop: `docker compose down`
- `.env` changes need only `docker compose up`. Code changes need
  `docker compose up --build`; there is no hot reload (use `make app-start-dev`
  for that).

Without Compose (BuildKit required), from the repository root. The build args
are only needed behind a package-registry proxy:

```bash
docker build -f app/docker/Dockerfile -t dqx-studio:local \
  --build-arg UV_INDEX_URL="$UV_INDEX_URL" --build-arg NPM_REGISTRY="$NPM_REGISTRY" .
docker run --rm -p 8000:8000 --env-file app/docker/.env dqx-studio:local
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot configure default credentials` | `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, or `DATABRICKS_CLIENT_SECRET` is empty in `.env`. |
| `invalid_client` | Wrong client id or secret. Create a new secret (step 2). |
| UI stuck loading, API returns 401 | Add `DQX_DEFAULT_AUTH_FALLBACK=1` to `.env`. |
| `database "…" does not exist` | Run `setup.sh`: it creates `DQX_LAKEBASE_DATABASE_NAME`. |
| `must be owner of table …` | `DQX_LAKEBASE_SCHEMA` was created by another identity. Use the app SP's own schema (`dqx_studio_local`). |
| `task_runner_run_as_missing` | Set `DQX_TASK_RUNNER_CLIENT_ID`, re-run the script, and select **Verify again**. |
| Any other permission error, or you aren't an admin in the UI | Re-run the script and check its summary. |

## Notes

- **Task-runner wheels.** The image ships the task-runner and DQX wheels, built
  from this checkout. The app publishes them to the wheels volume on start.
- **Reusing a task-runner job** (e.g. one from `make app-deploy`): set
  `DQX_JOB_ID`, and set `DQX_TASK_RUNNER_CLIENT_ID` to that job's current run-as.
  Otherwise the script changes the run-as.
- **One worker on purpose**: the in-process scheduler takes a file lock. Set
  `DQX_SCHEDULER_DISABLED=1` to turn it off.
- **Apple Silicon** builds natively for `arm64`; no emulation needed.
