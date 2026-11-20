from __future__ import annotations

import base64
import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    deploy_env: str = field(default_factory=lambda: os.getenv("DEPLOY_ENV", "local"))
    database_url: str | None = field(default_factory=lambda: os.getenv("DATABASE_URL"))
    db_host: str | None = field(default_factory=lambda: os.getenv("DB_HOST"))
    db_name: str = field(default_factory=lambda: os.getenv("DB_NAME", "app"))
    db_user: str = field(default_factory=lambda: os.getenv("DB_USER", "intake_api"))
    db_iam_auth: bool = field(default_factory=lambda: os.getenv("DB_IAM_AUTH", "false") == "true")
    phi_kms_key_id: str | None = field(default_factory=lambda: os.getenv("PHI_KMS_KEY_ID"))
    local_master_key_b64: str | None = field(default_factory=lambda: os.getenv("LOCAL_MASTER_KEY_B64"))
    blind_index_key_b64: str | None = field(default_factory=lambda: os.getenv("BLIND_INDEX_KEY_B64"))
    log_level: str = field(default_factory=lambda: os.getenv("LOG_LEVEL", "INFO"))

    def __post_init__(self) -> None:
        if self.deploy_env in ("prod", "staging"):
            if not self.phi_kms_key_id:
                raise ValueError("PHI_KMS_KEY_ID is required outside local/ephemeral")
            if self.local_master_key_b64:
                raise ValueError("LOCAL_MASTER_KEY_B64 must never be set in prod/staging")
            if not self.db_iam_auth:
                raise ValueError("IAM database auth is mandatory in prod/staging")

    @property
    def blind_index_key(self) -> bytes:
        if not self.blind_index_key_b64:
            if self.deploy_env in ("prod", "staging"):
                raise ValueError("BLIND_INDEX_KEY_B64 is required")
            return b"local-dev-blind-index-key-000000"
        return base64.b64decode(self.blind_index_key_b64)

    def resolved_database_url(self) -> str:
        if self.database_url:
            return self.database_url
        if not self.db_host:
            return "sqlite+pysqlite:///./local.db"
        if self.db_iam_auth:
            # Password is a 15-minute IAM token injected per-connection (see db.py).
            return (
                f"postgresql+psycopg://{self.db_user}@{self.db_host}:5432/{self.db_name}"
                "?sslmode=verify-full&sslrootcert=/etc/ssl/certs/rds-global-bundle.pem"
            )
        return f"postgresql+psycopg://{self.db_user}@{self.db_host}:5432/{self.db_name}"
