SHELL := /usr/bin/env bash

.PHONY: hooks secretscan

# Install the git hooks that refuse commits and pushes containing secrets.
hooks:
	git config core.hooksPath .githooks
	@echo "git hooks installed: commits and pushes are scanned for secrets"

# Scan every commit on every branch.
secretscan:
	go run ./scripts/secretscan history
