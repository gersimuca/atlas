.PHONY: help local-up local-down local-logs seed-data test lint \
        tf-init tf-plan tf-apply tf-destroy docker-build helm-lint helm-template

ENV ?= dev
AWS_REGION ?= us-east-1

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

## --- Local development (Docker Compose + LocalStack, no AWS account needed) ---

local-up: ## Build and start the full local stack (LocalStack + all services)
	cd local-dev && docker compose up --build -d
	@echo "api-gateway-service:  http://localhost:8000/docs"
	@echo "agent-orchestrator:   http://localhost:8001/docs"
	@echo "LocalStack dashboard: http://localhost:4566/_localstack/health"

local-down: ## Stop and remove the local stack
	cd local-dev && docker compose down -v

local-logs: ## Tail logs from every local service
	cd local-dev && docker compose logs -f

seed-data: ## Load sample documents into the local (or real) bronze bucket + metadata table
	python3 scripts/seed_sample_data.py

## --- Quality gates ---

test: ## Run unit tests for every Python service
	for svc in apps/api-gateway-service apps/agent-orchestrator apps/ingestion-worker; do \
		echo "--- $$svc ---"; \
		( cd $$svc && python3 -m pytest -q ) || exit 1; \
	done

lint: ## Lint Python, Terraform, and Helm
	ruff check apps ml lambda scripts || true
	terraform fmt -check -recursive infra || true
	helm lint k8s/helm/atlas-platform || true

## --- Terraform ---

tf-init: ## terraform init for the given ENV (dev|prod)
	cd infra/environments/$(ENV) && terraform init

tf-plan: ## terraform plan for the given ENV
	cd infra/environments/$(ENV) && terraform plan -out=tfplan

tf-apply: ## terraform apply the last plan for the given ENV
	cd infra/environments/$(ENV) && terraform apply tfplan

tf-destroy: ## terraform destroy for the given ENV (asks for confirmation)
	cd infra/environments/$(ENV) && terraform destroy

## --- Containers & Kubernetes ---

docker-build: ## Build all service images locally, tagged :dev
	docker build -t atlas/api-gateway-service:dev apps/api-gateway-service
	docker build -t atlas/agent-orchestrator:dev apps/agent-orchestrator
	docker build -t atlas/ingestion-worker:dev apps/ingestion-worker

helm-lint: ## Lint the Helm chart
	helm lint k8s/helm/atlas-platform -f k8s/helm/atlas-platform/values-$(ENV).yaml

helm-template: ## Render the Helm chart locally (no cluster needed) for review
	helm template atlas k8s/helm/atlas-platform -f k8s/helm/atlas-platform/values-$(ENV).yaml
