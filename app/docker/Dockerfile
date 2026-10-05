# syntax=docker/dockerfile:1.7
#
# DQX Studio — local container image.
#
# Build context is the REPOSITORY ROOT (not app/), because the app resolves the
# co-developed `databricks-labs-dqx` library from the parent checkout via
# `[tool.uv.sources]`. `scripts/build_app.py` vendors that library into
# `.build/_vendor/dqx` and retargets the copied pyproject/uv.lock, so the
# assembled tree is fully self-contained.
#
#   docker compose -f app/docker/docker-compose.yml up --build     (recommended)
#   docker build -f app/docker/Dockerfile -t dqx-studio:local .    (from repo root)
#
# See app/docker/README.md for configuration and the Databricks prerequisites.

# ---------------------------------------------------------------------------
# Stage 1 — builder: compile the UI, dump OpenAPI, assemble .build/, sync venv
# ---------------------------------------------------------------------------
FROM python:3.12-bookworm AS builder

# uv (pinned to match the repo toolchain) — copied from the official image.
COPY --from=ghcr.io/astral-sh/uv:0.12.1 /uv /uvx /usr/local/bin/

# Optional package-registry proxies, for networks that block public PyPI / npm
# (e.g. a corporate proxy). Passed via --build-arg / compose build.args; when
# empty the build uses the public registries.
#   UV_INDEX_URL  — Python package index for uv (empty => default PyPI).
#   NPM_REGISTRY  — npm/yarn registry mirror (empty => default registry.npmjs.org).
ARG UV_INDEX_URL=
ARG NPM_REGISTRY=

# Node 22 + yarn classic (v1) for the Vite/orval frontend build. When NPM_REGISTRY
# is set, point npm + yarn at it; the repo's registry-agnostic yarn.lock (no pinned
# tarball URLs) then resolves every package from that mirror.
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh; \
    bash /tmp/nodesource_setup.sh; \
    apt-get install -y --no-install-recommends nodejs; \
    if [ -n "${NPM_REGISTRY}" ]; then npm config set registry "${NPM_REGISTRY}"; fi; \
    npm install -g yarn@1.22.22; \
    if [ -n "${NPM_REGISTRY}" ]; then yarn config set registry "${NPM_REGISTRY}"; fi; \
    rm -rf /var/lib/apt/lists/* /tmp/nodesource_setup.sh

# Deterministic, self-contained venvs that survive a cross-stage COPY:
#  - copy (not hardlink) packages so /app/.venv holds real files
#  - only-system Python at a fixed path, identical in the slim runtime stage,
#    so the venv the runtime inherits points at an interpreter that exists.
# UV_INDEX_URL is inherited by every uv invocation (build_app openapi dump +
# uv sync); an empty value is treated by uv as "use the default index".
ENV UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-system \
    UV_PYTHON=/usr/local/bin/python3.12 \
    UV_INDEX_URL=${UV_INDEX_URL} \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /repo

# Parent DQX library sources — the minimum hatchling needs to build it, plus
# the package source that gets vendored into the app's deploy tree.
COPY pyproject.toml README.md LICENSE NOTICE ./
COPY src ./src

# The app itself (node_modules / .venv / .build are excluded via .dockerignore).
COPY app ./app

WORKDIR /repo/app

# Frontend deps, then the canonical build (== `make app-build`):
#   OpenAPI dump -> orval -> vite build -> assemble .build/ -> vendor dqx.
RUN yarn install --frozen-lockfile
RUN python scripts/build_app.py

# Assemble the runtime tree at its final path (/app) and resolve the locked
# environment there. Building the venv here (full toolchain available) means the
# slim runtime stage needs no compilers and no network at start.
RUN cp -a /repo/app/.build /app
WORKDIR /app
RUN uv sync --frozen --no-dev

# ---------------------------------------------------------------------------
# Stage 2 — runtime: slim image serving FastAPI + the built SPA on one port
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

# TLS roots for outbound HTTPS to the Databricks workspace and Lakebase.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    VIRTUAL_ENV=/app/.venv \
    PATH=/app/.venv/bin:$PATH \
    DQX_APP_PORT=8000

WORKDIR /app

# Source tree + pre-built venv from the builder (same /app path -> relocatable).
COPY --from=builder /app /app

EXPOSE 8000

# `/api/health` is dependency-free process liveness (no workspace/DB needed).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/health', timeout=3).status == 200 else 1)"

# Single worker: the in-process scheduler holds an exclusive file-lock lease,
# so exactly one worker must drive it.
CMD ["python", "-m", "uvicorn", "databricks_labs_dqx_app.backend.app:app", \
     "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
