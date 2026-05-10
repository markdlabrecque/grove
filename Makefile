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

# Two targets cover the full local test matrix:
#   ios-test-core  → swift test on the OracleCore package (mirrors the stable CI gate)
#   ios-test-app   → xcodebuild test on the Oracle scheme  (local-only; requires Xcode 26 + xcconfig)
#   ios-test       → runs both in sequence; required pre-push check per AGENTS.md
#
# CI runs only ios-test-core (the stable gate) because macos-latest ships Xcode 16.2,
# which cannot build the iOS 26 deployment target, and the xcconfig files are gitignored.
# ios-test-app is the local substitute for the CI canary job that was removed.
# See TODO(ci) in .github/workflows/ios-ci.yml for when to re-add the full-app CI job.

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

# smoke-ingress: Mac-side verification of the Tailnet → Apache (TLS) → FastAPI path.
# Covers steps 1–5 of the former docs/manual-tests/tailscale-tls-ingress.md.
#
# Step 6 (phone-side) is genuinely manual — originate a request from the phone:
#   Open Safari on the phone → https://<tailnet-host>/healthz  (expect {"status":"ok"})
#   Or POST /v1/captures via an HTTP-client app with Authorization: Bearer <BEARER_TOKEN>.

.PHONY: smoke-ingress
smoke-ingress: ## Verify Tailnet → Apache TLS → FastAPI ingress is healthy (run after cert/hostname changes)
	@set -euo pipefail; \
	if [ ! -f .env ]; then echo "FAIL: .env not found"; exit 1; fi; \
	source .env; \
	if [ -z "$${TAILSCALE_HOSTNAME:-}" ]; then echo "FAIL: TAILSCALE_HOSTNAME not set in .env"; exit 1; fi; \
	if [ -z "$${BEARER_TOKEN:-}" ]; then echo "FAIL: BEARER_TOKEN not set in .env"; exit 1; fi; \
	HOST="$$TAILSCALE_HOSTNAME"; \
	TOKEN="$$BEARER_TOKEN"; \
	\
	echo "--- smoke-ingress: $$HOST ---"; \
	\
	echo ""; \
	echo "1. Apache vhost config (ServerName + SSLCertificate lines):"; \
	VHOST=$$(docker compose exec -T apache cat /usr/local/apache2/conf/extra/oracle.conf 2>&1 | grep -E 'ServerName|SSLCertificate'); \
	if echo "$$VHOST" | grep -q "$$HOST"; then \
		echo "   PASS: ServerName contains $$HOST"; \
	else \
		echo "   FAIL: ServerName does not contain $$HOST — got: $$VHOST"; exit 1; \
	fi; \
	\
	echo ""; \
	echo "2. TLS handshake (cert subject CN + verify ok + HTTP 200 on /healthz):"; \
	TLS_OUT=$$(curl -sv --resolve "$$HOST:443:127.0.0.1" "https://$$HOST/healthz" 2>&1); \
	if echo "$$TLS_OUT" | grep -q "verify ok"; then \
		echo "   PASS: verify ok"; \
	else \
		echo "   FAIL: TLS verify not ok — $$(echo "$$TLS_OUT" | grep -E 'verify|subject|issuer' | head -5)"; exit 1; \
	fi; \
	if echo "$$TLS_OUT" | grep -qE 'HTTP/[0-9.]+ 200'; then \
		echo "   PASS: HTTP 200 on /healthz"; \
	else \
		STATUS=$$(echo "$$TLS_OUT" | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -1); \
		echo "   FAIL: expected HTTP 200, got: $$STATUS"; exit 1; \
	fi; \
	\
	echo ""; \
	echo "3. Public health endpoints over TLS:"; \
	HEALTHZ=$$(curl -o /dev/null -sw "%{http_code}" "https://$$HOST/healthz"); \
	if [ "$$HEALTHZ" = "200" ]; then \
		echo "   PASS: /healthz → 200"; \
	else \
		echo "   FAIL: /healthz → $$HEALTHZ (expected 200)"; exit 1; \
	fi; \
	READYZ=$$(curl -o /dev/null -sw "%{http_code}" "https://$$HOST/readyz"); \
	if [ "$$READYZ" = "200" ]; then \
		echo "   PASS: /readyz → 200"; \
	else \
		echo "   FAIL: /readyz → $$READYZ (expected 200)"; exit 1; \
	fi; \
	\
	echo ""; \
	echo "4. Auth gate — unauthenticated POST /v1/captures must return 401:"; \
	UNAUTH=$$(curl -o /dev/null -sw "%{http_code}" -X POST "https://$$HOST/v1/captures" \
		-H 'Content-Type: application/json' -d '{}'); \
	if [ "$$UNAUTH" = "401" ]; then \
		echo "   PASS: unauthenticated POST → 401"; \
	else \
		echo "   FAIL: expected 401, got $$UNAUTH (auth gate may be open)"; exit 1; \
	fi; \
	\
	echo ""; \
	echo "5. Authenticated round-trip — POST /v1/captures with valid bearer:"; \
	CID=$$(uuidgen | tr A-Z a-z); \
	NOW=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
	AUTH=$$(curl -o /dev/null -sw "%{http_code}" -X POST "https://$$HOST/v1/captures" \
		-H "Authorization: Bearer $$TOKEN" \
		-H 'Content-Type: application/json' \
		-d "{\"client_id\":\"$$CID\",\"content\":\"tls smoke from tailnet\",\"source_modality\":\"text\",\"source_device\":\"tailnet-curl\",\"captured_at\":\"$$NOW\"}"); \
	if [ "$$AUTH" = "201" ]; then \
		echo "   PASS: authenticated POST → 201"; \
	else \
		echo "   FAIL: expected 201, got $$AUTH"; exit 1; \
	fi; \
	\
	echo ""; \
	echo "smoke-ingress: all checks passed."
