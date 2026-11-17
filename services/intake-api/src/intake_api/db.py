from __future__ import annotations

from collections.abc import Iterator

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from .settings import Settings


def build_engine(settings: Settings) -> Engine:
    url = settings.resolved_database_url()
    kwargs: dict = {"pool_pre_ping": True}
    if url.startswith("postgresql"):
        # Recycle before IAM tokens (15 min) expire; keep pool small: Aurora
        # Serverless connections are not free.
        kwargs.update(pool_size=5, max_overflow=5, pool_recycle=600)
    engine = create_engine(url, **kwargs)

    if settings.db_iam_auth and settings.db_host:
        import boto3

        rds = boto3.client("rds")

        @event.listens_for(engine, "do_connect")
        def _inject_iam_token(dialect, conn_rec, cargs, cparams):  # noqa: ARG001
            cparams["password"] = rds.generate_db_auth_token(
                DBHostname=settings.db_host, Port=5432, DBUsername=settings.db_user
            )

    return engine


def session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, expire_on_commit=False)


def get_session(factory: sessionmaker[Session]) -> Iterator[Session]:
    session = factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
