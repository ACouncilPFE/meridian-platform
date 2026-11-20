# syntax=docker/dockerfile:1.7
# Multi-stage build: compilers and build deps never reach the runtime image.

FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /src
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY pyproject.toml ./
COPY src ./src
RUN pip install .

FROM python:3.12-slim AS runtime
# Patch OS packages, then drop to an unprivileged user (UID matches the
# ECS task definition `user = "10001"`; root FS is mounted read-only).
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
# Amazon RDS CA bundle so the app can use sslmode=verify-full against Aurora.
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/certs/rds-global-bundle.pem
COPY --from=build /opt/venv /opt/venv
COPY alembic.ini /app/alembic.ini
COPY migrations /app/migrations
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz').status==200 else 1)"
ENTRYPOINT ["uvicorn", "--factory", "intake_api.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
