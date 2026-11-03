SHELL := /bin/bash
.PHONY: lint validate test up smoke down

lint: validate
	yamllint .
	shellcheck scripts/*.sh scripts/smoke.d/*.sh

validate:
	scripts/validate.sh

test:
	bats test/
	@if command -v go >/dev/null 2>&1; then cd apps/demo/src && go test ./... && go vet ./...; else echo 'WARNING: go not found, skipping demo app unit tests'; fi

up:
	scripts/up.sh

smoke:
	scripts/smoke.sh

down:
	scripts/down.sh
