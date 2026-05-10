# The Oracle — developer convenience targets.
# Run `make help` for a list. Most targets are thin wrappers around
# `docker compose` so the same workflow applies in dev and (eventually) prod.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

COMPOSE := docker compose
APP := app
DB := postgres
WEB := apache

# ---------- meta ----------

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ---------- stack lifecycle ----------

.PHONY: up
up: ## Build (if needed) and start the stack in the background
	$(COMPOSE) up -d --build

.PHONY: down
down: ## Stop the stack (keeps the database)
	$(COMPOSE) down

.PHONY: nuke
nuke: ## Stop the stack AND wipe the database volume (irreversible)
	$(COMPOSE) down -v

.PHONY: restart
restart: ## Restart all services
	$(COMPOSE) restart

.PHONY: rebuild
rebuild: ## Rebuild the app image and restart only the app service
	$(COMPOSE) up -d --build $(APP)

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

# ---------- logs ----------

.PHONY: logs
logs: ## Tail logs from all services (Ctrl-C to exit)
	$(COMPOSE) logs -f

.PHONY: logs-app
logs-app: ## Tail logs from the FastAPI app
	$(COMPOSE) logs -f $(APP)

.PHONY: logs-db
logs-db: ## Tail logs from Postgres
	$(COMPOSE) logs -f $(DB)

.PHONY: logs-web
logs-web: ## Tail logs from Apache
	$(COMPOSE) logs -f $(WEB)

# ---------- shells ----------

.PHONY: shell
shell: ## Open a bash shell in the app container
	$(COMPOSE) exec $(APP) bash

.PHONY: psql
psql: ## Open a psql shell against the dev database
	$(COMPOSE) exec $(DB) psql -U oracle -d oracle

# ---------- migrations ----------
# These use `run --rm` so they work even when the stack isn't fully up.
# `app` still needs the DB though, so we depend on `up` for migrate targets.

.PHONY: migrate
migrate: up ## Apply all pending Alembic migrations
	$(COMPOSE) exec $(APP) alembic upgrade head

.PHONY: migrate-down
migrate-down: ## Roll back the most recent migration
	$(COMPOSE) exec $(APP) alembic downgrade -1

.PHONY: migrate-status
migrate-status: ## Show current migration revision
	$(COMPOSE) exec $(APP) alembic current

.PHONY: migrate-history
migrate-history: ## Show migration history
	$(COMPOSE) exec $(APP) alembic history --verbose

.PHONY: new-migration
new-migration: ## Create a new migration. Usage: make new-migration MSG="add memories table"
	@if [ -z "$(MSG)" ]; then echo "error: MSG is required. e.g. make new-migration MSG=\"add memories table\""; exit 1; fi
	$(COMPOSE) exec $(APP) alembic revision --autogenerate -m "$(MSG)"

# ---------- tests ----------

.PHONY: test
test: ## Run the test suite inside the app container (rebuilds the app image first)
	$(COMPOSE) run --rm --build $(APP) bash -c "pip install -e '.[dev]' >/dev/null && alembic upgrade head && pytest"

.PHONY: lint
lint: ## Run ruff lint + format check
	$(COMPOSE) run --rm $(APP) bash -c "pip install -e '.[dev]' >/dev/null && ruff check . && ruff format --check ."

.PHONY: format
format: ## Apply ruff formatting in-place
	$(COMPOSE) run --rm $(APP) bash -c "pip install -e '.[dev]' >/dev/null && ruff format . && ruff check --fix ."

# ---------- iOS tests ----------

# Three targets mirror the two-job CI strategy (stable + canary):
#   ios-test-core  → swift test on the OracleCore package (matches stable CI gate)
#   ios-test-app   → xcodebuild test on the Oracle scheme  (matches canary CI job)
#   ios-test       → runs both in sequence; local devs with Xcode 26 see both green
#
# The stable gate (ios-test-core) is the required merge check for develop.
# The canary gate (ios-test-app) requires the iOS 26 SDK locally.

.PHONY: ios-test-core
ios-test-core: ## Run OracleCore swift package tests (stable CI gate; no simulator needed)
	swift test --package-path ios/Oracle/OracleCore

.PHONY: ios-test-app
ios-test-app: ## Run the full Oracle scheme tests on iPhone 17 simulator (canary CI job)
	xcodebuild test \
		-project ios/Oracle/Oracle.xcodeproj \
		-scheme Oracle \
		-destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
		-resultBundlePath ios/build/TestResults.xcresult

.PHONY: ios-test
ios-test: ios-test-core ios-test-app ## Run all iOS tests: OracleCore package + Oracle scheme (requires iOS 26 SDK)

.PHONY: ios-test-clean
ios-test-clean: ## Wipe iOS build artefacts (ios/build/ and ios/DerivedData/) then run tests
	rm -rf ios/build/ ios/Oracle/DerivedData/
	$(MAKE) ios-test

# ---------- certs ----------

.PHONY: cert
cert: ## Issue/refresh the Tailscale TLS cert (runs sudo)
	./ops/scripts/bootstrap-cert.sh

.PHONY: cert-renew
cert-renew: ## Refresh the cert AND gracefully reload Apache
	./ops/scripts/renew-cert.sh

# ---------- smoke checks ----------

.PHONY: health
health: ## Curl the public healthz + readyz endpoints
	@source .env && \
	echo "→ /healthz" && curl -sf "https://$$TAILSCALE_HOSTNAME/healthz" && echo && \
	echo "→ /readyz"  && curl -sf "https://$$TAILSCALE_HOSTNAME/readyz"  && echo
