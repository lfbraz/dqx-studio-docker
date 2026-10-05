# Running DQX Studio in Docker

This directory packages **DQX Studio** as a container image you can run on a
local Docker engine (Colima, Docker Desktop, etc.) and, later, on a cloud
container platform. It builds the exact source-shipped tree the Databricks Apps
runtime uses (`.build/`) and serves the compiled React SPA **and** the FastAPI
backend from a single uvicorn process.

> **Important — this is not a self-hosted / offline app.** DQX Studio is a
> Databricks App. The container still talks to a **live Databricks workspace**:
> a SQL warehouse, a Unity Catalog catalog + wheels volume, and a **mandatory
> Lakebase (Postgres) endpoint**. It authenticates as a **service principal**
> (OAuth M2M) whose credentials come from environment variables.

## Prerequisites

- A running Docker engine. With Colima: `colima start` (give it enough memory,
  e.g. `colima start --memory 6`).
- Network access from the container to your workspace (HTTPS) and to the
  Lakebase endpoint (Postgres/TLS).
- Existing Databricks resources: a **SQL warehouse**, a **Unity Catalog
  catalog** with the `dqx_studio`, `dqx_studio_tmp`, and `genie` schemas and a
  **wheels volume**, and a **Lakebase project endpoint**. The fastest way to get
  a matching set is to run `make app-deploy` once against a dev workspace. See
  [`../DEVELOPMENT.md`](../DEVELOPMENT.md#bring-your-own-sql-warehouse-catalog-and-lakebase).
- A CLI profile for **your own** admin-capable identity (`<your-profile>` below)
  to run the one-time service-principal setup.

## How authentication works

The container gets the SP's credentials from three environment variables —
`DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` — which the
Databricks SDK uses for OAuth M2M. Locally they come from `.env`; on a cloud
platform you inject them from its secret manager.

On Databricks Apps, each user request carries the signed-in user's token
(`X-Forwarded-Access-Token`), and the app rejects requests without it. A
standalone container has no such proxy, so set **`DQX_DEFAULT_AUTH_FALLBACK=1`**:
requests without the header then run as the SP. Without the flag, the UI never
loads and every API call returns `401`.

With the flag on, **every request runs as the SP** — both the app's service
operations and the user-facing calls — and there is **no per-user
authentication**: anyone who can reach the port acts as the SP (a Studio admin,
once step 5 is done). That is fine on your laptop; see
[Deploying to a cloud container](#deploying-to-a-cloud-container) before
exposing it anywhere else.

## Set up the service principal (one time)

Run these with your own profile. Replace `<…>` placeholders; values you need
from earlier steps are noted.

**1. Create the service principal.**

```bash
databricks service-principals create --display-name dqx-studio-local \
  -p <your-profile> -o json
```

Note two values from the output: **`id`** (numeric, `<sp-id>` below) and
**`applicationId`** (UUID, `<sp-app-id>` below).

**2. Create an OAuth secret** for it. The secret is shown only once.

```bash
databricks service-principal-secrets-proxy create <sp-id> -p <your-profile> -o json
```

**3. Put the credentials in `.env`** (see [Configure](#configure)):

```bash
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_CLIENT_ID=<sp-app-id>
DATABRICKS_CLIENT_SECRET=<secret from step 2>
```

**4. Fill in the rest of `.env`** — the resources and `DQX_ADMIN_GROUP` (see
[Configure](#configure)).

**5. Grant the SP its permissions** with `grant_sp_permissions.sh`. It reads the
SP and every resource from `.env` (never the secret) and runs as **your**
profile, because a service principal cannot grant itself access. Preview first,
then apply:

```bash
cd app/docker
./grant_sp_permissions.sh --profile <your-profile> --dry-run   # read-only lookups + planned commands
./grant_sp_permissions.sh --profile <your-profile>             # shows the plan, asks to confirm
```

It grants, mirroring what the bundle grants the deployed app's SP:

| Resource | Permission |
|---|---|
| Workspace | `workspace-access`, `databricks-sql-access` entitlements |
| SQL warehouse (`DATABRICKS_WAREHOUSE_ID`) | `CAN_USE` |
| Catalog of `DQX_WHEELS_VOLUME` | `USE_CATALOG`, `CREATE_SCHEMA` |
| Main, tmp, and genie schemas | `ALL_PRIVILEGES` on those that exist; the app creates (and owns) missing ones |
| Wheels volume | `ALL_PRIVILEGES` |
| Lakebase branch of `DQX_LAKEBASE_ENDPOINT` | Postgres role for the SP, member of `DATABRICKS_SUPERUSER` (lets the app create its Postgres schema) |
| `DQX_ADMIN_GROUP` | SP added as a member; the group is created if missing. Refuses `admins`, which would make the SP a workspace admin |
| `DQX_JOB_ID` (if set) | `CAN_MANAGE` |

Your profile needs the rights to grant these: `MANAGE` or ownership on the
catalog, schemas, and volume; `CAN_MANAGE` on the warehouse (and job); access to
the Lakebase project; and group management (workspace admin). The script stops
if your profile points at a different workspace than `DATABRICKS_HOST` or the SP
isn't found there. Every step is safe to re-run; failed steps are listed at the
end, and the exit status is non-zero.

To browse or profile your own data in the UI, also grant the SP `USE CATALOG`,
`USE SCHEMA`, and `SELECT` on those catalogs/schemas/tables.

## Configure

```bash
cd app/docker
cp .env.example .env
```

Edit `.env` (git-ignored, and excluded from the image build context, so the
secret is never baked into the image):

- `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` — from
  steps 1–3.
- `DQX_DEFAULT_AUTH_FALLBACK=1` — keep it (see
  [How authentication works](#how-authentication-works)).
- `DATABRICKS_WAREHOUSE_ID`, `DQX_CATALOG`, the schema names, `DQX_WHEELS_VOLUME`,
  and `DQX_LAKEBASE_ENDPOINT` — your existing resources.
- `DQX_LAKEBASE_SCHEMA` — keep `dqx_studio_local` (the default here) when the
  Lakebase project is shared with a deployed app. Its `dqx_studio` tables are
  owned by the app's own SP, so migrations run as this SP would fail with
  `must be owner of table`.
- `DQX_ADMIN_GROUP` — a dedicated group for Studio admins (e.g. `dqx-studio-local-admins`); `grant_sp_permissions.sh` creates it and adds the SP.

Check the credentials before starting the app (uses the same env as the app):

```bash
docker compose run --rm dqx-studio python -c \
  "from databricks.sdk import WorkspaceClient; print(WorkspaceClient().current_user.me().user_name)"
```

It should print the SP's application id.

## Build & run

```bash
cd app/docker
docker compose up --build          # first build takes a few minutes
```

Then open **http://localhost:8000**.

- UI: `http://localhost:8000`
- API: `http://localhost:8000/api/v1/*`
- Swagger: `http://localhost:8000/docs`
- Liveness: `http://localhost:8000/api/health`

`.env` is read when the container starts, so changing it only needs
`docker compose up` (no rebuild). Stop with `Ctrl+C`, or from another shell:

```bash
docker compose -f app/docker/docker-compose.yml down
```

### Without Compose

Standalone `docker build` needs BuildKit (the `docker-buildx` plugin); without
it, the legacy builder ignores `Dockerfile.dockerignore` and sends the whole
repository as build context. Compose uses BuildKit out of the box.

```bash
# from the repository root (the build context MUST be the repo root)
docker build -f app/docker/Dockerfile -t dqx-studio:local \
  --build-arg UV_INDEX_URL="$UV_INDEX_URL" \
  --build-arg NPM_REGISTRY="$(npm config get registry)" .

docker run --rm -p 8000:8000 --env-file app/docker/.env dqx-studio:local
```

## Deploying to a cloud container

The image is configured purely through environment variables, so it runs
unchanged on any container platform. Pass the `.env` variables through the
platform's configuration (build-time proxy variables aren't needed at runtime),
and keep `DATABRICKS_CLIENT_SECRET` in its secret manager.

Before exposing the container beyond a trusted network, replace the
single-identity mode with real user authentication:

1. Put an **authenticating reverse proxy** in front (for example oauth2-proxy
   with Databricks as the OIDC provider) that signs users in and forwards their
   Databricks access token as `X-Forwarded-Access-Token` and their email as
   `X-Forwarded-Email` — the same headers Databricks Apps injects.
2. Have the proxy **strip any client-supplied `X-Forwarded-*` headers**; the app
   trusts `X-Forwarded-Email` as given.
3. **Unset `DQX_DEFAULT_AUTH_FALLBACK`.** The SP credentials still drive the
   app's service operations, while user-facing calls run as each signed-in user
   (OBO), so Unity Catalog permissions apply per user, as on Databricks Apps.

## What the image does

- **Builder stage** (`python:3.12` + Node 22 + yarn + uv): installs JS deps and
  runs `scripts/build_app.py` — the same steps as `make app-build` (OpenAPI dump
  → orval → `vite build` → assemble `.build/` → vendor `databricks-labs-dqx`).
  It then resolves the locked Python environment into `/app/.venv`.
- **Runtime stage** (`python:3.12-slim`): carries only the assembled `/app`
  tree and its pre-built venv, and launches
  `uvicorn databricks_labs_dqx_app.backend.app:app` (single worker) on port 8000.

Because the build context is the repository root, `Dockerfile.dockerignore`
excludes `.git`, `docs/`, `node_modules/`, `.venv/`, prior `.build/` output,
and `.env` files, so only what the image needs is sent.

## First-start behavior

On startup the app connects to Lakebase, runs its Delta + Lakebase migrations,
and (best-effort) uploads wheels and applies grants — all as the SP. If a
required resource is missing or unreachable, the app still boots and serves the
**setup wizard** instead of crash-looping; the wizard tells you what to fix.
Watch the logs:

```bash
docker compose logs -f
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `default auth: cannot configure default credentials` (logged under "Lakebase connection initialization failed") | `DATABRICKS_HOST` / `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` are missing or empty in `.env`. |
| `invalid_client: Client authentication failed` | Wrong client id or secret, or the secret was deleted. Create a new one (step 2). |
| UI stuck loading; API returns 401 "Authentication required" | `DQX_DEFAULT_AUTH_FALLBACK=1` is missing from `.env`. |
| `must be owner of table …` during startup migrations | `DQX_LAKEBASE_SCHEMA` points at a schema another identity created. Use the SP's own schema (`dqx_studio_local`). |
| `PERMISSION_DENIED` / setup wizard flags a resource | A grant is missing for the SP. Re-run `grant_sp_permissions.sh` (step 5) and check its summary for failed steps. |
| You are not an admin in the UI | The SP isn't in `DQX_ADMIN_GROUP`. Re-run `grant_sp_permissions.sh` (step 5). |

## Notes & limitations

- **One identity** (with `DQX_DEFAULT_AUTH_FALLBACK=1`). Every request runs as
  the SP, so you can't test per-user permission differences.
- **Profiler / dry-run / scheduled runs** submit a Databricks *task-runner job*.
  Set `DQX_JOB_ID` in `.env` (and ensure the wheels volume is populated) to use
  them; the SP also needs `CAN_MANAGE` on that job. Leave it unset to run the
  rest of the app. The image does not build or ship the task-runner wheel.
- **Single worker** is intentional — the in-process scheduler uses an exclusive
  file lock, so only one worker may drive it. Set `DQX_SCHEDULER_DISABLED=1` in
  `.env` to skip the scheduler locally.
- **Rebuild after code changes** with `docker compose up --build` (there is no
  hot reload in the container; for the fast HMR inner loop use
  `make app-start-dev` instead).
- **Apple Silicon**: the image builds natively for `arm64` under Colima. No
  emulation needed.
