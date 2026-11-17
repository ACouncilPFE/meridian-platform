.DEFAULT_GOAL := help
SHELL := /bin/bash

PROMTOOL ?= promtool

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- Local environment -------------------------------------------------------
up: ## Start full local stack (API, Postgres, Temporal, Prometheus, Grafana, Tempo)
	docker compose up -d --build
	@echo "Grafana http://localhost:3000 | API http://localhost:8000/docs | Temporal http://localhost:8233"

down: ## Stop local stack
	docker compose down

seed: ## Load synthetic patients into local API
	python3 scripts/seed_synthetic.py --url http://localhost:8000 --count 200

logs: ## Tail app logs
	docker compose logs -f intake-api pipeline-worker

# --- Quality gates (same as CI) ----------------------------------------------
test: test-api test-worker test-lambda obs-test ## Run every test suite

test-api:
	cd services/intake-api && pytest -q && ruff check src tests migrations

test-worker:
	cd workflows/pipeline-worker && pytest -q && ruff check src tests

test-lambda:
	cd lambdas/dr_verify && pytest -q

obs-test: ## Validate + unit-test Prometheus rules; check dashboards are generated
	$(PROMTOOL) check rules observability/prometheus/rules/*.yml
	$(PROMTOOL) test rules observability/prometheus/tests/*.test.yml
	python3 observability/grafana/build_dashboards.py --check

dashboards: ## Regenerate Grafana dashboard JSON from code
	python3 observability/grafana/build_dashboards.py

tf-check: ## fmt + validate all Terraform
	terraform fmt -check -recursive terraform
	@for d in terraform/modules/* terraform/envs/* terraform/bootstrap/*; do \
	  echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; \
	done

# --- Build -------------------------------------------------------------------
lambda-build: ## Bundle DR verify lambda with vendored deps (arm64)
	rm -rf lambdas/dr_verify/build && mkdir -p lambdas/dr_verify/build
	cp lambdas/dr_verify/handler.py lambdas/dr_verify/collector.yaml lambdas/dr_verify/build/
	pip install -q -r lambdas/dr_verify/requirements.txt -t lambdas/dr_verify/build \
	  --platform manylinux2014_aarch64 --only-binary=:all: --python-version 3.12

# --- Operations --------------------------------------------------------------
rollback: ## Roll an ECS service back to its previous task definition: make rollback ENV=prod SERVICE=intake-api
	scripts/ops/rollback.sh $(ENV) $(SERVICE)

.PHONY: help up down seed logs test test-api test-worker test-lambda obs-test dashboards tf-check lambda-build rollback
