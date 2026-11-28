# OpenAgentix: the same checks CI runs (.github/workflows/ci.yml), runnable locally. `make help` lists the targets.
# Go modules are discovered (hack/ci/go-modules.sh), so a new service needs no edit here.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

GO_MODULES    := $(shell hack/ci/go-modules.sh 2>/dev/null)
SHELL_FILES   := $(shell git ls-files '*.sh' 2>/dev/null)
GITLEAKS_ARGS ?=
# shellcheck is a report until the tree is clean: SHELLCHECK_STRICT=1 makes any finding fail `make lint`.
SHELLCHECK_STRICT ?= 0

# need <tool> [hint]: fail early with a clear message when a tool is missing.
define need
@command -v $(1) >/dev/null || { echo "ERROR: '$(1)' is required$(if $(2), ($(2)))." >&2; exit 1; }
endef

.PHONY: help test test-go flake-sweep test-chart test-shell test-integration test-console test-console-e2e e2e lint lint-go lint-shell secrets cover

help: ## List the targets
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: test-go test-chart test-shell ## Everything that runs offline (no Docker, no cluster)

test-go: ## go test -race over every Go module (COVER=1 writes coverage.out in each module)
	$(call need,go)
	@for m in $(GO_MODULES); do \
	  echo "=== go test $$m"; \
	  (cd $$m && go test ./... -race -count=1 $(if $(COVER),-coverprofile=coverage.out -covermode=atomic)); \
	done

flake-sweep: ## The nightly flake sweep, here: go test -race -count=$(COUNT) per module (COUNT=20, MODULES=<dirs> for fewer)
	$(call need,go)
	$(call need,jq)
	@fail=0; for m in $(or $(MODULES),$(GO_MODULES)); do \
	  hack/ci/flake-sweep.sh $$m --count $(or $(COUNT),20) || fail=1; \
	done; exit $$fail

cover: ## Per-module coverage summary
	@$(MAKE) --no-print-directory test-go COVER=1
	@for m in $(GO_MODULES); do printf '%-28s ' $$m; (cd $$m && go tool cover -func=coverage.out | tail -1); done

test-chart: ## Render tests over `helm template` plus helm lint (needs helm, jq, yq = the Python jq wrapper)
	$(call need,helm)
	$(call need,jq)
	$(call need,yq,the Python jq wrapper: pip install yq==3.4.3; NOT mikefarah/yq)
	@yq --version 2>&1 | grep -q '^yq 3\.' || { echo "ERROR: yq must be the Python wrapper (kislyuk/yq 3.x), found: $$(yq --version 2>&1 | head -1)" >&2; exit 1; }
	helm lint charts/openagentix
	charts/openagentix/tests/run.sh
	examples/use-cases/bank/tests/run.sh
	examples/use-cases/equipment/tests/run.sh
	examples/use-cases/software-org/tests/run.sh

test-shell: ## Offline shell and Python suites: channels, dashboard (jsdom part needs `npm ci` in website/), bench
	$(call need,jq)
	$(call need,yq,the Python jq wrapper)
	$(call need,python3)
	components/channels/tests/run.sh
	components/quickstart/tests/run.sh
	hack/dashboard/tests/run.sh
	hack/ci/image-tag-test.sh
	hack/ci/key-entry-test.sh
	hack/ci/phases-test.sh
	hack/ci/flake-sweep-test.sh
	hack/ci/green-streak-test.sh
	hack/demo-test.sh
	hack/ci/release-notes-test.sh
	hack/use-case-eval-test.sh
	hack/ci/verify-release-test.sh
	hack/ci/kind-image-digest-test.sh
	hack/ci/cluster-test.sh
	hack/ci/images-test.sh
	hack/ci/preflight-test.sh
	hack/ci/pdb-check-test.sh
	hack/ci/release-values-diff-test.sh
	hack/ci/netpol-check-test.sh
	hack/ci/compose-values-test.sh
	hack/ci/default-storageclass-test.sh
	hack/ci/sa-issuer-test.sh
	hack/ci/gateway-service-type-test.sh
	hack/ci/uninstall-test.sh
	hack/ci/diagnostics-bearer-test.sh
	hack/ci/diagnostics-check-test.sh
	hack/ci/kb-callers-test.sh
	hack/ci/kb-live-mode-test.sh
	hack/ci/endpoints-check-test.sh
	hack/ci/recovery-test-test.sh
	hack/ci/upgrade-test-test.sh
	hack/ci/lifecycle-test-test.sh
	hack/gke/tests/run.sh
	components/runtime/tests/run.sh
	hack/docs/tests/run.sh
	examples/use-cases/bank/tests/install-test.sh
	examples/use-cases/software-org/tests/install-test.sh
	examples/use-cases/bank/tests/live-guard-test.sh
	examples/use-cases/equipment/tests/install-test.sh
	examples/use-cases/equipment/tests/live-guard-test.sh
	hack/ci/events-live-test.sh
	hack/ci/use-case-classes-test.sh
	hack/ci/also-compose-cross-test.sh
	hack/ci/live-sweep-test.sh
	hack/ci/use-case-class-live-test.sh
	python3 -m unittest discover -s components/bench -p 'test_*.py'
	python3 -m unittest discover -s components/bench/compare -p 'test_*.py'

test-integration: ## Suites that need Docker: kb against PostgreSQL+pgvector, memory-expiry job (throwaway containers)
	$(call need,docker)
	@docker info >/dev/null 2>&1 || { echo "ERROR: the Docker daemon is not reachable" >&2; exit 1; }
	$(MAKE) -C services/kb test-integration
	charts/openagentix/tests/memory-expiry-integration.sh

lint: lint-go lint-shell ## gofmt check, go vet, shellcheck

lint-go: ## gofmt -l and go vet in every Go module
	$(call need,go)
	@fail=0; for m in $(GO_MODULES); do \
	  echo "=== lint $$m"; \
	  out=$$(cd $$m && gofmt -l .); [ -z "$$out" ] || { echo "gofmt needed:"; echo "$$out"; fail=1; }; \
	  (cd $$m && go vet ./...) || fail=1; \
	done; exit $$fail

lint-shell: ## shellcheck on tracked *.sh at warning level; prints the count; non-blocking unless SHELLCHECK_STRICT=1
	$(call need,shellcheck)
	@out=$$(shellcheck -S warning -f gcc $(SHELL_FILES) 2>&1 || true); \
	  warns=$$(printf '%s\n' "$$out" | grep -c ': warning:' || true); errs=$$(printf '%s\n' "$$out" | grep -c ': error:' || true); \
	  [ -z "$$out" ] || printf '%s\n' "$$out"; \
	  echo "shellcheck: $$warns warning(s), $$errs error(s) in $$(echo $(SHELL_FILES) | wc -w | tr -d ' ') files"; \
	  [ "$(SHELLCHECK_STRICT)" != 1 ] || [ "$$((warns + errs))" = 0 ]

secrets: ## gitleaks over the whole git history, honouring .gitleaksignore
	$(call need,gitleaks)
	gitleaks git --no-banner --redact $(GITLEAKS_ARGS) .

test-console: ## Console: pnpm install --frozen-lockfile, lint, svelte-check, vitest (needs Node 22 and pnpm); not the browser tests
	$(call need,pnpm)
	cd console && pnpm install --frozen-lockfile && pnpm lint && pnpm check && pnpm test

test-console-e2e: ## Console end-to-end in Chromium against the Go binary in demo mode (needs Node 22, pnpm, Go; installs Chromium)
	$(call need,pnpm)
	$(call need,go)
	services/console/build-web.sh
	cd console && pnpm exec playwright install --with-deps chromium && pnpm test:e2e

e2e: ## Prints how to run the keyless end-to-end install (needs Docker, kind, kubectl; make does not start a cluster)
	@echo "e2e: make does not create a cluster. With kind running, use your own KUBECONFIG and run:"
	@echo "  PROFILE=quickstart ./install.sh && hack/ci/smoke.sh"
	@echo "See hack/ci/README.md, section e2e."

# ---- control plane guard tests (own targets: the heavy k8s.io/apiserver dependency stays in hack/ci/guardtest, not in any service module) ----
.PHONY: test-guard test-apiserver test-python-samples

test-python-samples: ## The Python sample agent: hash-checked install in a throwaway venv, pytest, contract test against stub-model (needs python3; Go for the contract test)
	$(call need,python3)
	hack/ci/python-samples-test.sh

test-guard: ## Execute the control plane's admission guard (rendered by helm) with the Kubernetes CEL code: hack/ci/guardtest (needs helm, go)
	$(call need,go)
	$(call need,helm)
	cd hack/ci/guardtest && go test ./... -count=1

test-apiserver: ## The CRD and the guard against a real API server in a throwaway kind cluster (oa-ci-test): hack/ci/apiserver-test.sh (needs kind, kubectl, helm, docker, jq, yq)
	hack/ci/apiserver-test.sh
