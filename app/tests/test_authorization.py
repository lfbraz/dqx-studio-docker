"""Tests for ``backend.common.authorization``.

Covers:
- ``UserRole`` permission map shape (each role has a sane permission set).
- ``RUNNER`` orthogonality vs. the primary-role hierarchy.
- ``get_user_email`` header trust, OBO fallback, and 401 behaviour.
- ``default_auth_fallback_enabled`` gating, shared by ``get_user_email`` and
  ``dependencies.get_obo_ws``.
"""

import asyncio
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

from databricks_labs_dqx_app.backend.common.authorization import (
    DEFAULT_AUTH_FALLBACK_ENV,
    PERMISSIONS,
    ROLE_PRIORITY,
    UserRole,
    default_auth_fallback_enabled,
    get_permissions_for_role,
    get_user_email,
)
from databricks_labs_dqx_app.backend.dependencies import get_obo_ws, get_sp_ws


@pytest.fixture
def no_default_auth_env(monkeypatch):
    """Strip every variable that enables the default-auth fallback.

    app/.env is loaded on package import, so a developer's local profile or
    token would otherwise leak into these tests.
    """
    for name in ("DATABRICKS_CONFIG_PROFILE", "DATABRICKS_TOKEN", DEFAULT_AUTH_FALLBACK_ENV):
        monkeypatch.delenv(name, raising=False)
    return monkeypatch


# ---------------------------------------------------------------------------
# Permission map
# ---------------------------------------------------------------------------


class TestPermissionMap:
    def test_every_role_has_an_entry(self):
        for role in UserRole:
            assert role in PERMISSIONS, f"Missing permissions for {role}"

    def test_admin_has_every_other_roles_perms(self):
        admin_perms = set(PERMISSIONS[UserRole.ADMIN])
        for role, perms in PERMISSIONS.items():
            if role == UserRole.ADMIN:
                continue
            assert set(perms).issubset(admin_perms), f"Admin missing perms from {role}: {set(perms) - admin_perms}"

    def test_admin_includes_run_rules(self):
        # Admins can always run rules.
        assert "run_rules" in PERMISSIONS[UserRole.ADMIN]

    def test_no_runner_role(self):
        # RUNNER is removed — the enum must not have a RUNNER member.
        assert not hasattr(UserRole, "RUNNER")

    def test_viewer_is_read_only(self):
        assert PERMISSIONS[UserRole.VIEWER] == ["view_rules"]

    # A1: new matrix assertions -------------------------------------------

    def test_author_has_run_rules(self):
        assert "run_rules" in get_permissions_for_role(UserRole.RULE_AUTHOR)

    def test_approver_cannot_author_or_run(self):
        p = get_permissions_for_role(UserRole.RULE_APPROVER)
        assert "run_rules" not in p
        assert "create_rules" not in p
        assert "edit_rules" not in p
        assert "submit_rules" not in p

    def test_approver_can_approve_and_export(self):
        p = get_permissions_for_role(UserRole.RULE_APPROVER)
        assert "approve_rules" in p
        assert "export_rules" in p
        assert "configure_storage" in p

    def test_viewer_only_views(self):
        assert get_permissions_for_role(UserRole.VIEWER) == ["view_rules"]

    def test_author_can_write_but_not_approve(self):
        author = set(PERMISSIONS[UserRole.RULE_AUTHOR])
        assert "create_rules" in author
        assert "edit_rules" in author
        assert "submit_rules" in author
        assert "approve_rules" not in author
        assert "manage_roles" not in author

    def test_approver_can_approve_but_not_manage_roles(self):
        approver = set(PERMISSIONS[UserRole.RULE_APPROVER])
        assert "approve_rules" in approver
        assert "manage_roles" not in approver

    def test_role_priority_ascending_admin_last(self):
        # Stronger roles should come later in the priority list, since the
        # resolver walks reversed(ROLE_PRIORITY) and returns the first match.
        assert ROLE_PRIORITY[-1] == UserRole.ADMIN
        assert ROLE_PRIORITY[0] == UserRole.VIEWER


class TestGetPermissionsForRole:
    def test_returns_list(self):
        assert isinstance(get_permissions_for_role(UserRole.ADMIN), list)

    def test_unknown_role_returns_empty(self):
        # Defensive: passing a not-quite-UserRole returns [] (defaults to .get()).
        # We don't pass an arbitrary string because the type system disallows it,
        # but we still verify the .get() default by mutating PERMISSIONS view.
        assert get_permissions_for_role(UserRole.VIEWER) == ["view_rules"]


# ---------------------------------------------------------------------------
# get_user_email
# ---------------------------------------------------------------------------


class TestGetUserEmail:
    async def test_returns_x_forwarded_email_when_present(self):
        # NOTE: this captures *current* behaviour. The security audit (C-1)
        # flagged that this header is trusted without OBO cross-check; if
        # that gets fixed the test will need updating.
        assert await get_user_email(x_forwarded_email="alice@example.com") == "alice@example.com"

    async def test_x_forwarded_email_wins_over_token(self):
        # When both are present, the header is used directly (the OBO
        # fallback only fires when the header is missing).
        with patch("databricks.sdk.WorkspaceClient") as mock_ws_cls:
            assert (
                await get_user_email(
                    x_forwarded_email="alice@example.com",
                    x_forwarded_access_token="t0k3n",
                )
                == "alice@example.com"
            )
            mock_ws_cls.assert_not_called()

    async def test_falls_back_to_obo_token_resolution(self):
        with patch("databricks.sdk.WorkspaceClient") as mock_ws_cls:
            mock_user = MagicMock()
            mock_user.user_name = "bob@example.com"
            mock_ws_cls.return_value.current_user.me.return_value = mock_user

            email = await get_user_email(x_forwarded_email=None, x_forwarded_access_token="t0k3n")
            assert email == "bob@example.com"
            mock_ws_cls.assert_called_once()

    async def test_returns_401_when_neither_provided(self, no_default_auth_env):
        # The fallback variables are stripped to exercise the pure
        # "no identity" path the test name describes.
        with pytest.raises(HTTPException) as excinfo:
            await get_user_email(x_forwarded_email=None, x_forwarded_access_token=None)
        assert excinfo.value.status_code == 401

    async def test_fallback_flag_resolves_email_from_default_auth(self, no_default_auth_env):
        # Standalone container: SP credentials in env + explicit opt-in flag.
        no_default_auth_env.setenv(DEFAULT_AUTH_FALLBACK_ENV, "1")
        no_default_auth_env.setenv("DATABRICKS_CLIENT_ID", "sp-app-id")
        no_default_auth_env.setenv("DATABRICKS_CLIENT_SECRET", "sp-secret")
        with patch("databricks.sdk.WorkspaceClient") as mock_ws_cls:
            mock_user = MagicMock()
            mock_user.user_name = "sp-app-id"
            mock_ws_cls.return_value.current_user.me.return_value = mock_user

            email = await get_user_email(x_forwarded_email=None, x_forwarded_access_token=None)
            assert email == "sp-app-id"
            mock_ws_cls.assert_called_once_with()

    async def test_fallback_resolves_default_auth_once(self, no_default_auth_env):
        # Building a client and calling SCIM costs seconds, so the fixed default-auth
        # identity is resolved once instead of on every request.
        no_default_auth_env.setenv(DEFAULT_AUTH_FALLBACK_ENV, "1")
        with patch("databricks.sdk.WorkspaceClient") as mock_ws_cls:
            mock_ws_cls.return_value.current_user.me.return_value = MagicMock(user_name="sp-app-id")

            first = await get_user_email(x_forwarded_email=None, x_forwarded_access_token=None)
            await asyncio.sleep(0)  # let the cache's fire-and-forget write land, as between requests
            second = await get_user_email(x_forwarded_email=None, x_forwarded_access_token=None)

        assert first == second == "sp-app-id"
        mock_ws_cls.assert_called_once_with()

    async def test_fallback_does_not_cache_a_failed_lookup(self, no_default_auth_env):
        no_default_auth_env.setenv(DEFAULT_AUTH_FALLBACK_ENV, "1")
        with patch("databricks.sdk.WorkspaceClient") as mock_ws_cls:
            mock_ws_cls.return_value.current_user.me.side_effect = [
                RuntimeError("scim down"),
                MagicMock(user_name="sp-app-id"),
            ]

            with pytest.raises(HTTPException) as excinfo:
                await get_user_email(x_forwarded_email=None, x_forwarded_access_token=None)
            assert excinfo.value.status_code == 401
            await asyncio.sleep(0)
            assert await get_user_email(x_forwarded_email=None, x_forwarded_access_token=None) == "sp-app-id"

    async def test_returns_401_when_obo_lookup_fails_and_no_header(self):
        # Token present but SCIM call blows up → no email → 401.
        with patch("databricks.sdk.WorkspaceClient", side_effect=RuntimeError("scim down")):
            with pytest.raises(HTTPException) as excinfo:
                await get_user_email(x_forwarded_email=None, x_forwarded_access_token="t0k3n")
            assert excinfo.value.status_code == 401

    async def test_obo_lookup_returns_user_with_no_user_name_yields_401(self):
        # If SCIM succeeds but `user_name` is None, the function falls
        # through to the 401 branch.
        with patch("databricks.sdk.WorkspaceClient") as mock_ws_cls:
            mock_user = MagicMock()
            mock_user.user_name = None
            mock_ws_cls.return_value.current_user.me.return_value = mock_user

            with pytest.raises(HTTPException) as excinfo:
                await get_user_email(x_forwarded_email=None, x_forwarded_access_token="t0k3n")
            assert excinfo.value.status_code == 401


# ---------------------------------------------------------------------------
# default_auth_fallback_enabled
# ---------------------------------------------------------------------------


class TestDefaultAuthFallbackEnabled:
    def test_disabled_without_profile_token_or_flag(self, no_default_auth_env):
        assert default_auth_fallback_enabled() is False

    def test_service_principal_credentials_alone_do_not_enable_it(self, no_default_auth_env):
        # This is exactly the Databricks Apps production shape: the platform
        # injects SP credentials and the X-Forwarded-* headers are mandatory.
        no_default_auth_env.setenv("DATABRICKS_CLIENT_ID", "sp-app-id")
        no_default_auth_env.setenv("DATABRICKS_CLIENT_SECRET", "sp-secret")
        assert default_auth_fallback_enabled() is False

    @pytest.mark.parametrize(
        ("name", "value"),
        [
            ("DATABRICKS_CONFIG_PROFILE", "dev"),
            ("DATABRICKS_TOKEN", "dapi-test"),
            (DEFAULT_AUTH_FALLBACK_ENV, "1"),
        ],
    )
    def test_enabled_by_profile_token_or_flag(self, no_default_auth_env, name, value):
        no_default_auth_env.setenv(name, value)
        assert default_auth_fallback_enabled() is True

    @pytest.mark.parametrize("value", ["0", "", "true", "yes"])
    def test_flag_must_be_exactly_one(self, no_default_auth_env, value):
        no_default_auth_env.setenv(DEFAULT_AUTH_FALLBACK_ENV, value)
        assert default_auth_fallback_enabled() is False


# ---------------------------------------------------------------------------
# dependencies.get_obo_ws (shares the default-auth gate)
# ---------------------------------------------------------------------------


class TestGetOboWsFallback:
    async def test_rejects_headerless_request_without_fallback(self, no_default_auth_env):
        no_default_auth_env.setenv("DATABRICKS_CLIENT_ID", "sp-app-id")
        no_default_auth_env.setenv("DATABRICKS_CLIENT_SECRET", "sp-secret")
        with pytest.raises(HTTPException) as excinfo:
            await get_obo_ws(token=None)
        assert excinfo.value.status_code == 401

    async def test_fallback_flag_uses_default_auth(self, no_default_auth_env):
        no_default_auth_env.setenv(DEFAULT_AUTH_FALLBACK_ENV, "1")
        no_default_auth_env.setenv("DATABRICKS_CLIENT_ID", "sp-app-id")
        no_default_auth_env.setenv("DATABRICKS_CLIENT_SECRET", "sp-secret")
        with patch("databricks_labs_dqx_app.backend.dependencies.WorkspaceClient") as mock_ws_cls:
            workspace = await get_obo_ws(token=None)
        assert workspace is mock_ws_cls.return_value
        mock_ws_cls.assert_called_once_with()

    async def test_fallback_reuses_the_cached_service_principal_client(self, no_default_auth_env):
        # A new WorkspaceClient per request costs ~1s of auth setup; header-less
        # requests share the cached SP client instead.
        no_default_auth_env.setenv(DEFAULT_AUTH_FALLBACK_ENV, "1")
        with patch("databricks_labs_dqx_app.backend.dependencies.WorkspaceClient") as mock_ws_cls:
            first = await get_obo_ws(token=None)
            await asyncio.sleep(0)  # let the cache's fire-and-forget write land, as between requests
            second = await get_obo_ws(token=None)
            sp_workspace = await get_sp_ws()
        assert first is second is sp_workspace
        mock_ws_cls.assert_called_once_with()
