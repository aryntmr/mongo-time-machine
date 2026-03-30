.DEFAULT_GOAL := help
.PHONY: help up down logs subscribe listen simulate validate query bootstrap install \
        infra-init infra-plan infra-apply infra-destroy

# ── help ───────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  Pipeline"
	@echo "    make up          Start MongoDB replica set (Docker)"
	@echo "    make down        Stop and remove MongoDB containers + volumes"
	@echo "    make logs        Tail Docker container logs"
	@echo "    make subscribe   Terminal 1 — Pub/Sub to BigQuery"
	@echo "    make listen      Terminal 2 — CDC to Pub/Sub"
	@echo "    make simulate    Terminal 3 — price updates"
	@echo "    make validate    Compare MongoDB vs BigQuery"
	@echo "    make query       Run query.py  (pass ARGS='--name AAPL --latest')"
	@echo ""
	@echo "  Setup"
	@echo "    make bootstrap   Provision GCP + populate .env  (pass ARGS='<project-id>')"
	@echo "    make install     pip install -r requirements.txt"
	@echo ""
	@echo "  Infrastructure (Terraform)"
	@echo "    make infra-init    terraform init"
	@echo "    make infra-plan    terraform plan"
	@echo "    make infra-apply   terraform apply"
	@echo "    make infra-destroy terraform destroy"
	@echo ""

# ── pipeline ───────────────────────────────────────────────────────────────────

up:
	docker compose up -d

down:
	docker compose down -v

logs:
	docker compose logs -f

subscribe:
	python subscriber.py

listen:
	python listener.py

simulate:
	python simulator.py

validate:
	python validate.py

query:
	python query.py $(ARGS)

# ── setup ──────────────────────────────────────────────────────────────────────

bootstrap:
	bash bootstrap.sh $(ARGS)

install:
	pip install -r requirements.txt

# ── infrastructure ─────────────────────────────────────────────────────────────

INFRA_DIR := ../infra

infra-init:
	terraform -chdir=$(INFRA_DIR) init -upgrade

infra-plan:
	terraform -chdir=$(INFRA_DIR) plan

infra-apply:
	terraform -chdir=$(INFRA_DIR) apply

infra-destroy:
	terraform -chdir=$(INFRA_DIR) destroy
