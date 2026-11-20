import pytest

from intake_api.admin import admin_url, grant_statements, role_statements


def test_roles_are_idempotent_and_iam_enabled():
    stmts = role_statements("intake_api", "dr_verifier")
    assert len(stmts) == 4
    assert all("IF NOT EXISTS" in s or "IF EXISTS" in s for s in stmts)
    assert any("GRANT rds_iam TO intake_api" in s for s in stmts)
    assert any("GRANT rds_iam TO dr_verifier" in s for s in stmts)


def test_app_role_cannot_mutate_audit_log_or_delete():
    stmts = " ; ".join(grant_statements("platform_admin", "intake_api", "dr_verifier"))
    assert "REVOKE UPDATE, DELETE, TRUNCATE ON phi_access_log FROM intake_api" in stmts
    assert "DELETE" not in stmts.split("REVOKE")[0]  # no DELETE granted anywhere
    assert "CREATE" not in stmts  # no DDL rights for runtime roles


def test_verifier_is_read_only():
    for s in grant_statements("platform_admin", "intake_api", "dr_verifier"):
        if "dr_verifier" in s and s.startswith("GRANT") and "USAGE" not in s:
            assert "GRANT SELECT" in s


@pytest.mark.parametrize("bad", ["intake_api; DROP TABLE patients", "Robert'); --", "x" * 70, ""])
def test_rejects_unsafe_role_names(bad):
    with pytest.raises(ValueError):
        role_statements(bad, "dr_verifier")


def test_admin_url_escapes_password_and_verifies_tls():
    url = admin_url("db.example", "app", "platform_admin", "p@ss/w:rd?#")
    assert "p%40ss%2Fw%3Ard%3F%23" in url
    assert "sslmode=verify-full" in url and "sslrootcert=" in url
