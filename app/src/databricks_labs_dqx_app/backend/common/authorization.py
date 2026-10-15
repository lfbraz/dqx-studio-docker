import asyncio
import logging
import os
from enum import Enum
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from ..cache import app_cache

logger = logging.getLogger(__name__)


class UserRole(str, Enum):
    ADMIN = "admin"
    RULE_APPROVER = "rule_approver"
    RULE_AUTHOR = "rule_author"
    VIEWER = "viewer"


# Role hierarchy for primary-role resolution (higher index = higher priority).
ROLE_PRIORITY: list[UserRole] = [
    UserRole.VIEWER,
    UserRole.RULE_AUTHOR,
    UserRole.RULE_APPROVER,
    UserRole.ADMIN,
]

# Permissions granted to each role
PERMISSIONS: dict[UserRole, list[str]] = {
    UserRole.ADMIN: [
        "view_rules",
        "create_rules",
        "edit_rules",
        "generate_rules",
        "submit_rules",
        "approve_rules",
        "export_rules",
        "configure_storage",
        "manage_roles",
        "run_rules",
    ],
    UserRole.RULE_APPROVER: [
        "view_rules",
        "approve_rules",
        "export_rules",
        "configure_storage",
    ],
    UserRole.RULE_AUTHOR: [
        "view_rules",
        "create_rules",
        "edit_rules",
        "generate_rules",
        "submit_rules",
        "run_rules",
    ],
    UserRole.VIEWER: [
        "view_rules",
    ],
}

# Roles that may trigger rule execution (manual runs, scheduled runs, batch runs).
# VIEWER and RULE_APPROVER are excluded — approvers review rules, not execute them.
CAN_RUN_ROLES: tuple[UserRole, ...] = (UserRole.ADMIN, UserRole.RULE_AUTHOR)


def get_permissions_for_role(role: UserRole) -> list[str]:
    """Return the list of permissions granted to a role."""
    return PERMISSIONS.get(role, [])


DEFAULT_AUTH_FALLBACK_ENV = "DQX_DEFAULT_AUTH_FALLBACK"


def default_auth_fallback_enabled() -> bool:
    """Return whether requests without platform identity headers may use the SDK default auth.

    On Databricks Apps the proxy always injects the X-Forwarded-* headers and the app
    authenticates via DATABRICKS_CLIENT_ID/SECRET with no CLI profile or PAT, so this is
    never true there. It is true for local development with a CLI profile or PAT, and
    when DQX_DEFAULT_AUTH_FALLBACK=1 is set explicitly for a standalone container that
    authenticates as a service principal via DATABRICKS_CLIENT_ID/SECRET. Every request
    then runs as that single identity, so only enable the flag where untrusted callers
    cannot reach the app.

    Returns:
        True when header-less requests fall back to the SDK default auth.
    """
    return bool(
        os.environ.get("DATABRICKS_CONFIG_PROFILE")
        or os.environ.get("DATABRICKS_TOKEN")
        or os.environ.get(DEFAULT_AUTH_FALLBACK_ENV) == "1"
    )


_DEFAULT_AUTH_USER_TTL = 45 * 60  # 45 minutes, matching the cached SP WorkspaceClient


def _current_user_name(token: str | None = None) -> str | None:
    """Return the SCIM user name of the OBO *token*, or of the SDK default auth when None."""
    from databricks.sdk import WorkspaceClient

    workspace = WorkspaceClient(token=token, auth_type="pat") if token else WorkspaceClient()
    return workspace.current_user.me().user_name


@app_cache.cached("auth:default:user_name", ttl=_DEFAULT_AUTH_USER_TTL)
async def _resolve_default_auth_user_name() -> str:
    """Resolve the SDK default-auth identity once per TTL instead of once per request.

    Building a WorkspaceClient and calling SCIM costs seconds per request, and the
    identity is fixed for the process. Raises when the user name is missing so a
    failed lookup is never cached.
    """
    user_name = await asyncio.to_thread(_current_user_name)
    if not user_name:
        raise ValueError("default auth identity has no user name")
    logger.warning(
        "X-Forwarded-Email/Access-Token missing — resolved email via local default auth (%s). Local dev only.",
        user_name,
    )
    return user_name


async def get_user_email(
    x_forwarded_email: Annotated[str | None, Header()] = None,
    x_forwarded_access_token: Annotated[str | None, Header()] = None,
) -> str:
    """Resolve the authenticated user's email.

    Primary source is the platform-verified X-Forwarded-Email header.
    Fallback derives the email from the OBO access token via the SCIM API,
    which is needed for local dev where the proxy only injects the token.
    """
    if x_forwarded_email:
        return x_forwarded_email

    if x_forwarded_access_token:
        try:
            user_name = await asyncio.to_thread(_current_user_name, x_forwarded_access_token)
            if user_name:
                logger.debug("Resolved user email from OBO token: %s", user_name)
                return user_name
        except Exception:
            logger.warning("Failed to resolve user email from OBO token", exc_info=True)

    # Default-auth fallback: no X-Forwarded-* headers are present outside Databricks
    # Apps. When a CLI profile / token is configured (local dev) or the standalone
    # flag is set, derive the email from the SDK default auth — same gate as
    # get_obo_ws. Cannot trigger in production (see default_auth_fallback_enabled).
    if default_auth_fallback_enabled():
        try:
            return await _resolve_default_auth_user_name()
        except Exception:
            logger.warning("Failed to resolve user email from local default auth", exc_info=True)

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="User identity not found. Missing X-Forwarded-Email header.",
    )


CurrentUser = Annotated[str, Depends(get_user_email)]

# Note: get_user_role, require_role, and CurrentUserRole are defined in
# dependencies.py to avoid circular imports (they need RoleService).
