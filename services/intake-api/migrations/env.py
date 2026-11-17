"""Alembic environment.

Migration policy (enforced in code review + CI, see docs/runbooks/db-migrations.md):
  * Expand/contract only. A deploy may ADD (nullable columns, new tables,
    indexes CONCURRENTLY); it may not DROP or RENAME something the previous
    app version still reads. Destructive steps ship in a later release.
  * Every migration has a working downgrade(), exercised in CI.
  * lock_timeout + statement_timeout are set so a migration can never hold
    an ACCESS EXCLUSIVE lock long enough to cause an outage.
"""

from alembic import context
from sqlalchemy import text

from intake_api.db import build_engine
from intake_api.models import Base
from intake_api.settings import Settings

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(url=Settings().resolved_database_url(), target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = build_engine(Settings())
    with engine.connect() as connection:
        if connection.dialect.name == "postgresql":
            connection.execute(text("SET lock_timeout = '5s'"))
            connection.execute(text("SET statement_timeout = '15min'"))
        context.configure(connection=connection, target_metadata=target_metadata, transaction_per_migration=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
