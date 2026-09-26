SHELL := /usr/bin/env bash
SCRIPTS := install.sh check.sh backup.sh lib/common.sh test/container-test.sh test/in-container.sh

.PHONY: hooks secretscan lint test test-dry-run

# Install the git hooks that refuse commits and pushes containing secrets.
hooks:
	git config core.hooksPath .githooks
	@echo "git hooks installed: commits and pushes are scanned for secrets"

# Scan every commit on every branch.
secretscan:
	go run ./scripts/secretscan history

# Syntax and shellcheck for every script, and the scanner's own tests.
lint:
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	shellcheck -x $(SCRIPTS)
	go vet ./... && go test ./...

# The container tests (docker, linux/amd64): dry runs for every chain and
# role, then the installer's early steps for real in test mode.
test: lint
	test/container-test.sh

test-dry-run:
	test/container-test.sh dry-run
