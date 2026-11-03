SHELL := /bin/bash
.PHONY: lint validate test up smoke down

lint: validate
	yamllint .
	shellcheck scripts/*.sh scripts/smoke.d/*.sh

validate:
	scripts/validate.sh

test:
	bats test/

up:
	scripts/up.sh

smoke:
	scripts/smoke.sh

down:
	scripts/down.sh
