# syntax=docker/dockerfile:1.7
FROM python:3.15-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /src
COPY pyproject.toml ./
COPY src ./src
RUN pip install .

FROM python:3.15-slim
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1
USER 10001
EXPOSE 9464
ENTRYPOINT ["python", "-m", "pipeline_worker.worker"]
