SHELL := /bin/bash
.PHONY: lint validate test up smoke down

lint: validate
	yamllint .
	shellcheck scripts/*.sh

validate:
	scripts/validate.sh

test:
	bats test/

up smoke down:
	@echo "make $@: not implemented yet" >&2
	@exit 1
