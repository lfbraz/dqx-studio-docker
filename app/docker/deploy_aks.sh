#!/usr/bin/env bash
#
# Deploy DQX Studio to AKS from .env (README.md "Deploy to Azure Kubernetes
# Service"). Creates missing Azure resources, builds the image in ACR, and runs
# one replica behind a ClusterIP Service. Run setup.sh first. Idempotent; stops
# at the first failure.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
RESOURCE_GROUP=""
REGISTRY=""
CLUSTER="dqx-studio"
LOCATION=""
NAMESPACE="dqx-studio"
NODE_SIZE="Standard_D2s_v5"
NODE_COUNT=1
API_SERVER_RANGES=""
TAG=""
IMAGE=""
LOCAL_BUILD=0
DRY_RUN=0
ASSUME_YES=0
APP_NAME="dqx-studio"
SECRET_NAME="dqx-studio-env"
PULL_TOKEN="dqx-studio-pull"
PULL_SECRET="dqx-studio-acr-pull"
IMAGE_REPOSITORY="dqx-studio"
# Build-only (.env.example): passed to --local-build, kept out of the Secret.
BUILD_ONLY_KEYS="UV_INDEX_URL NPM_REGISTRY"
# What the Dockerfile copies from the repository root.
BUILD_PATHS=(pyproject.toml README.md LICENSE NOTICE src app)

usage() {
  cat <<'EOF'
Usage: deploy_aks.sh -g <resource-group> -r <acr-name> [options]

Creates the resource group, container registry, and AKS cluster when missing,
builds and pushes the image, and deploys it (Secret from .env, one replica,
ClusterIP Service on port 8000).

Options:
  -g, --resource-group  resource group (required)
  -r, --registry        ACR name, globally unique (required)
  -c, --cluster         AKS cluster (default: dqx-studio)
  -l, --location        region for a new resource group; use the workspace's
  -n, --namespace       namespace (default: dqx-studio)
      --node-size       VM size of a new cluster (default: Standard_D2s_v5)
      --node-count      nodes of a new cluster (default: 1)
      --api-server-ip-ranges
                        IPv4 CIDRs allowed to reach the API server
                        (default: your public IP)
      --env-file        configuration (default: .env next to this script)
      --tag             image tag (default: git commit)
      --image           deploy this image instead of building one
      --local-build     build with local Docker instead of ACR Tasks
      --dry-run         print the changes without applying them
  -y, --yes             skip the confirmation prompt
  -h, --help            show this help
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

# Silent under --dry-run, where run() already printed the command.
changed() {
  [[ $DRY_RUN -eq 1 ]] || printf '  ✓ %s\n' "$*"
}

# Mutating command; printed instead of executed under --dry-run.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# KEY=VALUE pairs of the env file (last one wins, quotes stripped), without empty
# values or build-only keys. Parsed, never sourced.
env_pairs() {
  awk -v skip=" $BUILD_ONLY_KEYS " '
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      key = substr(line, 1, index(line, "=") - 1)
      value = substr(line, index(line, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
      if (index(skip, " " key " ")) next
      if (!(key in values)) order[++count] = key
      values[key] = value
    }
    END {
      for (i = 1; i <= count; i++) if (values[order[i]] != "") print order[i] "=" values[order[i]]
    }
  ' "$ENV_FILE"
}

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

# 32-bit integer of a dotted IPv4 address.
ipv4_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%s' $(((a << 24) | (b << 16) | (c << 8) | d))
}

# Whether IPv4 CIDR $1 contains CIDR $2 (a bare address is a /32).
cidr_contains() {
  local outer=$1 inner=$2 outer_bits inner_bits mask
  [[ $outer == */* ]] || outer="$outer/32"
  [[ $inner == */* ]] || inner="$inner/32"
  outer_bits=${outer#*/}
  inner_bits=${inner#*/}
  [[ $outer_bits -le $inner_bits ]] || return 1
  mask=$(((0xFFFFFFFF << (32 - outer_bits)) & 0xFFFFFFFF))
  [[ $(($(ipv4_int "${outer%/*}") & mask)) -eq $(($(ipv4_int "${inner%/*}") & mask)) ]]
}

ipv4_cidr_re='^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}(/(3[0-2]|[12]?[0-9]))?$'

# Whether the cluster's kubelet identity has AcrPull on the registry.
acr_pull_granted() {
  local kubelet
  [[ -n $ACR_ID ]] || return 1
  kubelet=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" --query identityProfile.kubeletidentity.objectId -o tsv)
  [[ -n $kubelet ]] || return 1
  [[ $(az role assignment list --assignee "$kubelet" --scope "$ACR_ID" --include-inherited \
    --query "length([?roleDefinitionName=='AcrPull'])" -o tsv) -gt 0 ]]
}

checksum() {
  if command -v sha256sum >/dev/null; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# --- Arguments --------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    -g | --resource-group | -r | --registry | -c | --cluster | -l | --location | -n | --namespace | \
      --node-size | --node-count | --api-server-ip-ranges | --env-file | --tag | --image)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case $1 in
        -g | --resource-group) RESOURCE_GROUP=$2 ;;
        -r | --registry) REGISTRY=$2 ;;
        -c | --cluster) CLUSTER=$2 ;;
        -l | --location) LOCATION=$2 ;;
        -n | --namespace) NAMESPACE=$2 ;;
        --node-size) NODE_SIZE=$2 ;;
        --node-count) NODE_COUNT=$2 ;;
        --api-server-ip-ranges) API_SERVER_RANGES=$2 ;;
        --env-file) ENV_FILE=$2 ;;
        --tag) TAG=$2 ;;
        --image) IMAGE=$2 ;;
      esac
      shift 2
      ;;
    --local-build)
      LOCAL_BUILD=1
      shift
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

[[ -n $RESOURCE_GROUP && -n $REGISTRY ]] || {
  usage >&2
  die "--resource-group and --registry are required"
}
[[ $RESOURCE_GROUP =~ ^[A-Za-z0-9._()-]{1,90}$ ]] || die "invalid resource group name: $RESOURCE_GROUP"
[[ $REGISTRY =~ ^[A-Za-z0-9]{5,50}$ ]] || die "--registry must be 5-50 letters or digits: $REGISTRY"
[[ $CLUSTER =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]] || die "invalid cluster name: $CLUSTER"
[[ -z $LOCATION || $LOCATION =~ ^[a-z0-9]+$ ]] || die "--location must be an Azure region name, e.g. eastus: $LOCATION"
[[ $NAMESPACE =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "--namespace must be a DNS label: $NAMESPACE"
[[ $NODE_SIZE =~ ^[A-Za-z0-9_]+$ ]] || die "invalid --node-size: $NODE_SIZE"
[[ $NODE_COUNT =~ ^[1-9][0-9]*$ ]] || die "--node-count must be a positive integer"
[[ -z $TAG || $TAG =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid --tag: $TAG"
[[ -z $IMAGE || $IMAGE =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "invalid --image: $IMAGE"
[[ -z $IMAGE || -z $TAG ]] || die "--tag names the image this script builds; it can't be combined with --image"
[[ -z $IMAGE || $LOCAL_BUILD -eq 0 ]] || die "--local-build builds an image; it can't be combined with --image"
[[ -f $ENV_FILE ]] || die "env file not found: $ENV_FILE"

command -v az >/dev/null || die "the Azure CLI is not installed (brew install azure-cli)"
if [[ $DRY_RUN -eq 0 ]]; then
  command -v kubectl >/dev/null || die "kubectl is not installed (brew install kubectl, or az aks install-cli)"
fi
if [[ $LOCAL_BUILD -eq 1 ]]; then
  command -v docker >/dev/null || die "--local-build needs Docker with buildx"
fi
if [[ -z $IMAGE ]]; then
  command -v git >/dev/null || die "git is needed to assemble the build context"
fi

# --- Configuration from .env -------------------------------------------------

for key in DATABRICKS_HOST DATABRICKS_CLIENT_ID DATABRICKS_CLIENT_SECRET DATABRICKS_WAREHOUSE_ID \
  DQX_WHEELS_VOLUME DQX_LAKEBASE_ENDPOINT; do
  [[ -n $(env_value "$key") ]] || die "$key must be set in $ENV_FILE"
done
HOST=$(env_value DATABRICKS_HOST)
CONFIG_KEYS=$(env_pairs | cut -d= -f1 | paste -sd' ' -)
# In the pod template, so a config change restarts the pod.
CONFIG_CHECKSUM=$(env_pairs | checksum)

if [[ $(env_value DQX_DEFAULT_AUTH_FALLBACK) != 1 ]]; then
  printf '  ! DQX_DEFAULT_AUTH_FALLBACK is not 1: without an authenticating proxy in front, every API call returns 401\n'
fi

# API server authorized IP ranges; default: this machine's public IP.
if [[ -z $API_SERVER_RANGES ]]; then
  API_SERVER_RANGES=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
  [[ -n $API_SERVER_RANGES ]] || die "could not detect your public IP; pass --api-server-ip-ranges"
fi
API_SERVER_RANGES=$(printf '%s' "$API_SERVER_RANGES" | tr -d '[:space:]')
IFS=, read -r -a REQUESTED_RANGES <<<"$API_SERVER_RANGES"
[[ ${#REQUESTED_RANGES[@]} -gt 0 ]] || die "--api-server-ip-ranges is empty"
for range in "${REQUESTED_RANGES[@]}"; do
  [[ $range =~ $ipv4_cidr_re ]] || die "--api-server-ip-ranges: '$range' is not an IPv4 address or CIDR"
  [[ $range != */0 ]] || die "--api-server-ip-ranges: '$range' would open the API server to everyone"
done

# --- Preflight: Azure account and existing resources --------------------------

az account show -o none 2>/dev/null || die "not logged in to Azure; run az login"
SUBSCRIPTION=$(az account show --query '[name, id]' -o tsv | paste -sd' ' -)

GROUP_LOCATION=$(az group show -n "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
if [[ -z $GROUP_LOCATION ]]; then
  [[ -n $LOCATION ]] || die "resource group $RESOURCE_GROUP doesn't exist; pass --location to create it (the workspace's region)"
  GROUP_PLAN="create in $LOCATION"
else
  [[ -z $LOCATION || $LOCATION == "$GROUP_LOCATION" ]] ||
    note "resource group $RESOURCE_GROUP is in $GROUP_LOCATION; new resources go there, not to $LOCATION"
  LOCATION=$GROUP_LOCATION
  GROUP_PLAN="exists ($LOCATION)"
fi

ACR_ID=$(az acr show -n "$REGISTRY" --query id -o tsv 2>/dev/null || true)
if [[ -z $ACR_ID ]]; then
  REGISTRY_PLAN="create (Basic SKU)"
  LOGIN_SERVER="$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]').azurecr.io"
else
  [[ $ACR_ID == */resourceGroups/*/providers/* ]] || die "unexpected registry id: $ACR_ID"
  REGISTRY_PLAN="exists"
  LOGIN_SERVER=$(az acr show -n "$REGISTRY" --query loginServer -o tsv)
fi

CLUSTER_EXISTS=0
MISSING_RANGES=()
if az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" -o none 2>/dev/null; then
  CLUSTER_EXISTS=1
  CLUSTER_PLAN="exists"
  IS_PRIVATE=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" --query apiServerAccessProfile.enablePrivateCluster -o tsv)
  CURRENT_RANGES=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" \
    --query "join(',', apiServerAccessProfile.authorizedIpRanges || \`[]\`)" -o tsv)
  if [[ $IS_PRIVATE == true ]]; then
    RANGES_PLAN="private cluster: kubectl needs network access to its VNet"
  elif [[ -z $CURRENT_RANGES ]]; then
    RANGES_PLAN="unrestricted; left as is"
  else
    IFS=, read -r -a EXISTING_RANGES <<<"$CURRENT_RANGES"
    for range in "${REQUESTED_RANGES[@]}"; do
      covered=0
      for existing in "${EXISTING_RANGES[@]}"; do
        if [[ $existing =~ $ipv4_cidr_re ]] && cidr_contains "$existing" "$range"; then
          covered=1
          break
        fi
      done
      [[ $covered -eq 1 ]] || MISSING_RANGES+=("$range")
    done
    if [[ ${#MISSING_RANGES[@]} -eq 0 ]]; then
      RANGES_PLAN="$CURRENT_RANGES; covers $API_SERVER_RANGES"
    else
      RANGES_PLAN="$CURRENT_RANGES; add $(IFS=,; printf '%s' "${MISSING_RANGES[*]}")"
    fi
  fi
else
  CLUSTER_PLAN="create ($NODE_COUNT × $NODE_SIZE)"
  RANGES_PLAN="$API_SERVER_RANGES"
fi

# Granting AcrPull needs Owner, so without it pull with a repository-scoped token.
USE_PULL_TOKEN=1
PULL_PLAN="pull-only token $PULL_TOKEN (the cluster has no AcrPull)"
if [[ $CLUSTER_EXISTS -eq 1 ]] && acr_pull_granted; then
  USE_PULL_TOKEN=0
  PULL_PLAN="AcrPull of the cluster identity"
fi

if [[ -n $IMAGE ]]; then
  IMAGE_PLAN="$IMAGE  (prebuilt)"
else
  if [[ -z $TAG ]]; then
    TAG=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)
    [[ -z $(git -C "$REPO_ROOT" status --porcelain -- "${BUILD_PATHS[@]}") ]] || TAG="$TAG-dirty-$(date -u +%Y%m%d%H%M%S)"
  fi
  IMAGE="$LOGIN_SERVER/$IMAGE_REPOSITORY:$TAG"
  if [[ $LOCAL_BUILD -eq 1 ]]; then
    IMAGE_PLAN="$IMAGE  (built locally for linux/amd64)"
  else
    IMAGE_PLAN="$IMAGE  (built by ACR Tasks for linux/amd64)"
  fi
fi

# --- Plan + confirmation -------------------------------------------------------

cat <<EOF

DQX Studio — deploy to AKS
  Subscription    $SUBSCRIPTION
  Resource group  $RESOURCE_GROUP  → $GROUP_PLAN
  Registry        $REGISTRY  → $REGISTRY_PLAN
  Cluster         $CLUSTER  → $CLUSTER_PLAN
  Image pulls     $PULL_PLAN
  API server      authorized IP ranges: $RANGES_PLAN
  Image           $IMAGE_PLAN
  Namespace       $NAMESPACE
  Secret          $SECRET_NAME  ← $ENV_FILE ($CONFIG_KEYS)
  Workload        Deployment $APP_NAME (1 replica) + ClusterIP Service on port 8000
  Workspace       $HOST
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

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
chmod 700 "$WORK_DIR"

# --- Azure resources ------------------------------------------------------------

step "Resource group"
if [[ -z $GROUP_LOCATION ]]; then
  run az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
  changed "created $RESOURCE_GROUP in $LOCATION"
else
  note "$RESOURCE_GROUP exists"
fi

step "Container registry"
if [[ -z $ACR_ID ]]; then
  run az acr create -g "$RESOURCE_GROUP" -n "$REGISTRY" -l "$LOCATION" --sku Basic -o none
  [[ $DRY_RUN -eq 1 ]] || ACR_ID=$(az acr show -n "$REGISTRY" --query id -o tsv)
  changed "created $LOGIN_SERVER"
else
  note "$LOGIN_SERVER exists"
fi

step "AKS cluster"
if [[ $CLUSTER_EXISTS -eq 0 ]]; then
  [[ $DRY_RUN -eq 1 ]] || note "creating $CLUSTER; this takes several minutes"
  run az aks create -g "$RESOURCE_GROUP" -n "$CLUSTER" -l "$LOCATION" \
    --node-count "$NODE_COUNT" --node-vm-size "$NODE_SIZE" --tier free \
    --enable-managed-identity --no-ssh-key \
    --api-server-authorized-ip-ranges "$API_SERVER_RANGES" -o none
  changed "created $CLUSTER"
else
  if [[ ${#MISSING_RANGES[@]} -gt 0 ]]; then
    run az aks update -g "$RESOURCE_GROUP" -n "$CLUSTER" -o none \
      --api-server-authorized-ip-ranges "$CURRENT_RANGES,$(IFS=,; printf '%s' "${MISSING_RANGES[*]}")"
    changed "authorized $(IFS=,; printf '%s' "${MISSING_RANGES[*]}") on the API server"
  fi
  note "$CLUSTER exists"
fi

step "Image pulls"
if [[ $USE_PULL_TOKEN -eq 0 ]]; then
  note "the cluster pulls with AcrPull"
elif az acr token show -r "$REGISTRY" -n "$PULL_TOKEN" -o none 2>/dev/null; then
  note "token $PULL_TOKEN exists"
else
  run az acr token create -r "$REGISTRY" -n "$PULL_TOKEN" --repository "$IMAGE_REPOSITORY" content/read \
    --no-passwords -o none
  changed "created token $PULL_TOKEN (pull-only on $IMAGE_REPOSITORY)"
fi

# --- Image ----------------------------------------------------------------------

if [[ $IMAGE_PLAN != *"(prebuilt)" ]]; then
  step "Image"
  if [[ $LOCAL_BUILD -eq 1 ]]; then
    BUILD_ARGS=()
    for key in $BUILD_ONLY_KEYS; do
      value=$(env_value "$key")
      [[ -z $value ]] || BUILD_ARGS+=(--build-arg "$key=$value")
    done
    run az acr login -n "$REGISTRY"
    run docker buildx build --platform linux/amd64 -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE" \
      ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --push "$REPO_ROOT"
  else
    # Upload only non-git-ignored files, so .env never leaves the machine.
    CONTEXT="$WORK_DIR/context"
    mkdir -p "$CONTEXT"
    (
      cd "$REPO_ROOT"
      git ls-files -z --cached --others --exclude-standard -- "${BUILD_PATHS[@]}" |
        while IFS= read -r -d '' file; do [[ -f $file ]] && printf '%s\0' "$file"; done |
        tar -cf - --null -T - | tar -xf - -C "$CONTEXT"
    )
    cp "$SCRIPT_DIR/Dockerfile.dockerignore" "$CONTEXT/.dockerignore"
    note "build context: $(du -sh "$CONTEXT" | cut -f1 | tr -d '[:space:]')"
    # From inside the context: az resolves --file against the current directory.
    (
      cd "$CONTEXT"
      run az acr build -r "$REGISTRY" -t "$IMAGE_REPOSITORY:$TAG" --platform linux/amd64 \
        -f app/docker/Dockerfile --timeout 3600 .
    )
  fi
  changed "pushed $IMAGE"
fi

# --- Kubernetes -----------------------------------------------------------------

pull_secrets_yaml() {
  [[ $USE_PULL_TOKEN -eq 1 ]] || return 0
  printf '      imagePullSecrets:\n        - name: %s\n' "$PULL_SECRET"
}

manifests() {
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: $APP_NAME
spec:
  replicas: 1
  # Never two pods at once: each would run the scheduler.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: $APP_NAME
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $APP_NAME
      annotations:
        dqx-studio/config-checksum: "$CONFIG_CHECKSUM"
    spec:
      automountServiceAccountToken: false
$(pull_secrets_yaml)
      nodeSelector:
        kubernetes.io/os: linux
        kubernetes.io/arch: amd64
      containers:
        - name: $APP_NAME
          image: $IMAGE
          ports:
            - name: http
              containerPort: 8000
          envFrom:
            - secretRef:
                name: $SECRET_NAME
          resources:
            requests:
              cpu: 250m
              memory: 1Gi
            limits:
              memory: 3Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          # Startup (migrations, wheel publishing) may take up to 10 minutes.
          startupProbe:
            httpGet:
              path: /api/health
              port: http
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /api/health
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/health
              port: http
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 5
---
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: $APP_NAME
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: $APP_NAME
  ports:
    - name: http
      port: 8000
      targetPort: http
EOF
}

# Server-side: no last-applied annotation copying the Secret's values.
apply_manifests() {
  kubectl apply --server-side --field-manager=deploy-aks --force-conflicts -f -
}

step "Kubernetes"
if [[ $DRY_RUN -eq 1 ]]; then
  note "would create namespace $NAMESPACE and secret $SECRET_NAME ($CONFIG_KEYS)"
  [[ $USE_PULL_TOKEN -eq 0 ]] || note "would generate a $PULL_TOKEN password into secret $PULL_SECRET"
  note "would apply:"
  manifests | sed 's/^/      /'
else
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER" --file "$KUBECONFIG" -o none
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | apply_manifests >/dev/null
  (
    umask 077
    env_pairs >"$WORK_DIR/config.env"
  )
  kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" --from-env-file="$WORK_DIR/config.env" \
    --dry-run=client -o yaml | apply_manifests >/dev/null
  rm -f "$WORK_DIR/config.env"
  note "secret $SECRET_NAME updated"
  if [[ $USE_PULL_TOKEN -eq 1 ]]; then
    # A new password on every run; it expires after a year without one.
    password=$(az acr token credential generate -r "$REGISTRY" -n "$PULL_TOKEN" --password1 \
      --expiration-in-days 365 --query "passwords[0].value" -o tsv)
    auth=$(printf '%s:%s' "$PULL_TOKEN" "$password" | base64 | tr -d '\n')
    (
      umask 077
      printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
        "$LOGIN_SERVER" "$PULL_TOKEN" "$password" "$auth" >"$WORK_DIR/dockerconfig.json"
    )
    unset password auth
    kubectl -n "$NAMESPACE" create secret generic "$PULL_SECRET" --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$WORK_DIR/dockerconfig.json" --dry-run=client -o yaml | apply_manifests >/dev/null
    rm -f "$WORK_DIR/dockerconfig.json"
    note "secret $PULL_SECRET updated"
  fi
  manifests | apply_manifests
  if ! kubectl -n "$NAMESPACE" rollout status "deployment/$APP_NAME" --timeout=12m; then
    kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$APP_NAME" -o wide || true
    kubectl -n "$NAMESPACE" logs "deployment/$APP_NAME" --tail=40 || true
    die "the rollout did not become ready; see the pod status and logs above"
  fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\nDry run complete; nothing was changed.\n'
  exit 0
fi

cat <<EOF

Done. DQX Studio runs in $CLUSTER, namespace $NAMESPACE, and is not exposed
outside the cluster. To open it on http://localhost:8000:

  az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER
  kubectl -n $NAMESPACE port-forward svc/$APP_NAME 8000:8000

Logs: kubectl -n $NAMESPACE logs -f deployment/$APP_NAME
EOF
