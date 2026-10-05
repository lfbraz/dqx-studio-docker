#!/usr/bin/env bash
#
# Grant the service principal configured in .env every permission DQX Studio
# needs to run in this container (see README.md "Set up the service principal").
#
# Run it as YOUR OWN admin-capable identity: a service principal cannot grant
# itself access. The SP's application id and all resources come from .env; the
# client secret is never read.
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
Usage: grant_sp_permissions.sh --profile <admin-profile> [--env-file <path>] [--dry-run] [--yes]

Grants the DQX Studio service principal (DATABRICKS_CLIENT_ID in .env):
  - workspace-access + databricks-sql-access entitlements
  - CAN_USE on the SQL warehouse (DATABRICKS_WAREHOUSE_ID)
  - USE_CATALOG + CREATE_SCHEMA on the catalog of DQX_WHEELS_VOLUME
  - ALL_PRIVILEGES on the main, tmp, and genie schemas (those that exist)
  - ALL_PRIVILEGES on the wheels volume
  - a Lakebase Postgres role (DATABRICKS_SUPERUSER member) on the
    DQX_LAKEBASE_ENDPOINT branch
  - membership in DQX_ADMIN_GROUP (created if missing; never "admins")
  - CAN_MANAGE on DQX_JOB_ID, when set

Options:
  -p, --profile   CLI profile for the DATABRICKS_HOST workspace, run as an identity
                  that can grant on the warehouse, catalog, Lakebase project, and
                  groups (required)
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

# {"changes":[{"principal":<sp>,"add":[<privileges...>]}]} for "grants update".
grant_json() {
  jq -nc --arg sp "$SP_APP_ID" '{changes: [{principal: $sp, add: $ARGS.positional}]}' --args "$@"
}

# {"access_control_list":[...]} for warehouse / job "update-permissions".
acl_json() {
  jq -nc --arg sp "$SP_APP_ID" --arg level "$1" \
    '{access_control_list: [{service_principal_name: $sp, permission_level: $level}]}'
}

# SCIM list responses: a bare array, or an object with "Resources".
scim_items='if type == "array" then . else (.Resources // []) end'

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
TMP_SCHEMA=$(env_value DQX_TMP_SCHEMA)
TMP_SCHEMA=${TMP_SCHEMA:-dqx_studio_tmp}
GENIE_SCHEMA=$(env_value DQX_GENIE_SCHEMA)
GENIE_SCHEMA=${GENIE_SCHEMA:-genie}
LAKEBASE_ENDPOINT=$(env_value DQX_LAKEBASE_ENDPOINT)
ADMIN_GROUP=$(env_value DQX_ADMIN_GROUP)
ADMIN_GROUP=${ADMIN_GROUP:-admins}
JOB_ID=$(env_value DQX_JOB_ID)

[[ $HOST =~ ^https:// ]] || die "DATABRICKS_HOST must be set to the workspace URL (https://...) in $ENV_FILE"
[[ $SP_APP_ID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  die "DATABRICKS_CLIENT_ID must be the service principal's application id (a UUID) in $ENV_FILE"
[[ $WAREHOUSE_ID =~ ^[A-Za-z0-9]+$ ]] || die "DATABRICKS_WAREHOUSE_ID must be set to a warehouse id in $ENV_FILE"

# The app derives its catalog and main schema from the volume path, so do we.
[[ $VOLUME_PATH =~ ^/Volumes/([^/]+)/([^/]+)/([^/]+)/?$ ]] ||
  die "DQX_WHEELS_VOLUME must look like /Volumes/<catalog>/<schema>/<volume> in $ENV_FILE"
CATALOG=${BASH_REMATCH[1]}
MAIN_SCHEMA=${BASH_REMATCH[2]}
VOLUME_NAME=${BASH_REMATCH[3]}
for pair in "catalog:$CATALOG" "schema:$MAIN_SCHEMA" "volume:$VOLUME_NAME" \
  "DQX_TMP_SCHEMA:$TMP_SCHEMA" "DQX_GENIE_SCHEMA:$GENIE_SCHEMA"; do
  require_identifier "${pair%%:*}" "${pair#*:}"
done
VOLUME_FULL_NAME="$CATALOG.$MAIN_SCHEMA.$VOLUME_NAME"

[[ $LAKEBASE_ENDPOINT =~ ^projects/([A-Za-z0-9_-]+)/branches/([A-Za-z0-9_-]+)/endpoints/[A-Za-z0-9_-]+$ ]] ||
  die "DQX_LAKEBASE_ENDPOINT must look like projects/<project>/branches/<branch>/endpoints/<endpoint> in $ENV_FILE"
LAKEBASE_BRANCH="projects/${BASH_REMATCH[1]}/branches/${BASH_REMATCH[2]}"
LAKEBASE_ROLE_ID="sp-$SP_APP_ID"

[[ $ADMIN_GROUP != *'"'* && $ADMIN_GROUP != *\\* && ! $ADMIN_GROUP =~ [[:cntrl:]] ]] ||
  die "DQX_ADMIN_GROUP must not contain quotes, backslashes, or control characters"
[[ -z $JOB_ID || $JOB_ID =~ ^[0-9]+$ ]] || die "DQX_JOB_ID must be numeric when set"

# --- Preflight: right workspace, SP exists ------------------------------------

PROFILE_HOST=$(databricks auth env --profile "$PROFILE" 2>/dev/null | jq -r '.env.DATABRICKS_HOST // empty' || true)
[[ -n $PROFILE_HOST ]] || die "could not resolve the host of profile '$PROFILE' (is it logged in? try: databricks auth login --profile $PROFILE)"
[[ $(normalize_host "$PROFILE_HOST") == "$(normalize_host "$HOST")" ]] ||
  die "profile '$PROFILE' points at $PROFILE_HOST, but DATABRICKS_HOST in $ENV_FILE is $HOST"

SP_JSON=$(lookup service-principals list --filter "applicationId eq \"$SP_APP_ID\"") ||
  die "could not list service principals with profile '$PROFILE'"
SP_ID=$(jq -r --arg id "$SP_APP_ID" "$scim_items"' | map(select((.applicationId // "" | ascii_downcase) == $id)) | .[0].id // empty' <<<"$SP_JSON")
SP_NAME=$(jq -r --arg id "$SP_APP_ID" "$scim_items"' | map(select((.applicationId // "" | ascii_downcase) == $id)) | .[0].displayName // empty' <<<"$SP_JSON")
[[ -n $SP_ID ]] || die "no service principal with application id $SP_APP_ID in $HOST (create it first: README step 1)"

if [[ -n $CONF_CATALOG && $CONF_CATALOG != "$CATALOG" ]] || [[ -n $CONF_SCHEMA && $CONF_SCHEMA != "$MAIN_SCHEMA" ]]; then
  warn "DQX_CATALOG/DQX_SCHEMA ($CONF_CATALOG.$CONF_SCHEMA) differ from DQX_WHEELS_VOLUME ($CATALOG.$MAIN_SCHEMA); the app uses the volume's catalog and schema, so this script does too"
fi

# --- Plan + confirmation -------------------------------------------------------

if [[ $(lowercase "$ADMIN_GROUP") == admins ]]; then
  ADMIN_GROUP_PLAN="skipped — 'admins' would make the SP a workspace admin"
else
  ADMIN_GROUP_PLAN="member"
fi

cat <<EOF

DQX Studio — service principal permissions
  Workspace     $HOST  (as profile '$PROFILE')
  SP            ${SP_NAME:-<no display name>}  (application id $SP_APP_ID, id $SP_ID)
  Entitlements  workspace-access, databricks-sql-access
  Warehouse     $WAREHOUSE_ID  → CAN_USE
  Catalog       $CATALOG  → USE_CATALOG, CREATE_SCHEMA
  Schemas       $CATALOG.{$MAIN_SCHEMA,$TMP_SCHEMA,$GENIE_SCHEMA}  → ALL_PRIVILEGES (existing ones)
  Volume        $VOLUME_FULL_NAME  → ALL_PRIVILEGES
  Lakebase      $LAKEBASE_BRANCH  → Postgres role $LAKEBASE_ROLE_ID (DATABRICKS_SUPERUSER)
  Admin group   $ADMIN_GROUP  → $ADMIN_GROUP_PLAN
  Task runner   ${JOB_ID:-<DQX_JOB_ID not set — skipped>}${JOB_ID:+  → CAN_MANAGE}
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
apply "USE_CATALOG, CREATE_SCHEMA on catalog $CATALOG" \
  grants update catalog "$CATALOG" --json "$(grant_json USE_CATALOG CREATE_SCHEMA)"
apply "ALL_PRIVILEGES on schema $CATALOG.$MAIN_SCHEMA" \
  grants update schema "$CATALOG.$MAIN_SCHEMA" --json "$(grant_json ALL_PRIVILEGES)"
for schema in "$TMP_SCHEMA" "$GENIE_SCHEMA"; do
  if lookup schemas get "$CATALOG.$schema" >/dev/null; then
    apply "ALL_PRIVILEGES on schema $CATALOG.$schema" \
      grants update schema "$CATALOG.$schema" --json "$(grant_json ALL_PRIVILEGES)"
  else
    note "$CATALOG.$schema does not exist yet — the app creates (and owns) it on first start"
  fi
done
apply "ALL_PRIVILEGES on volume $VOLUME_FULL_NAME" \
  grants update volume "$VOLUME_FULL_NAME" --json "$(grant_json ALL_PRIVILEGES)"

step "Lakebase"
if role_json=$(lookup postgres get-role "$LAKEBASE_BRANCH/roles/$LAKEBASE_ROLE_ID"); then
  if jq -e '[.. | strings] | index("DATABRICKS_SUPERUSER")' <<<"$role_json" >/dev/null; then
    note "Postgres role $LAKEBASE_ROLE_ID already exists (DATABRICKS_SUPERUSER member)"
  else
    warn "Postgres role $LAKEBASE_ROLE_ID exists but is not a DATABRICKS_SUPERUSER member; the app cannot create its Postgres schema ($LAKEBASE_BRANCH) — recreate the role or add the membership"
  fi
elif roles_json=$(lookup postgres list-roles "$LAKEBASE_BRANCH") &&
  jq -e --arg id "$SP_APP_ID" '[.. | strings | ascii_downcase] | index($id)' <<<"$roles_json" >/dev/null; then
  note "a Postgres role for the SP already exists on $LAKEBASE_BRANCH under another id; left unchanged (it must be a DATABRICKS_SUPERUSER member)"
else
  apply "Postgres role $LAKEBASE_ROLE_ID on $LAKEBASE_BRANCH (DATABRICKS_SUPERUSER member)" \
    postgres create-role "$LAKEBASE_BRANCH" --role-id "$LAKEBASE_ROLE_ID" --json "$(jq -nc --arg sp "$SP_APP_ID" \
      '{spec: {identity_type: "SERVICE_PRINCIPAL", postgres_role: $sp,
        auth_method: "LAKEBASE_OAUTH_V1", membership_roles: ["DATABRICKS_SUPERUSER"]}}')"
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
  note "DQX_JOB_ID is not set — skipped (the app creates a job on first start if needed)"
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
[[ $DRY_RUN -eq 1 ]] || echo "  All permissions are in place. Start the app with: docker compose up"
echo "  To browse or profile your own tables in the UI, also grant the SP USE CATALOG, USE SCHEMA, and SELECT on them."
