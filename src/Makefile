.DEFAULT_GOAL := help
.PHONY: help up down logs simulate validate query subscribe listen bootstrap \
        infra-init infra-plan infra-apply infra-destroy \
        deploy deploy-subscriber deploy-listener \
        pipeline-up pipeline-down listener-up listener-down

# All tooling (gcloud, Terraform, Python) runs inside the tools container.
# The host only needs Docker Desktop.
TOOLS_RUN = docker compose --profile tools run --rm tools
INFRA_DIR := ../infra

# ── help ───────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  Prerequisites: Docker Desktop only."
	@echo "  All other tools (gcloud, Terraform, Python) run inside the tools container."
	@echo ""
	@echo "  First-time setup"
	@echo "    make setup            Provision GCP infra + deploy subscriber to Cloud Run"
	@echo "    make bootstrap        Provision GCP infra only (pass ARGS='<project-id>')"
	@echo ""
	@echo "  Run the pipeline (hybrid: listener local, subscriber on Cloud Run)"
	@echo "    make up               Start MongoDB replica set"
	@echo "    make listener-up      Start listener as a local Docker container"
	@echo "    make simulate         Run price simulator"
	@echo "    make listener-down    Stop local listener container"
	@echo "    make down             Stop MongoDB + remove volumes"
	@echo ""
	@echo "  Observe"
	@echo "    make logs             Tail all Docker container logs"
	@echo "    make validate         Compare MongoDB vs BigQuery"
	@echo "    make query            Query BigQuery (ARGS='--name AAPL --latest')"
	@echo ""
	@echo "  Cloud Deployment"
	@echo "    make deploy           Build + push subscriber image → deploy to Cloud Run"
	@echo "    make deploy-subscriber Redeploy subscriber to Cloud Run only"
	@echo "    make deploy-listener  Redeploy listener to GCE (optional, production)"
	@echo ""
	@echo "  Run everything in Docker (no Cloud Run)"
	@echo "    make pipeline-up      Start MongoDB + listener + subscriber all locally"
	@echo "    make pipeline-down    Stop all pipeline containers"
	@echo ""
	@echo "  Infrastructure (Terraform)"
	@echo "    make infra-init       terraform init"
	@echo "    make infra-plan       terraform plan"
	@echo "    make infra-apply      terraform apply"
	@echo "    make infra-destroy    terraform destroy (removes all GCP resources)"
	@echo ""

# ── first-time setup ───────────────────────────────────────────────────────────

setup:
	$(TOOLS_RUN) bash bootstrap.sh $(ARGS)
	$(TOOLS_RUN) bash deploy.sh

bootstrap:
	$(TOOLS_RUN) bash bootstrap.sh $(ARGS)

# ── MongoDB (runs on host Docker, no tools container needed) ───────────────────

up:
	docker compose up -d

down:
	docker compose down -v

logs:
	docker compose logs -f

# ── pipeline containers ────────────────────────────────────────────────────────

listener-up:
	docker compose --profile pipeline up -d listener

listener-down:
	docker compose --profile pipeline stop listener
	docker compose --profile pipeline rm -f listener

pipeline-up:
	docker compose --profile pipeline up -d

pipeline-down:
	docker compose --profile pipeline down

# ── Python scripts (run inside tools container) ────────────────────────────────

simulate:
	$(TOOLS_RUN) python3 simulator.py

validate:
	$(TOOLS_RUN) python3 validate.py

query:
	$(TOOLS_RUN) python3 query.py $(ARGS)

# Local debugging — runs subscriber/listener as bare Python inside tools container
subscribe:
	$(TOOLS_RUN) python3 subscriber.py

listen:
	$(TOOLS_RUN) python3 listener.py

# ── cloud deployment ───────────────────────────────────────────────────────────

deploy:
	$(TOOLS_RUN) bash deploy.sh

deploy-subscriber:
	$(TOOLS_RUN) bash deploy.sh --subscriber-only

deploy-listener:
	$(TOOLS_RUN) bash deploy.sh --listener-only

# ── infrastructure (Terraform via tools container) ─────────────────────────────

infra-init:
	$(TOOLS_RUN) terraform -chdir=$(INFRA_DIR) init -upgrade

infra-plan:
	$(TOOLS_RUN) terraform -chdir=$(INFRA_DIR) plan

infra-apply:
	$(TOOLS_RUN) terraform -chdir=$(INFRA_DIR) apply

infra-destroy:
	$(TOOLS_RUN) terraform -chdir=$(INFRA_DIR) destroy
