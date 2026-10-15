#!/usr/bin/env bash
#
# Set up the workspace for DQX Studio in this container (see README.md "Set up"),
# from the values in .env:
#   - create the catalog, schemas, and wheels volume, and the Lakebase database,
#     when they don't exist yet;
#   - grant the app service principal (DATABRICKS_CLIENT_ID) its permissions;
#   - with DQX_TASK_RUNNER_CLIENT_ID set, set up the task-runner job and service
#     principal. Its Lakebase grants run as the app SP — the owner of the
#     Lakebase schema — through grant_runner_lakebase.py in a one-off app
#     container, which holds the SP's credentials and first applies the app's
#     migrations.
#
# Run it once before the app's first start; setup then completes on that start.
#
# Run it as YOUR OWN admin-capable identity: a service principal cannot grant
# itself access. The SQL warehouse and the Lakebase project must already exist.
# The client secret is never read.
#
# Every step is idempotent, so re-running is safe. A failed step is reported and
# the remaining steps still run; the exit status is non-zero if any step failed.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
PROFILE=""
DRY_RUN=0
ASSUME_YES=0
SCIM_PATCH_OP="urn:ietf:params:scim:api:messages:2.0:PatchOp"
FAILURES=()
WARNINGS=()

usage() {
  cat <<'EOF'
Usage: setup.sh --profile <admin-profile> [--env-file <path>] [--dry-run] [--yes]

Creates, when missing (the SQL warehouse and the Lakebase project must exist):
  - the catalog, main schema, and wheels volume of DQX_WHEELS_VOLUME
    (DQX_CATALOG_STORAGE_ROOT sets the catalog's storage root, when needed)
  - the tmp and genie schemas
  - the Lakebase database DQX_LAKEBASE_DATABASE_NAME, owned by the app SP

Grants the app service principal (DATABRICKS_CLIENT_ID):
  - workspace-access + databricks-sql-access entitlements
  - CAN_USE on the SQL warehouse (DATABRICKS_WAREHOUSE_ID)
  - USE_CATALOG + CREATE_SCHEMA + READ_METADATA on the catalog (READ_METADATA
    lets setup verify the task runner's grants)
  - ALL_PRIVILEGES on the main, tmp, and genie schemas and the wheels volume
  - a Lakebase Postgres role (DATABRICKS_SUPERUSER member) on the
    DQX_LAKEBASE_ENDPOINT branch
  - membership in DQX_ADMIN_GROUP (created if missing; never "admins")
  - CAN_MANAGE on DQX_JOB_ID, when set

And, when DQX_TASK_RUNNER_CLIENT_ID is set, the task-runner service principal:
  - the run-as of the task-runner job: DQX_JOB_ID, or this app's job, which is
    created (with CAN_MANAGE for the app SP) when missing. Setting it gives
    your profile's identity the Service principal: User role on the
    task-runner SP, which the run-as requires
  - USE_CATALOG; USE_SCHEMA + SELECT + MODIFY on the main schema; USE_SCHEMA on
    the tmp schema; READ_VOLUME on the wheels volume
  - a Lakebase OAuth role (never DATABRICKS_SUPERUSER) with CONNECT, USAGE, and
    SELECT + DELETE on dq_run_configs, granted as the app SP after applying the
    app's migrations (builds the dqx-studio:local image when missing)

Options:
  -p, --profile   CLI profile for the DATABRICKS_HOST workspace, run as an identity
                  that can create and grant on these resources (required)
      --env-file  configuration to read (default: .env next to this script)
      --dry-run   run read-only lookups and print the changes without applying them
  -y, --yes       apply without the confirmation prompt
  -h, --help      show this help
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n▶ %s\n' "$*"
}

note() {
  printf '  • %s\n' "$*"
}

warn() {
  printf '  ! %s\n' "$*"
  WARNINGS+=("$*")
}

# Return the value of KEY from the env file (last occurrence wins), with
# surrounding whitespace and one layer of matching quotes removed. The file is
# parsed, never sourced, so its content cannot execute.
env_value() {
  local key=$1 line value
  line=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n 1 || true)
  value=${line#*=}
  value=$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ $value =~ ^\"(.*)\"$ ]] || [[ $value =~ ^\'(.*)\'$ ]]; then
    value=${BASH_REMATCH[1]}
  fi
  printf '%s' "$value"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_host() {
  lowercase "$1" | sed -E 's:/+$::'
}

require_identifier() {
  local label=$1 value=$2
  [[ $value =~ ^[A-Za-z0-9_-]+$ ]] || die "$label '$value' must contain only letters, digits, '_' or '-'"
}

# Read-only CLI call returning JSON; runs under --dry-run too.
lookup() {
  databricks "$@" --profile "$PROFILE" -o json 2>/dev/null
}

# Mutating CLI call; printed instead of executed under --dry-run.
apply() {
  local description=$1 output
  shift
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n     ' "$description"
    printf ' %q' databricks "$@" --profile "$PROFILE"
    printf '\n'
    return 0
  fi
  if output=$(databricks "$@" --profile "$PROFILE" 2>&1); then
    printf '  ✓ %s\n' "$description"
  else
    printf '  ✗ %s\n' "$description"
    printf '%s\n' "$output" | head -n 5 | sed 's/^/      /'
    FAILURES+=("$description")
  fi
}

# {"changes":[{"principal":<principal>,"add":[<privileges...>]}]} for "grants update".
grant_json() {
  local principal=$1
  shift
  jq -nc --arg principal "$principal" '{changes: [{principal: $principal, add: $ARGS.positional}]}' --args "$@"
}

# {"access_control_list":[...]} for warehouse / job "update-permissions".
acl_json() {
  jq -nc --arg sp "$SP_APP_ID" --arg level "$1" \
    '{access_control_list: [{service_principal_name: $sp, permission_level: $level}]}'
}

# SCIM list responses: a bare array, or an object with "Resources".
scim_items='if type == "array" then . else (.Resources // []) end'

# FIELD of the service principal with application id APP_ID in a SCIM list response.
sp_field() {
  local json=$1 app_id=$2 field=$3
  jq -r --arg id "$app_id" --arg field "$field" \
    "$scim_items"' | map(select((.applicationId // "" | ascii_downcase) == $id)) | .[0][$field] // empty' <<<"$json"
}

application_id_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# --- Arguments --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    -p | --profile)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      PROFILE=$2
      shift 2
      ;;
    --env-file)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      ENV_FILE=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -y | --yes)
      ASSUME_YES=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n $PROFILE ]] || {
  usage >&2
  die "--profile is required (your own admin profile, not the service principal)"
}
[[ -f $ENV_FILE ]] || die "env file not found: $ENV_FILE"
command -v databricks >/dev/null || die "the Databricks CLI is not installed"
command -v jq >/dev/null || die "jq is not installed"

# --- Configuration from .env -------------------------------------------------

HOST=$(env_value DATABRICKS_HOST)
SP_APP_ID=$(lowercase "$(env_value DATABRICKS_CLIENT_ID)")
WAREHOUSE_ID=$(env_value DATABRICKS_WAREHOUSE_ID)
VOLUME_PATH=$(env_value DQX_WHEELS_VOLUME)
CONF_CATALOG=$(env_value DQX_CATALOG)
CONF_SCHEMA=$(env_value DQX_SCHEMA)
STORAGE_ROOT=$(env_value DQX_CATALOG_STORAGE_ROOT)
TMP_SCHEMA=$(env_value DQX_TMP_SCHEMA)
GENIE_SCHEMA=$(env_value DQX_GENIE_SCHEMA)
LAKEBASE_ENDPOINT=$(env_value DQX_LAKEBASE_ENDPOINT)
# Same defaults as AppConfig.
LAKEBASE_DATABASE=$(env_value DQX_LAKEBASE_DATABASE_NAME)
LAKEBASE_DATABASE=${LAKEBASE_DATABASE:-databricks_postgres}
LAKEBASE_SCHEMA=$(env_value DQX_LAKEBASE_SCHEMA)
LAKEBASE_SCHEMA=${LAKEBASE_SCHEMA:-dqx_studio}
ADMIN_GROUP=$(env_value DQX_ADMIN_GROUP)
ADMIN_GROUP=${ADMIN_GROUP:-admins}
JOB_ID=$(env_value DQX_JOB_ID)
RUNNER_APP_ID=$(lowercase "$(env_value DQX_TASK_RUNNER_CLIENT_ID)")

[[ $HOST =~ ^https:// ]] || die "DATABRICKS_HOST must be set to the workspace URL (https://...) in $ENV_FILE"
[[ $SP_APP_ID =~ $application_id_re ]] ||
  die "DATABRICKS_CLIENT_ID must be the service principal's application id (a UUID) in $ENV_FILE"
[[ $WAREHOUSE_ID =~ ^[A-Za-z0-9]+$ ]] || die "DATABRICKS_WAREHOUSE_ID must be set to a warehouse id in $ENV_FILE"

# The app derives its catalog and main schema from the volume path, so do we.
[[ $VOLUME_PATH =~ ^/Volumes/([^/]+)/([^/]+)/([^/]+)/?$ ]] ||
  die "DQX_WHEELS_VOLUME must look like /Volumes/<catalog>/<schema>/<volume> in $ENV_FILE"
CATALOG=${BASH_REMATCH[1]}
MAIN_SCHEMA=${BASH_REMATCH[2]}
VOLUME_NAME=${BASH_REMATCH[3]}
# Same defaults as AppConfig: sibling schemas are named after the volume's schema.
TMP_SCHEMA=${TMP_SCHEMA:-${MAIN_SCHEMA}_tmp}
GENIE_SCHEMA=${GENIE_SCHEMA:-${MAIN_SCHEMA}_genie}
for pair in "catalog:$CATALOG" "schema:$MAIN_SCHEMA" "volume:$VOLUME_NAME" \
  "DQX_TMP_SCHEMA:$TMP_SCHEMA" "DQX_GENIE_SCHEMA:$GENIE_SCHEMA"; do
  require_identifier "${pair%%:*}" "${pair#*:}"
done
VOLUME_FULL_NAME="$CATALOG.$MAIN_SCHEMA.$VOLUME_NAME"
# A different DQX_CATALOG / DQX_SCHEMA would make this script create resources
# the app never uses.
if [[ -n $CONF_CATALOG && $CONF_CATALOG != "$CATALOG" ]] || [[ -n $CONF_SCHEMA && $CONF_SCHEMA != "$MAIN_SCHEMA" ]]; then
  die "DQX_CATALOG/DQX_SCHEMA (${CONF_CATALOG:-$CATALOG}.${CONF_SCHEMA:-$MAIN_SCHEMA}) differ from DQX_WHEELS_VOLUME ($CATALOG.$MAIN_SCHEMA), which the app uses; set DQX_WHEELS_VOLUME=/Volumes/${CONF_CATALOG:-$CATALOG}/${CONF_SCHEMA:-$MAIN_SCHEMA}/$VOLUME_NAME in $ENV_FILE"
fi
[[ -z $STORAGE_ROOT || $STORAGE_ROOT =~ ^[a-z0-9]+://[^[:space:]]+$ ]] ||
  die "DQX_CATALOG_STORAGE_ROOT must be a storage URL (e.g. abfss://<container>@<account>.dfs.core.windows.net/<path>) in $ENV_FILE"

[[ $LAKEBASE_ENDPOINT =~ ^projects/([A-Za-z0-9_-]+)/branches/([A-Za-z0-9_-]+)/endpoints/[A-Za-z0-9_-]+$ ]] ||
  die "DQX_LAKEBASE_ENDPOINT must look like projects/<project>/branches/<branch>/endpoints/<endpoint> in $ENV_FILE"
LAKEBASE_BRANCH="projects/${BASH_REMATCH[1]}/branches/${BASH_REMATCH[2]}"
LAKEBASE_ROLE_ID="sp-$SP_APP_ID"
require_identifier DQX_LAKEBASE_DATABASE_NAME "$LAKEBASE_DATABASE"
require_identifier DQX_LAKEBASE_SCHEMA "$LAKEBASE_SCHEMA"
# Lakebase database ids follow RFC 1123, like the built-in databricks-postgres.
LAKEBASE_DATABASE_ID=$(lowercase "$LAKEBASE_DATABASE" | tr '_' '-')

[[ $ADMIN_GROUP != *'"'* && $ADMIN_GROUP != *\\* && ! $ADMIN_GROUP =~ [[:cntrl:]] ]] ||
  die "DQX_ADMIN_GROUP must not contain quotes, backslashes, or control characters"
[[ -z $JOB_ID || $JOB_ID =~ ^[0-9]+$ ]] || die "DQX_JOB_ID must be numeric when set"
if [[ -n $RUNNER_APP_ID ]]; then
  [[ $RUNNER_APP_ID =~ $application_id_re ]] ||
    die "DQX_TASK_RUNNER_CLIENT_ID must be the task-runner service principal's application id (a UUID) in $ENV_FILE"
  [[ $RUNNER_APP_ID != "$SP_APP_ID" ]] ||
    die "DQX_TASK_RUNNER_CLIENT_ID must differ from DATABRICKS_CLIENT_ID: setup requires a separate task-runner identity"
fi

# --- Preflight: right workspace, SP exists ------------------------------------

PROFILE_HOST=$(databricks auth env --profile "$PROFILE" 2>/dev/null | jq -r '.env.DATABRICKS_HOST // empty' || true)
[[ -n $PROFILE_HOST ]] || die "could not resolve the host of profile '$PROFILE' (is it logged in? try: databricks auth login --profile $PROFILE)"
[[ $(normalize_host "$PROFILE_HOST") == "$(normalize_host "$HOST")" ]] ||
  die "profile '$PROFILE' points at $PROFILE_HOST, but DATABRICKS_HOST in $ENV_FILE is $HOST"

SP_JSON=$(lookup service-principals list --filter "applicationId eq \"$SP_APP_ID\"") ||
  die "could not list service principals with profile '$PROFILE'"
SP_ID=$(sp_field "$SP_JSON" "$SP_APP_ID" id)
SP_NAME=$(sp_field "$SP_JSON" "$SP_APP_ID" displayName)
[[ -n $SP_ID ]] || die "no service principal with application id $SP_APP_ID in $HOST (create it first: README step 1)"

RUNNER_JOB_ID=$JOB_ID
if [[ -n $RUNNER_APP_ID ]]; then
  RUNNER_JSON=$(lookup service-principals list --filter "applicationId eq \"$RUNNER_APP_ID\"") ||
    die "could not list service principals with profile '$PROFILE'"
  RUNNER_NAME=$(sp_field "$RUNNER_JSON" "$RUNNER_APP_ID" displayName)
  RUNNER_ID=$(sp_field "$RUNNER_JSON" "$RUNNER_APP_ID" id)
  [[ -n $RUNNER_ID ]] ||
    die "no service principal with application id $RUNNER_APP_ID (DQX_TASK_RUNNER_CLIENT_ID) in $HOST (create it first: README step 1)"

  # Setting a job's run-as needs the Service principal: User role on that SP,
  # which even the SP's creator (a Manager) doesn't hold by default.
  ME=$(lookup current-user me | jq -r '.userName // empty') && [[ -n $ME ]] ||
    die "could not read the current user of profile '$PROFILE'"
  if [[ $(lowercase "$ME") =~ $application_id_re ]]; then
    ME_PRINCIPAL="servicePrincipals/$(lowercase "$ME")"
  else
    ME_PRINCIPAL="users/$ME"
  fi

  # Without DQX_JOB_ID, the app uses the job carrying the Studio discovery tags
  # that its SP can see: one an earlier run of this script created (tagged with
  # the SP), or one the app created itself. With none, this script creates it.
  if [[ -z $RUNNER_JOB_ID ]]; then
    jobs_json=$(lookup jobs list) || die "could not list jobs with profile '$PROFILE'"
    app_jobs=$(jq -c --arg sp "$SP_APP_ID" '[.[]? | select(.settings.tags.dqx_studio_managed == "true"
      and .settings.tags.dqx_component == "task_runner"
      and (((.creator_user_name // "") | ascii_downcase) == $sp or .settings.tags.dqx_studio_app_sp == $sp)) | .job_id]' <<<"$jobs_json")
    [[ $(jq length <<<"$app_jobs") -le 1 ]] ||
      die "the app SP owns several task-runner jobs ($(jq -r 'map(tostring) | join(", ")' <<<"$app_jobs")); set DQX_JOB_ID in $ENV_FILE to the one to use"
    RUNNER_JOB_ID=$(jq -r '.[0] // empty' <<<"$app_jobs")
  fi
fi

# --- Preflight: prerequisites exist; find the resources to create --------------

lookup warehouses get "$WAREHOUSE_ID" >/dev/null ||
  die "SQL warehouse $WAREHOUSE_ID (DATABRICKS_WAREHOUSE_ID) not found in $HOST — create it first"
lookup postgres get-endpoint "$LAKEBASE_ENDPOINT" >/dev/null ||
  die "Lakebase endpoint $LAKEBASE_ENDPOINT (DQX_LAKEBASE_ENDPOINT) not found — create the Lakebase project first"

CREATE_ITEMS=()
CATALOG_MISSING=0
if ! lookup catalogs get "$CATALOG" >/dev/null; then
  CATALOG_MISSING=1
  CREATE_ITEMS+=("catalog $CATALOG")
fi
MISSING_SCHEMAS=()
for schema in "$MAIN_SCHEMA" "$TMP_SCHEMA" "$GENIE_SCHEMA"; do
  if ! lookup schemas get "$CATALOG.$schema" >/dev/null; then
    MISSING_SCHEMAS+=("$schema")
    CREATE_ITEMS+=("schema $CATALOG.$schema")
  fi
done
VOLUME_MISSING=0
if ! lookup volumes read "$VOLUME_FULL_NAME" >/dev/null; then
  VOLUME_MISSING=1
  CREATE_ITEMS+=("volume $VOLUME_FULL_NAME")
fi
databases_json=$(lookup postgres list-databases "$LAKEBASE_BRANCH") ||
  die "could not list the Lakebase databases of $LAKEBASE_BRANCH with profile '$PROFILE'"
DATABASE_MISSING=0
if ! jq -e --arg db "$LAKEBASE_DATABASE" \
  'any(.[]?; (.status.postgres_database // .spec.postgres_database) == $db)' <<<"$databases_json" >/dev/null; then
  [[ $LAKEBASE_DATABASE_ID =~ ^[a-z][a-z0-9-]{2,61}[a-z0-9]$ ]] ||
    die "the Lakebase database '$LAKEBASE_DATABASE' (DQX_LAKEBASE_DATABASE_NAME) does not exist and cannot be created under that name: use 4-63 letters, digits, or '_', starting with a letter"
  DATABASE_MISSING=1
  CREATE_ITEMS+=("Lakebase database $LAKEBASE_DATABASE")
fi

# --- Plan + confirmation -------------------------------------------------------

if [[ $(lowercase "$ADMIN_GROUP") == admins ]]; then
  ADMIN_GROUP_PLAN="skipped — 'admins' would make the SP a workspace admin"
else
  ADMIN_GROUP_PLAN="member"
fi

CREATE_PLAN="nothing — every resource exists"
if [[ ${#CREATE_ITEMS[@]} -gt 0 ]]; then
  CREATE_PLAN=$(printf '%s, ' "${CREATE_ITEMS[@]}")
  CREATE_PLAN=${CREATE_PLAN%, }
fi

if [[ -z $RUNNER_APP_ID ]]; then
  RUNNER_PLAN="<DQX_TASK_RUNNER_CLIENT_ID not set — skipped>"
else
  RUNNER_JOB_PLAN="a new task-runner job (CAN_MANAGE for the SP)"
  [[ -z $RUNNER_JOB_ID ]] || RUNNER_JOB_PLAN="job $RUNNER_JOB_ID"
  RUNNER_PLAN="${RUNNER_NAME:-<no display name>}  (application id $RUNNER_APP_ID)
                → run-as of $RUNNER_JOB_PLAN
                  (gives $ME the Service principal: User role on it, which the run-as requires)
                → USE_CATALOG; USE_SCHEMA, SELECT, MODIFY on $MAIN_SCHEMA; USE_SCHEMA on $TMP_SCHEMA; READ_VOLUME
                → Postgres OAuth role sp-$RUNNER_APP_ID; CONNECT, USAGE, SELECT + DELETE on $LAKEBASE_SCHEMA.dq_run_configs"
fi

cat <<EOF

DQX Studio — workspace setup
  Workspace     $HOST  (as profile '$PROFILE')
  Create        $CREATE_PLAN
  SP            ${SP_NAME:-<no display name>}  (application id $SP_APP_ID, id $SP_ID)
  Entitlements  workspace-access, databricks-sql-access
  Warehouse     $WAREHOUSE_ID  → CAN_USE
  Catalog       $CATALOG  → USE_CATALOG, CREATE_SCHEMA, READ_METADATA
  Schemas       $CATALOG.{$MAIN_SCHEMA,$TMP_SCHEMA,$GENIE_SCHEMA}  → ALL_PRIVILEGES
  Volume        $VOLUME_FULL_NAME  → ALL_PRIVILEGES
  Lakebase      $LAKEBASE_BRANCH  → Postgres role $LAKEBASE_ROLE_ID (DATABRICKS_SUPERUSER); database $LAKEBASE_DATABASE
  Admin group   $ADMIN_GROUP  → $ADMIN_GROUP_PLAN
  Task runner   ${JOB_ID:-<DQX_JOB_ID not set — skipped>}${JOB_ID:+  → CAN_MANAGE}
  Runner SP     $RUNNER_PLAN
EOF

if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
  (: </dev/tty) 2>/dev/null || die "no terminal to confirm on; re-run with --yes"
  printf '\nApply these changes? [y/N] '
  read -r reply </dev/tty
  [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]] || {
    echo "Aborted; nothing was changed."
    exit 1
  }
fi

# --- Resources ----------------------------------------------------------------

step "Unity Catalog resources"
if [[ $CATALOG_MISSING -eq 0 && ${#MISSING_SCHEMAS[@]} -eq 0 && $VOLUME_MISSING -eq 0 ]]; then
  note "the catalog, schemas, and wheels volume already exist"
fi
if [[ $CATALOG_MISSING -eq 1 ]]; then
  apply "create catalog $CATALOG" catalogs create "$CATALOG" ${STORAGE_ROOT:+--storage-root "$STORAGE_ROOT"}
fi
for schema in ${MISSING_SCHEMAS[@]+"${MISSING_SCHEMAS[@]}"}; do
  apply "create schema $CATALOG.$schema" schemas create "$schema" "$CATALOG"
done
if [[ $VOLUME_MISSING -eq 1 ]]; then
  apply "create volume $VOLUME_FULL_NAME" volumes create "$CATALOG" "$MAIN_SCHEMA" "$VOLUME_NAME" MANAGED
fi

# --- Grants -------------------------------------------------------------------

step "Workspace entitlements"
apply "workspace-access + databricks-sql-access" \
  service-principals patch "$SP_ID" --json "$(jq -nc --arg op "$SCIM_PATCH_OP" \
    '{schemas: [$op], Operations: [{op: "add", path: "entitlements",
      value: [{value: "workspace-access"}, {value: "databricks-sql-access"}]}]}')"

step "SQL warehouse"
apply "CAN_USE on warehouse $WAREHOUSE_ID" \
  warehouses update-permissions "$WAREHOUSE_ID" --json "$(acl_json CAN_USE)"

step "Unity Catalog"
# In a container, setup verifies the task runner's grants as the app SP (there
# is no signed-in administrator), and reading another principal's grants needs
# READ_METADATA. Granted on the catalog, it covers the schemas and volume too.
apply "USE_CATALOG, CREATE_SCHEMA, READ_METADATA on catalog $CATALOG" \
  grants update catalog "$CATALOG" --json "$(grant_json "$SP_APP_ID" USE_CATALOG CREATE_SCHEMA READ_METADATA)"
for schema in "$MAIN_SCHEMA" "$TMP_SCHEMA" "$GENIE_SCHEMA"; do
  apply "ALL_PRIVILEGES on schema $CATALOG.$schema" \
    grants update schema "$CATALOG.$schema" --json "$(grant_json "$SP_APP_ID" ALL_PRIVILEGES)"
done
apply "ALL_PRIVILEGES on volume $VOLUME_FULL_NAME" \
  grants update volume "$VOLUME_FULL_NAME" --json "$(grant_json "$SP_APP_ID" ALL_PRIVILEGES)"

step "Lakebase"
APP_ROLE_NAME="$LAKEBASE_BRANCH/roles/$LAKEBASE_ROLE_ID"
if role_json=$(lookup postgres get-role "$APP_ROLE_NAME"); then
  if jq -e '[.. | strings] | index("DATABRICKS_SUPERUSER")' <<<"$role_json" >/dev/null; then
    note "Postgres role $LAKEBASE_ROLE_ID already exists (DATABRICKS_SUPERUSER member)"
  else
    warn "Postgres role $LAKEBASE_ROLE_ID exists but is not a DATABRICKS_SUPERUSER member; the app cannot create its Postgres schema ($LAKEBASE_BRANCH) — recreate the role or add the membership"
  fi
elif roles_json=$(lookup postgres list-roles "$LAKEBASE_BRANCH") &&
  existing_role=$(jq -r --arg id "$SP_APP_ID" '[.[]? | select(((.status.postgres_role // .spec.postgres_role // "")
    | ascii_downcase) == $id) | .name] | .[0] // empty' <<<"$roles_json") && [[ -n $existing_role ]]; then
  APP_ROLE_NAME=$existing_role
  note "a Postgres role for the SP already exists ($existing_role); left unchanged (it must be a DATABRICKS_SUPERUSER member)"
else
  apply "Postgres role $LAKEBASE_ROLE_ID on $LAKEBASE_BRANCH (DATABRICKS_SUPERUSER member)" \
    postgres create-role "$LAKEBASE_BRANCH" --role-id "$LAKEBASE_ROLE_ID" --json "$(jq -nc --arg sp "$SP_APP_ID" \
      '{spec: {identity_type: "SERVICE_PRINCIPAL", postgres_role: $sp,
        auth_method: "LAKEBASE_OAUTH_V1", membership_roles: ["DATABRICKS_SUPERUSER"]}}')"
fi
if [[ $DATABASE_MISSING -eq 1 ]]; then
  # Owned by the app SP, so the app can create its schema and grant the task runner.
  apply "create Postgres database $LAKEBASE_DATABASE on $LAKEBASE_BRANCH (owned by the SP's role)" \
    postgres create-database "$LAKEBASE_BRANCH" --database-id "$LAKEBASE_DATABASE_ID" \
    --json "$(jq -nc --arg db "$LAKEBASE_DATABASE" --arg role "$APP_ROLE_NAME" '{spec: {postgres_database: $db, role: $role}}')"
else
  note "Postgres database $LAKEBASE_DATABASE already exists"
fi

step "Studio admin group"
if [[ $(lowercase "$ADMIN_GROUP") == admins ]]; then
  warn "DQX_ADMIN_GROUP is 'admins'; adding the SP would make it a workspace admin, so it was skipped — set a dedicated group (e.g. dqx-studio-local-admins) in $ENV_FILE"
else
  groups_json=$(lookup groups list --filter "displayName eq \"$ADMIN_GROUP\"" || echo '[]')
  GROUP_ID=$(jq -r --arg name "$ADMIN_GROUP" "$scim_items"' | map(select(.displayName == $name)) | .[0].id // empty' <<<"$groups_json")
  if [[ -z $GROUP_ID ]]; then
    apply "create group '$ADMIN_GROUP' with the SP as member" \
      groups create --json "$(jq -nc --arg name "$ADMIN_GROUP" --arg id "$SP_ID" \
        '{displayName: $name, members: [{value: $id}]}')"
  elif jq -e --arg id "$SP_ID" '(.members // []) | map(.value) | index($id)' \
    <<<"$(lookup groups get "$GROUP_ID" || echo '{}')" >/dev/null; then
    note "the SP is already a member of '$ADMIN_GROUP'"
  else
    apply "add the SP to group '$ADMIN_GROUP'" \
      groups patch "$GROUP_ID" --json "$(jq -nc --arg op "$SCIM_PATCH_OP" --arg id "$SP_ID" \
        '{schemas: [$op], Operations: [{op: "add", path: "members", value: [{value: $id}]}]}')"
  fi
fi

step "Task-runner job"
if [[ -n $JOB_ID ]]; then
  apply "CAN_MANAGE on job $JOB_ID" jobs update-permissions "$JOB_ID" --json "$(acl_json CAN_MANAGE)"
else
  note "DQX_JOB_ID is not set — skipped"
fi

step "Task-runner service principal"
if [[ -z $RUNNER_APP_ID ]]; then
  note "DQX_TASK_RUNNER_CLIENT_ID is not set — skipped. Setup completes only once the task-runner job runs as a separate service principal (README \"Set up\")"
else
  if [[ -n $RUNNER_JOB_ID &&
    $(lookup jobs get "$RUNNER_JOB_ID" | jq -r '.settings.run_as.service_principal_name // "" | ascii_downcase') == "$RUNNER_APP_ID" ]]; then
    note "job $RUNNER_JOB_ID already runs as the task-runner SP"
  else
    user_role="roles/servicePrincipal.user"
    account_id=$(lookup workspace-iam-v2 get-service-principal-proxy "$RUNNER_ID" | jq -r '.account_id // empty' || true)
    rule_set_name="accounts/$account_id/servicePrincipals/$RUNNER_APP_ID/ruleSets/default"
    if [[ -z $account_id ]] ||
      ! rule_set=$(lookup api get "/api/2.0/preview/accounts/access-control/rule-sets?name=$rule_set_name&etag="); then
      warn "could not read the roles on the task-runner SP; if setting the run-as fails, give $ME the 'Service principal: User' role on it (Settings → Identity and access → Service principals → ${RUNNER_NAME:-$RUNNER_APP_ID} → Permissions)"
    elif jq -e --arg role "$user_role" --arg me "$ME_PRINCIPAL" \
      'any(.grant_rules[]?; .role == $role and any(.principals[]?; . == $me))' <<<"$rule_set" >/dev/null; then
      note "$ME already has the Service principal: User role on the task-runner SP"
    else
      # The update replaces the whole rule set, so keep every existing rule.
      apply "Service principal: User role on the task-runner SP → $ME (needed to set the run-as)" \
        api put /api/2.0/preview/accounts/access-control/rule-sets --json "$(jq -c --arg role "$user_role" --arg me "$ME_PRINCIPAL" '
          (.grant_rules // []) as $rules
          | {name: .name, rule_set: {name: .name, etag: .etag, grant_rules: (
              if any($rules[]; .role == $role)
              then $rules | map(if .role == $role then .principals = ((.principals // []) + [$me] | unique) else . end)
              else $rules + [{role: $role, principals: [$me]}]
              end)}}' <<<"$rule_set")"
    fi
    if [[ -n $RUNNER_JOB_ID ]]; then
      apply "run-as of job $RUNNER_JOB_ID → task-runner SP" \
        jobs update --json "$(jq -nc --argjson id "$RUNNER_JOB_ID" --arg sp "$RUNNER_APP_ID" \
          '{job_id: $id, new_settings: {run_as: {service_principal_name: $sp}}}')"
    else
      # Same name and discovery tags as the job the app would create, so the app
      # uses this one and fills in its tasks, parameters, and environment.
      apply "create task-runner job dqx-studio-task-runner (runs as the task-runner SP; CAN_MANAGE for the app SP)" \
        jobs create --json "$(jq -nc --arg sp "$SP_APP_ID" --arg runner "$RUNNER_APP_ID" '
          {name: "dqx-studio-task-runner", max_concurrent_runs: 10,
           tags: {app: "dqx-studio", dqx_studio_managed: "true", dqx_component: "task_runner", dqx_studio_app_sp: $sp},
           run_as: {service_principal_name: $runner},
           access_control_list: [{service_principal_name: $sp, permission_level: "CAN_MANAGE"}]}')"
    fi
  fi

  apply "USE_CATALOG on catalog $CATALOG (task runner)" \
    grants update catalog "$CATALOG" --json "$(grant_json "$RUNNER_APP_ID" USE_CATALOG)"
  apply "USE_SCHEMA, SELECT, MODIFY on schema $CATALOG.$MAIN_SCHEMA (task runner)" \
    grants update schema "$CATALOG.$MAIN_SCHEMA" --json "$(grant_json "$RUNNER_APP_ID" USE_SCHEMA SELECT MODIFY)"
  apply "USE_SCHEMA on schema $CATALOG.$TMP_SCHEMA (task runner)" \
    grants update schema "$CATALOG.$TMP_SCHEMA" --json "$(grant_json "$RUNNER_APP_ID" USE_SCHEMA)"
  apply "READ_VOLUME on volume $VOLUME_FULL_NAME (task runner)" \
    grants update volume "$VOLUME_FULL_NAME" --json "$(grant_json "$RUNNER_APP_ID" READ_VOLUME)"

  RUNNER_ROLE_ID="sp-$RUNNER_APP_ID"
  if role_json=$(lookup postgres get-role "$LAKEBASE_BRANCH/roles/$RUNNER_ROLE_ID"); then
    if jq -e '[.. | strings] | index("DATABRICKS_SUPERUSER")' <<<"$role_json" >/dev/null; then
      warn "Postgres role $RUNNER_ROLE_ID is a DATABRICKS_SUPERUSER member; the task runner must never be — recreate the role without that membership"
    else
      note "Postgres role $RUNNER_ROLE_ID already exists"
    fi
  elif roles_json=$(lookup postgres list-roles "$LAKEBASE_BRANCH") &&
    jq -e --arg id "$RUNNER_APP_ID" '[.. | strings | ascii_downcase] | index($id)' <<<"$roles_json" >/dev/null; then
    note "a Postgres role for the task-runner SP already exists on $LAKEBASE_BRANCH under another id; left unchanged (it must not be a DATABRICKS_SUPERUSER member)"
  else
    apply "Postgres OAuth role $RUNNER_ROLE_ID on $LAKEBASE_BRANCH (task runner, no DATABRICKS_SUPERUSER)" \
      postgres create-role "$LAKEBASE_BRANCH" --role-id "$RUNNER_ROLE_ID" --json "$(jq -nc --arg sp "$RUNNER_APP_ID" \
        '{spec: {identity_type: "SERVICE_PRINCIPAL", postgres_role: $sp, auth_method: "LAKEBASE_OAUTH_V1"}}')"
  fi

  # The app SP owns the Lakebase schema and its tables, so the app's migrations
  # (which create dq_run_configs) and these grants run as the app SP, in a
  # one-off app container that already holds its credentials.
  pg_grants="CONNECT on $LAKEBASE_DATABASE, USAGE on $LAKEBASE_SCHEMA, SELECT + DELETE on $LAKEBASE_SCHEMA.dq_run_configs (task runner, as the app SP, after the app's migrations)"
  compose=(docker compose -f "$SCRIPT_DIR/docker-compose.yml")
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n      docker compose build (when dqx-studio:local is missing); docker compose run --rm --no-deps -T dqx-studio python - < grant_runner_lakebase.py\n' "$pg_grants"
  elif [[ ! $ENV_FILE -ef $SCRIPT_DIR/.env ]]; then
    warn "the task runner's Lakebase grants run in the app container, which reads $SCRIPT_DIR/.env rather than $ENV_FILE — skipped"
  elif ! command -v docker >/dev/null; then
    warn "Docker is not installed — skipped the task runner's Lakebase grants"
  else
    status=0
    if ! docker image inspect dqx-studio:local >/dev/null 2>&1; then
      note "building the dqx-studio:local image (a few minutes the first time)"
      output=$("${compose[@]}" build 2>&1) || status=$?
    fi
    if [[ $status -eq 0 ]]; then
      output=$("${compose[@]}" run --rm --no-deps -T -e "DQX_TASK_RUNNER_CLIENT_ID=$RUNNER_APP_ID" \
        dqx-studio python - <"$SCRIPT_DIR/grant_runner_lakebase.py" 2>&1) || status=$?
    fi
    if [[ $status -eq 0 ]]; then
      printf '  ✓ %s\n' "$pg_grants"
    else
      printf '  ✗ %s\n' "$pg_grants"
      printf '%s\n' "$output" | tail -n 5 | sed 's/^/      /'
      FAILURES+=("$pg_grants")
    fi
  fi
fi

# --- Summary --------------------------------------------------------------------

step "Summary"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  Dry run — nothing was changed. Re-run without --dry-run to apply."
fi
for message in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
  printf '  ! %s\n' "$message"
done
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "  These steps failed (your profile may lack MANAGE / admin rights on them):"
  for failure in "${FAILURES[@]}"; do
    printf '    ✗ %s\n' "$failure"
  done
  exit 1
fi
[[ $DRY_RUN -eq 1 ]] || echo "  All resources and permissions are in place. Start the app with: docker compose up (if it is running, select Verify again in the setup wizard)"
echo "  To browse or profile your own tables in the UI, also grant the SP USE CATALOG, USE SCHEMA, and SELECT on them."
